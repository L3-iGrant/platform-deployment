# Workers and clock

This page explains the background work of the organisation wallet: the workers, the clock, their values, their stops and their checks.

[Back to the contents](../README.md#contents)

The wallet runs its background work as actors on the queues of Valkey. An actor is a function that a worker runs for one message. The service and config pods send the messages of their requests after the commit. A job that nothing else repairs (for example a credential offer) is also a row in the database, until a worker ran it. The clock sends the messages of the cron actors when their time comes. Valkey is never a record: after a loss of Valkey, the actors find their work again in the database.

| Deployment | Command | Replicas (default) | Database role | NATS user | Valkey user | Port |
| --- | --- | --- | --- | --- | --- | --- |
| `<release>-wallet-worker-<group>` | `dramatiq ows.worker.run:start` with the processes, threads, shutdown timeout and queues of the group, and `--worker-fork-timeout 650000` (the time of the startup probe: Dramatiq then always starts the health server) | the group | `<prefix>_jobs` | `walletWorker` | `walletWorker` (`wallet-worker`) | 9191 |
| `<release>-wallet-clock` | `start-clock` | 2 | `<prefix>_clock` (CONNECT only) | none | `walletClock` (`wallet-clock`) | 9192 |

## Queues and worker groups

The wallet has five queues:

| Queue | Actors |
| --- | --- |
| `realtime` | the outbox relay (also the durable jobs), the audit anchors, the credential offers, the QES PDF signatures, the Android attestation status list, the writes of the issuer status lists, the issuance counters |
| `attestation` | the WIA pools of the organisation wallet units |
| `status` | the status refresh of the held credentials |
| `kms` | the HSM signer sync and the HSM orphan check (without an HSM signer they end at once) |
| `maintenance` | the retention purge, the monthly exports of the audit log, the usage report, the deactivation of an organisation, the expiry of the open issuances, the nightly recount of the issuance counters, the copy of the issuances of earlier releases |

A worker group (`organisationWallet.workers.groups`) is one Deployment `<release>-wallet-worker-<name>` that runs some of the queues. Each pod reads the configuration key `worker-<name>.yaml` of the ConfigMap `<release>-wallet`. The default groups:

| Group | Queues | Replicas | Processes x threads | `shutdownTimeoutSeconds` | `terminationGracePeriodSeconds` |
| --- | --- | --- | --- | --- | --- |
| `main` | `realtime`, `attestation`, `status`, `kms` | 2 | 1 x 8 | 600 | 630 |
| `maintenance` | `maintenance` | 1 | 1 x 2 | 14400 | 14430 |

One thread runs one actor at a time. A worker pod runs `processes` worker processes with `threads` threads each.

The value is a list: your list replaces the whole default list. The render stops when:

- a group has no name, a name that is not lower-case letters, digits and `-`, or the name of another group;
- the Deployment name `<release>-wallet-worker-<name>` has more than 63 characters;
- a queue is not a queue of the wallet, or a group names a queue two times;
- `replicas`, `processes` or `threads` is below 1;
- `terminationGracePeriodSeconds` is below `shutdownTimeoutSeconds` + 30;
- no group runs a queue: its messages would stay in Valkey and grow.

Two groups can run the same queue. For example, give the queue `attestation` a group of its own, with more replicas:

```yaml
organisationWallet:
  workers:
    groups:
      - {name: main, queues: [realtime, status, kms], replicas: 2, processes: 1, threads: 8,
         shutdownTimeoutSeconds: 600, terminationGracePeriodSeconds: 630}
      - {name: attestation, queues: [attestation], replicas: 3, processes: 1, threads: 8,
         shutdownTimeoutSeconds: 600, terminationGracePeriodSeconds: 630}
      - {name: maintenance, queues: [maintenance], replicas: 1, processes: 1, threads: 2,
         shutdownTimeoutSeconds: 14400, terminationGracePeriodSeconds: 14430}
```

## Status list writes

A revocation of an issued credential is final at once in its issuance and in its webhook event. The transaction of the revocation adds it to a queue in the database, and the workers write it into the published status list of the issuer: the actor `status_list.write_changes` (queue `realtime`, every 5 seconds) writes the queued revocations of each list at most once in `organisationWallet.statusList.writeIntervalSeconds` (default 30, 0 to 50; 0: at each run). A revocation is in the published list within 60 seconds. Only the files of the workers have the value (`status_list.write_interval_seconds`).

Without a worker group that runs the queue `realtime`, or without the clock, a revocation is final in the issuance and in its event, but the published list does not change. The same queue keeps the statistics of the issuer: the actor `issuance_counter.apply_changes` adds the count changes of the issuances to the counters every 5 seconds. The queue `maintenance` gives the status `expired` to the open issuances whose grant ended (`issuance.expiry_dispatch`, each minute) and counts all issuances again each night (`issuance_counter.reconcile`, 03:10 UTC). See the alerts in [Probes and metrics](#probes-and-metrics).

## The copy of the issuances

The wallet keeps each issuance in tables by its life cycle: the issuance, its claims, its protocol session, its evidence, each issued credential and its token. The issuances of earlier releases are rows of `issuer.credential_issuance`. Two actors of the queue `maintenance` copy these rows into the tables of the issuance:

| Actor | When | Work |
| --- | --- | --- |
| `issuance.backfill` | A durable job of the upgrade, about 10 minutes after the migration (only when `issuer.credential_issuance` has rows), then one job for each next run while rows are left | Copies the rows in the order of their ids: 1,000 rows in each transaction, 20 transactions in each run. It records its position in `platform.data_migration` (`issuance backfill`). At the end it sends the reconcile. |
| `issuance.backfill_reconcile` | Each day at 04:10 UTC, and at the end of the backfill | Copies the rows that have no copy, and the copies that wait for a change that a pod of an earlier release made. Then it writes the counts to the progress row and to the log. |

The two actors hold the lock `issuance:backfill`: only one run at a time. A copy of a row that has a copy and did not change writes nothing. A server pod that reads an issuance that the backfill did not copy yet copies it at once, so a wallet that was in an issuance at the upgrade can complete it.

Run the command `issuance-backfill` in a worker pod, with the configuration of the worker:

```bash
kubectl -n ows exec deploy/ows-wallet-worker-maintenance -- /app/.venv/bin/issuance-backfill status
```

`status` prints JSON with two parts:

- `progress`: the progress row (`applied`, `outcome`, the start and end times, and in `details` the position and the counts of the last reconcile). `null`: the installation had no issuance of an earlier release, and there is nothing to copy.
- `counts`: the counts at this time. `source`: the rows of `issuer.credential_issuance`; `copied` and `missing`: the rows with and without a copy; `issuances`: the issuances; `changed`: the copies that wait for a copy again; `revoked` and `revokedCopies`: the revoked rows and their revoked copies.

The copy is complete when `progress.applied` is `true` and `counts.missing` and `counts.changed` are `0`.

`issuance-backfill start` adds a durable job of the backfill, for example when the job stopped after its retries: the job continues after the recorded position. `issuance-backfill start --from-start` reads every row again from the first one: use it when `counts.missing` stays above 0 after a reconcile. With `--operator <id>`, the audit log names you by a pseudonymous id (never an e-mail address) in place of the command. Exit code: 0 done, 1 a database error, 2 a wrong argument.

The reconcile has no metric. When a row has no copy, it writes a warning to the log of the worker: the line has `[ows.issuance.backfill] [WARNING] Issuance backfill reconcile:`, then the counts. Make an alert on this line in your log system, for example with Loki:

```text
sum(count_over_time({namespace="ows", container=~"wallet-worker-.+"} |= "[ows.issuance.backfill] [WARNING]" [1d])) > 0
```

After the alert, run `issuance-backfill status`, then `issuance-backfill start --from-start` when rows stay missing. A later release drops `issuer.credential_issuance`; its migration stops while the copy is not complete (see [Upgrade](upgrade.md#the-tables-of-the-issuances)).

## Stops and rollouts

An upgrade changes the Deployments of the servers and of the workers together. The service and config pods of a new release can depend on actors that only the workers of the same release have (for example, they queue the revocations of the issuer status lists, and only the new workers write them). Do not scale the worker groups or the clock to 0 during an upgrade, and do not hold back the workers of a new release.

At SIGTERM, a worker stops the consumers of its queues, then waits at most `shutdownTimeoutSeconds` for its running actors. Each actor has a time limit. Set `shutdownTimeoutSeconds` to at least the longest time limit of the actors of the queues of the group: 600 seconds for the queues of `main`, and 4 hours for `maintenance` (the export of one month of one scope of the audit log). An actor that does not end in that time stops, and runs again from its message: each actor is idempotent.

A rollout starts the new pod first. The old pod takes no new message, but it can stay in the state `Terminating` until its running actors end: up to 4 hours for the group `maintenance`. A drain of a node waits for it too. With a shorter grace period, an interrupted export runs again from its start.

## Clock

Only the clock that holds the leader lock sends messages. The lock is a session advisory lock on a direct connection to the database. A clock whose database is in recovery (a standby) never leads. The other clock tries the lock at each wake-up (at least every 5 seconds), so it takes over within seconds after a stop, and within about 25 seconds after the loss of the node of the leader. For a short time two clocks can send: each actor is idempotent.

## Probes and metrics

Each worker pod and each clock pod has one HTTP port (`health`): 9191 for the workers, 9192 for the clock.

| Path | Probe | Checks |
| --- | --- | --- |
| `/healthz` | startup, liveness | the heartbeat of the event loop of each worker process, or of each wake-up of the clock (stale after 60 seconds). Never Valkey: a failover of Valkey does not restart the pods. |
| `/readyz` | readiness | Valkey (`PING`) and the database (`SELECT 1`). No Service sends traffic to a worker or a clock: the readiness only holds a rollout. |
| `/metrics` | | the Prometheus metrics |

The startup probe of a worker gives the boot 650 seconds: each worker process waits up to 600 seconds for the database schema at the head of its release.

The service and config pods have the port `metrics` (9190) for the metrics of the server: `/metrics` only (`server.metrics_port`). Their probes stay on the port of the routes (`/healthz`, `/readyz`). Each process of a server pod writes its metrics files to an `emptyDir` in memory (`server.metrics_directory`, `/run/ows-server`), and the port reads all of them. The Services of the routes and the exposure objects do not have the port 9190. The server metrics include the requests of each route group and the hot routes, the NATS commands, the event loop lag, the waits for a database connection (`ows_db_pool_wait_seconds`), the waits of the audit appends and the Redis commands; the docs of the organisation-wallet-suite repository list them, with the alerts.

`organisationWallet.serviceMonitor.enabled: true` creates a headless Service for the service and config roles (`<release>-wallet-service-metrics`, `<release>-wallet-config-metrics`: the port `metrics`), for each worker group and for the clock (the port `health`), also with the pods that are not ready, and the ServiceMonitor `<release>-wallet-metrics` of `/metrics` (the CRD of the Prometheus Operator must exist). The label `metrics.igrant.io/job` of each Service gives the job of its targets (`jobLabel`): `wallet-server`, `wallet-worker`, `wallet-clock`. `interval` (default 15 s) and `labels` are the values of the ServiceMonitor. With network policies, set `networkPolicy.monitoring` to your monitoring namespace: only it reaches the ports 9190, 9191 and 9192.

| Metric | Labels | Process |
| --- | --- | --- |
| `ows_worker_messages_total` | queue, actor, outcome (`succeeded`, `failed`, `skipped`) | worker |
| `ows_worker_message_retries_total`, `ows_worker_dead_letters_total` | queue, actor | worker |
| `ows_worker_message_duration_seconds` | queue, actor | worker |
| `ows_worker_event_loop_lag_seconds` | | worker |
| `ows_worker_queue_messages`, `ows_worker_queue_delayed_messages`, `ows_worker_queue_dead_messages`, `ows_worker_queue_oldest_message_age_seconds` | queue | worker |
| `ows_clock_leader`, `ows_clock_heartbeat_age_seconds` | | clock |
| `ows_clock_messages_sent_total`, `ows_clock_send_failures_total` | actor | clock |

Each worker pod reads the queue metrics of all queues from Valkey: use `max by (queue)` for them.

Each worker pod also reads gauges from the database at each scrape, so each pod gives the same values: use `max` for them. The chart makes no alert rules: the docs of the organisation-wallet-suite repository list the metrics and their alerts. The issuer needs these alerts:

| Metric | Alert | Meaning |
| --- | --- | --- |
| `ows_status_list_change_age_seconds` | above 60 | The age of the oldest queued revocation of an issuer status list (0 without one). A revocation is in the published list within 60 seconds: check the worker group of the queue `realtime` and the clock. |
| `ows_issuance_counter_change_age_seconds` | above 60 | The age of the oldest count change of the issuances that waits for the actor `issuance_counter.apply_changes` (0 without one). The statistics of the issuer are late. |
| `ows_worker_schedule_overdue_rows{schedule="issuance.expiry"}` | above 0 | The open issuances whose grant ended more than two runs of `issuance.expiry_dispatch` ago: the expiry is late. Check the worker group of the queue `maintenance` and the clock. |

For example, as a PrometheusRule of the Prometheus Operator:

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: ows-wallet-issuer
  namespace: ows
spec:
  groups:
    - name: ows-wallet-issuer
      rules:
        - alert: IssuerStatusListWritesLate
          expr: max(ows_status_list_change_age_seconds) > 60
        - alert: IssuanceCountersLate
          expr: max(ows_issuance_counter_change_age_seconds) > 60
        - alert: IssuanceExpiryLate
          expr: max(ows_worker_schedule_overdue_rows{schedule="issuance.expiry"}) > 0
```

The copy of the issuances of earlier releases has an alert on a log line, not on a metric: see [The copy of the issuances](#the-copy-of-the-issuances).

## Users and files

- The workers connect as the jobs role `<prefix>_jobs`, the clock as the clock role `<prefix>_clock`: it can only connect (see [Database](database.md#database-roles-of-the-wallet)).
- The NATS user `walletWorker` publishes the events of the outbox relay and of the actors (see [NATS users](nats-users.md)). The clock connects to no NATS.
- The Valkey users `wallet-worker` and `wallet-clock` have the rights of the other wallet users (see [Redis](redis.md#acl-users)).
- The worker pods mount the OpenBao login, the service key, the NATS seed of their user and the files of the audit bucket (the actors of the anchors and the exports write it). The clock pods mount only the password of their database role and of their Valkey user, and the CA files. The configuration of the clock has only the log level, the database, Valkey and its health port (`check-config --role clock` of the wallet checks it).

## The /tmp folder of the workers

The root file system of the worker pods is read-only (see [Security settings of the containers](security-context.md)). The workers write only their temporary files to `/tmp`: an `emptyDir` in memory of 64Mi, the same as in the other wallet pods. The files of `/tmp` count against the memory limit of the worker container.

The monthly audit export (`audit.export`, queue `maintenance`, only with an audit bucket) writes no local file: it reads the month in pages and sends each chain in parts of at most 16 MiB to the bucket. Its memory peak is about 263 to 424 MiB for one export (at most 16 open parts of 16 MiB, one page and one chunk of 8 MiB), so two exports at the same time stay below 1 GiB, inside the memory limit of the workers (1536Mi).

## Network policies

The network role `wallet-worker` reaches the database, NATS, OpenBao and Valkey, with the egress profiles `internet`, `kms`, `cloudKms` and `auditBucket` (default; `metadata` is allowed too). The profile `internet` also gives the actor of the Android attestation status list its source (`android.googleapis.com`, port 443); for a mirror in your network, add a profile with its address to `networkPolicy.egress.roles.wallet-worker`. The network role `wallet-clock` reaches only the database and Valkey. See [Network policies](network-policies.md).

## Check

```bash
kubectl -n ows get pods -l 'app.kubernetes.io/component in (wallet-clock,wallet-worker-main,wallet-worker-maintenance)'
for pod in $(kubectl -n ows get pods -l app.kubernetes.io/component=wallet-clock -o name); do
  kubectl -n ows exec "$pod" -- /app/.venv/bin/python -c \
    "import urllib.request; print(urllib.request.urlopen('http://127.0.0.1:9192/metrics').read().decode())" | grep '^ows_clock_leader '
done
```

All pods are `Running` and `READY`, and exactly one clock shows `ows_clock_leader 1.0`.
