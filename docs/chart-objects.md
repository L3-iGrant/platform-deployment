# Chart objects

This page lists the objects that the chart creates for OpenBao, for Valkey and for the workers and the clock of the wallet. For the Secrets of the keys and the passwords, see [Keys](keys.md).

[Back to the contents](../README.md#contents)

## OpenBao

The objects of the bundled OpenBao (`openbao.mode: bundled`):

| Object | Function |
| --- | --- |
| `<release>-openbao` (StatefulSet, Service, ConfigMap) | OpenBao with raft storage, its configuration, the entrypoint and `bootstrap.sh` |
| `<release>-openbao-headless` (Service) | The pod names of the raft nodes |
| `<release>-openbao-tls` (Secret) | The CA and the certificate of the listener (10 years). To use your own certificate, set `openbao.tls.existingSecret`. |
| `<release>-openbao-wallet` (Secret) | The password of the user `wallet` (random); `bootstrap.sh` sets it in OpenBao |

New certificates: delete the Secret `<release>-openbao-tls`, run `helm upgrade`, then restart the OpenBao pods and the wallet pods.

## Valkey

The objects of the bundled Valkey (`redis.mode: bundled`, see [Redis](redis.md)). They are normal resources of the release, not hooks:

| Object | Function |
| --- | --- |
| `<release>-redis` (StatefulSet, ConfigMap) | The pods (in each pod the containers `valkey` and `sentinel`), the templates of the configuration files and the scripts of the pods: the start of the data server and of the Sentinel, the probes, and the failover before the primary stops |
| `<release>-redis-headless` (Service) | The pod DNS names (ports 6379 and 26379), also before the pods are ready |
| `<release>-redis-sentinel` (Service) | The Sentinels of the ready pods (port 26379) |
| `<release>-redis-users` (Secret) | The passwords of the ACL users (random, kept across upgrades): the users of the processes without their own Secret, and `replication`, `sentinel` and `probe` |
| `<release>-redis-tls` (Secret) | The CA and the certificate of the servers and the Sentinels (10 years). To use your own certificate, set `redis.tls.existingSecret`. |
| `data-<release>-redis-<n>` (PersistentVolumeClaim) | The data of each pod (the AOF files) |

The configuration files with the passwords are in memory in each pod (an `emptyDir` with the medium `Memory`), never in the ConfigMap or on the data volume.

New certificates: delete the Secret `<release>-redis-tls`, run `helm upgrade`, then restart the Valkey pods (`kubectl -n ows rollout restart statefulset/ows-redis`), the wallet pods and the gateway pods.

## Workers and clock

The objects of the background work of the wallet (see [Workers and clock](workers.md)):

| Object | Function |
| --- | --- |
| `<release>-wallet-worker-<group>` (Deployment) | The workers of one group of `organisationWallet.workers.groups`: `dramatiq ows.worker.run:start` with the queues of the group, the port 9191 and an `emptyDir` in memory for the heartbeat and metric files of its worker processes |
| `<release>-wallet-clock` (Deployment) | The clock: `start-clock` in 2 replicas, the port 9192 |
| The keys `worker-<group>.yaml` and `clock.yaml` of the ConfigMap `<release>-wallet` | The configuration of each worker group and of the clock |
| `<release>-wallet-worker-<group>`, `<release>-wallet-clock` (headless Services), `<release>-wallet-metrics` (ServiceMonitor) | Only with `organisationWallet.serviceMonitor.enabled`: the scrape of `/metrics` |

The worker and clock pods mount no service account token.

## NATS

| Object | Function |
| --- | --- |
| `<release>-nats-tls` (Secret) | The CA and the certificate of the bundled NATS (10 years): the TLS of the clients and the mutual TLS of the routes. To use your own certificate, set `nats.tls.existingSecret` |
