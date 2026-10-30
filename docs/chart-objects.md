# Chart objects

This page lists the objects that the chart creates for OpenBao and for Valkey. For the Secrets of the keys and the passwords, see [Keys](keys.md).

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
