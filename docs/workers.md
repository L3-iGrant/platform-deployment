# Workers and clock

This page explains the background work of the organisation wallet: the workers, the clock, their values, their stops and their checks.

[Back to the contents](../README.md#contents)

The wallet runs its background work as actors on the queues of Valkey. An actor is a function that a worker runs for one message. The service and config pods send the messages of their requests after the commit. A job that nothing else repairs (for example a credential offer) is also a row in the database, until a worker ran it. The clock sends the messages of the cron actors when their time comes. Valkey is never a record: after a loss of Valkey, the actors find their work again in the database.

| Deployment | Command | Replicas (default) | Database role | NATS user | Valkey user | Port |
| --- | --- | --- | --- | --- | --- | --- |
| `<release>-wallet-worker-<group>` | `dramatiq ows.worker.run:start` with the processes, threads, shutdown timeout and queues of the group | the group | `<prefix>_jobs` | `walletWorker` | `walletWorker` (`wallet-worker`) | 9191 |
| `<release>-wallet-clock` | `start-clock` | 2 | `<prefix>_clock` (CONNECT only) | none | `walletClock` (`wallet-clock`) | 9192 |

## Queues and worker groups

The wallet has five queues:

| Queue | Actors |
| --- | --- |
| `realtime` | the outbox relay (also the durable jobs), the audit anchors, the credential offers, the QES PDF signatures, the Android attestation status list |
| `attestation` | the WIA pools of the organisation wallet units |
| `status` | the status refresh of the held credentials |
| `kms` | the HSM signer sync and the HSM orphan check (without an HSM signer they end at once) |
| `maintenance` | the retention purge, the monthly exports of the audit log, the usage report, the deactivation of an organisation |

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

## Stops and rollouts

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

`organisationWallet.serviceMonitor.enabled: true` creates a headless Service for each worker group and for the clock (also with the pods that are not ready), and the ServiceMonitor `<release>-wallet-metrics` of `/metrics` (the CRD of the Prometheus Operator must exist). `interval` and `labels` are the values of the ServiceMonitor. With network policies, set `networkPolicy.monitoring` to your monitoring namespace: only it reaches the health ports.

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

## Users and files

- The workers connect as the jobs role `<prefix>_jobs`, the clock as the clock role `<prefix>_clock`: it can only connect (see [Database](database.md#database-roles-of-the-wallet)).
- The NATS user `walletWorker` publishes the events of the outbox relay and of the actors (see [NATS users](nats-users.md)). The clock connects to no NATS.
- The Valkey users `wallet-worker` and `wallet-clock` have the rights of the other wallet users (see [Redis](redis.md#acl-users)).
- The worker pods mount the OpenBao login, the service key, the NATS seed of their user and the files of the audit bucket (the actors of the anchors and the exports write it). The clock pods mount only the password of their database role and of their Valkey user, and the CA files. The configuration of the clock has only the log level, the database, Valkey and its health port (`check-config --role clock` of the wallet checks it).

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
