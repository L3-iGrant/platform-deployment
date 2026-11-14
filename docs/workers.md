# Workers and clock

The background work of the organisation wallet: the workers, the clock, their values, how they stop, and how to check them.

[Back to the contents](../README.md#contents)

The wallet runs its background work as actors on Valkey queues. An actor is a function that a worker runs for one message.

- The service and config pods send the messages of their requests after the commit. A job that nothing else repairs (for example a credential offer) is also a database row, until a worker has run it.
- The clock sends the messages of the cron actors when they are due.

Valkey is never a record: after a Valkey loss, the actors find their work in the database again.

| Deployment | Command | Replicas (default) | Database role | NATS user | Valkey user | Port |
| --- | --- | --- | --- | --- | --- | --- |
| `<release>-wallet-worker-<group>` | `dramatiq ows.worker.run:start` with the processes, threads, shutdown timeout and queues of the group, and `--worker-fork-timeout 650000` (the time of the startup probe, so that Dramatiq always starts the health server) | the group | `<prefix>_jobs` | `walletWorker` | `walletWorker` (`wallet-worker`) | 9191 |
| `<release>-wallet-clock` | `start-clock` | 2 | `<prefix>_clock` (CONNECT only) | none | `walletClock` (`wallet-clock`) | 9192 |

## Queues and worker groups

The wallet has five queues:

| Queue | Actors |
| --- | --- |
| `realtime` | the outbox relay (also the durable jobs), the audit anchors, the credential offers, the QES PDF signatures, the Android attestation status list, the writes of the issuer status lists, the issuance counters |
| `attestation` | the WIA pools of the organisation wallet units |
| `status` | the status refresh of the held credentials |
| `kms` | the HSM signer sync and the HSM orphan check (without an HSM signer, they end at once) |
| `maintenance` | the retention purge, the monthly audit log exports, the usage report, the deactivation of an organisation, the expiry of the open issuances, the nightly recount of the issuance counters |

A worker group (`organisationWallet.workers.groups`) is one Deployment `<release>-wallet-worker-<name>` that runs some of the queues. Each pod reads the configuration key `worker-<name>.yaml` of the ConfigMap `<release>-wallet`. The default groups:

| Group | Queues | Replicas | Processes x threads | `shutdownTimeoutSeconds` | `terminationGracePeriodSeconds` |
| --- | --- | --- | --- | --- | --- |
| `main` | `realtime`, `attestation`, `status`, `kms` | 2 | 1 x 8 | 600 | 630 |
| `maintenance` | `maintenance` | 1 | 1 x 2 | 14400 | 14430 |

One thread runs one actor at a time. A worker pod runs `processes` worker processes with `threads` threads each.

The value is a list: your list replaces the whole default list. The render stops when:

- a group has no name, a name with characters other than lower-case letters, digits and `-`, or the name of another group;
- the Deployment name `<release>-wallet-worker-<name>` has more than 63 characters;
- a queue is not a wallet queue, or a group names a queue twice;
- `replicas`, `processes` or `threads` is below 1;
- `terminationGracePeriodSeconds` is below `shutdownTimeoutSeconds` + 30;
- no group runs a queue: its messages would stay in Valkey and grow.

Two groups can run the same queue. For example, to give the queue `attestation` its own group with more replicas:

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

A revocation of an issued credential is final at once, in its issuance and in its webhook event. The transaction of the revocation adds it to a queue in the database, and the workers write it into the issuer's published status list. The actor `status_list.write_changes` (queue `realtime`, every 5 seconds) writes the queued revocations of each list at most once per `organisationWallet.statusList.writeIntervalSeconds` (default 30, 0 to 50; 0: at every run). A revocation is in the published list within 60 seconds. Only the worker files have this value (`status_list.write_interval_seconds`).

Without a worker group that runs the queue `realtime`, or without the clock, a revocation is still final in the issuance and its event, but the published list does not change. The same queue keeps the issuer statistics: the actor `issuance_counter.apply_changes` adds the count changes of the issuances to the counters every 5 seconds. The queue `maintenance` sets the status `expired` on the open issuances whose grant ended (`issuance.expiry_dispatch`, every minute), and counts all issuances again every night (`issuance_counter.reconcile`, 03:10 UTC). See the alerts in [Probes and metrics](#probes-and-metrics).

## Stops and rollouts

An upgrade changes the Deployments of the servers and of the workers together. The service and config pods of a new release can depend on actors that only the workers of the same release have (for example, they queue the revocations of the issuer status lists, and only the new workers write them). Do not scale the worker groups or the clock to 0 during an upgrade, and do not hold back the workers of a new release.

At SIGTERM, a worker stops consuming its queues, then waits at most `shutdownTimeoutSeconds` for its running actors. Each actor has a time limit. Set `shutdownTimeoutSeconds` to at least the longest time limit of the actors on the group's queues: 600 seconds for the queues of `main`, and 4 hours for `maintenance` (the export of one month of one audit log scope). An actor that does not end in that time stops, and runs again from its message: every actor is idempotent.

A rollout starts the new pod first. The old pod takes no new messages, but it can stay `Terminating` until its running actors end: up to 4 hours for the group `maintenance`. A node drain waits for it too. With a shorter grace period, an interrupted export starts again from the beginning.

## Clock

Only the clock that holds the leader lock sends messages. The lock is a session advisory lock on a direct database connection. A clock whose database is in recovery (a standby) never leads. The other clock tries the lock at each wake-up (at least every 5 seconds), so it takes over within seconds after a stop, and within about 25 seconds after the loss of the leader's node. For a short time, two clocks can send: every actor is idempotent.

## Probes and metrics

Each worker pod and each clock pod has one HTTP port (`health`): 9191 for the workers, 9192 for the clock.

| Path | Probe | Checks |
| --- | --- | --- |
| `/healthz` | startup, liveness | the heartbeat of the event loop of each worker process, or of each clock wake-up (stale after 60 seconds). Never Valkey: a Valkey failover does not restart the pods. |
| `/readyz` | readiness | Valkey (`PING`) and the database (`SELECT 1`). No Service sends traffic to a worker or a clock: the readiness only holds a rollout. |
| `/metrics` | | the Prometheus metrics |

The startup probe of a worker gives the boot 650 seconds: each worker process waits up to 600 seconds for the database schema to be at the head of its release.

The service and config pods have the port `metrics` (9190) for the server metrics: `/metrics` only (`server.metrics_port`). Their probes stay on the port of the routes (`/healthz`, `/readyz`). Each process of a server pod writes its metrics files to an `emptyDir` in memory (`server.metrics_directory`, `/run/ows-server`), and the port reads all of them. The Services of the routes and the exposure objects do not have port 9190. The server metrics include the requests of each route group and of the hot routes, the NATS commands, the event loop lag, the waits for a database connection (`ows_db_pool_wait_seconds`), the waits of the audit appends, and the Redis commands.

`organisationWallet.serviceMonitor.enabled: true` creates a headless Service for the service and config roles (`<release>-wallet-service-metrics`, `<release>-wallet-config-metrics`: the port `metrics`), for each worker group and for the clock (the port `health`), including the pods that are not ready. It also creates the ServiceMonitor `<release>-wallet-metrics` for `/metrics` (the Prometheus Operator CRD must exist). The label `metrics.igrant.io/job` of each Service gives the job of its targets (`jobLabel`): `wallet-server`, `wallet-worker`, `wallet-clock`. `interval` (default 15 s) and `labels` go to the ServiceMonitor. With network policies, set `networkPolicy.monitoring` to your monitoring namespace: only it reaches the ports 9190, 9191 and 9192.

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

Each worker pod also reads gauges from the database at each scrape, so every pod gives the same values: use `max` for them. See [Alerts](#alerts) for the alert rules.

## Alerts

`organisationWallet.prometheusRule.enabled: true` (with `serviceMonitor.enabled`; the Prometheus Operator CRD must exist) creates the PrometheusRule `<release>-wallet-alerts` with the rules below. `prometheusRule.labels` gives the labels for the `ruleSelector` of your Prometheus. The rules read the gauges of the worker pods (the ServiceMonitor job `wallet-worker`, in the release namespace). Each worker pod reads them from the database at each scrape, so the rules use `max`. With other monitoring, create the same rules (change the job selector to the one of your scrape):

| Alert | Severity | Rule | Meaning |
| --- | --- | --- | --- |
| `AuditExportStopped` | critical | `max by (namespace, scope) (ows_audit_export_stopped_months{job="wallet-worker"}) > 0` for 10m | The export of a closed month of an audited scope stopped after 8 attempts. The month stays in PostgreSQL, and the partition step cannot drop its partitions (see [Audit log](audit-log.md#partitions)). Fix the cause, then run `audit export-retry` in a worker pod. |
| `PartitionOfTheMonthMissing` | critical | `max by (namespace, table) (ows_partition_months_ahead{job="wallet-worker"}) < 0` for 5m | A table has no partition for the current month: inserts fail. Run the upgrade again (the partition step of the migration hook). |
| `PartitionMonthsAheadLow` | warning | `max by (namespace, table) (ows_partition_months_ahead{job="wallet-worker"}) < 2` for 1h | A table has partitions for fewer than 2 months after the current month. |
| `IssuerStatusListWritesLate` | warning | `max by (namespace) (ows_status_list_change_age_seconds{job="wallet-worker"}) > 60` for 2m | A revocation is not in the published status list after 60 seconds. Check the worker group of the queue `realtime`, and the clock. |
| `IssuanceCountersLate` | warning | `max by (namespace) (ows_issuance_counter_change_age_seconds{job="wallet-worker"}) > 60` for 10m | The issuer statistics are late. |
| `IssuanceExpiryLate` | warning | `max by (namespace) (ows_worker_schedule_overdue_rows{job="wallet-worker",schedule="issuance.expiry"}) > 0` for 15m | Open issuances whose grant ended more than two runs of `issuance.expiry_dispatch` ago. Check the worker group of the queue `maintenance`, and the clock. |
| `AndroidAttestationStatusOld` | warning | `max by (namespace) (ows_android_attestation_status_age_seconds{job="wallet-worker"}) > 7200` for 10m | The stored Google attestation status list is older than 2 hours; a copy older than 24 hours cannot check a key attestation chain. |

A wallet image without a metric gives no series, so its rule does not fire. `tests/alert-rules.sh` checks the rules with `promtool` (see [Tests](tests.md)).

## Users and files

- The workers connect as the jobs role `<prefix>_jobs`, and the clock as the clock role `<prefix>_clock`, which can only connect (see [Database](database.md#database-roles-of-the-wallet)).
- The NATS user `walletWorker` publishes the events of the outbox relay and of the actors (see [NATS users](nats-users.md)). The clock connects to no NATS.
- The Valkey users `wallet-worker` and `wallet-clock` have the rights of the other wallet users (see [Redis](redis.md#acl-users)).
- The worker pods mount the OpenBao login, the service key, the NATS seed of their user, and the audit bucket files (the anchor and export actors write to the bucket). The clock pods mount only the passwords of their database role and their Valkey user, and the CA files. The clock configuration has only the log level, the database, Valkey and its health port (the wallet's `check-config --role clock` checks it).

## The /tmp folder of the workers

The root file system of the worker pods is read-only (see [Security settings of the containers](security-context.md)). The workers write only their temporary files to `/tmp`: an `emptyDir` in memory of 64Mi, the same as in the other wallet pods. The files in `/tmp` count against the memory limit of the worker container.

The monthly audit export (`audit.export`, queue `maintenance`, only with an audit bucket) writes no local file: it reads the month in pages, and sends each chain to the bucket in parts of at most 16 MiB. Its memory peak is about 263 to 424 MiB per export (at most 16 open parts of 16 MiB, one page and one chunk of 8 MiB). So two exports at the same time stay below 1 GiB, inside the memory limit of the workers (1536Mi).

## Network policies

The network role `wallet-worker` reaches the database, NATS, OpenBao and Valkey, with the egress profiles `internet-any-port`, `platform`, `kms`, `cloudKms` and `auditBucket` (default; `metadata` is allowed too). The profile `internet-any-port` also lets the Android attestation status list actor reach its source (`android.googleapis.com`, port 443). For a mirror in your network, add a profile with its address to `networkPolicy.egress.roles.wallet-worker`. The network role `wallet-clock` reaches only the database and Valkey. See [Network policies](network-policies.md).

## Check

```bash
kubectl -n ows get pods -l 'app.kubernetes.io/component in (wallet-clock,wallet-worker-main,wallet-worker-maintenance)'
for pod in $(kubectl -n ows get pods -l app.kubernetes.io/component=wallet-clock -o name); do
  kubectl -n ows exec "$pod" -- /app/.venv/bin/python -c \
    "import urllib.request; print(urllib.request.urlopen('http://127.0.0.1:9192/metrics').read().decode())" | grep '^ows_clock_leader '
done
```

All pods are `Running` and `READY`, and exactly one clock shows `ows_clock_leader 1.0`.
