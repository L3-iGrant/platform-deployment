# Redis

Valkey with Sentinel in the chart, and what your own Valkey or Redis server needs.

[Back to the contents](../README.md#contents)

The organisation wallet uses Valkey (a Redis-compatible server) for three things:

- the work queue of its background jobs;
- short-lived single-use values (the nonces and the proof ids that a replay check refuses the second time);
- the caches that its replicas share.

The gateway will use Valkey for the failure counters of unknown API keys. Valkey is never a record: the evidence, the audit log, the locks and the status list counters stay in the database. When Valkey is not available, the routes that need it answer 503, and the jobs run later from the database. The pods stay ready (their readiness does not depend on Valkey).

By default (`redis.mode: bundled`), the chart runs Valkey with Sentinel. With `redis.mode: external`, the processes use your Valkey or Redis (`profiles/redis-external.yaml`, see [External Valkey or Redis](#external-valkey-or-redis)).

## Bundled Valkey

The StatefulSet `<release>-redis` has 3 pods (`redis.replicas`: an odd number, 3 or more). Each pod has two containers:

- `valkey`: a data server. One data server is the primary; the others are its replicas.
- `sentinel`: a Sentinel. The Sentinels watch the primary. When the primary stops, they make a replica the new primary (a failover) and give its address to the clients.

The settings of the data servers:

| Setting | Value | Why |
| --- | --- | --- |
| `appendonly`, `appendfsync` | `yes`, `everysec` | A crash loses at most about one second of writes. |
| `maxmemory-policy` | `noeviction` | An eviction would delete queue messages or nonces. When the memory is full (`redis.maxmemory`), writes fail. |
| `min-replicas-to-write`, `min-replicas-max-lag` | `1`, `10` | A primary without an in-sync replica refuses writes. The wallet accepts a single-use value only when a replica has it (`WAIT 1`). |
| TLS | the data port 6379 and the Sentinel port 26379, and also the replication and Sentinel links | The chart's certificate names each pod and the Sentinel Service. |
| Users | no `default` user; one ACL user for each process kind (see [ACL users](#acl-users)) | Each process can use only its own keys. |
| Names | `announce-hostnames yes`: the Sentinels give out the pod DNS names (`<release>-redis-<n>.<release>-redis-headless.<namespace>.svc`) | The pod addresses change; the certificate names the pod DNS names. |

Placement and stops:

- The chart sets no pod anti-affinity and no PodDisruptionBudget for Valkey (see [Scaled deployments](scaled-deployments.md)). On a cluster with 3 or more nodes, set `redis.affinity` so that each pod runs on its own node. Then, when a node stops, the Sentinels keep their majority and the primary keeps a replica:

  ```yaml
  redis:
    affinity:
      podAntiAffinity:
        requiredDuringSchedulingIgnoredDuringExecution:
          - topologyKey: kubernetes.io/hostname
            labelSelector:
              matchLabels:
                app.kubernetes.io/component: redis
  ```

- Before the primary stops (a rolling update, a node drain), a Sentinel moves the primary to a replica (`SENTINEL FAILOVER`): writes stop only for the switch (a few seconds). An upgrade restarts one pod at a time, from the last pod to pod 0. The next pod waits until the new pod is an in-sync replica.
- A new pod asks the Sentinels for the primary and starts as its replica. At the first start of a new group, pod 0 is the primary.
- Each pod has a volume (`redis.persistence.size`, default 8 GiB) for its data.

For the objects, see [Chart objects](chart-objects.md#valkey).

Check that the group has one primary and two in-sync replicas:

```bash
kubectl -n ows get pods -l app.kubernetes.io/component=redis
kubectl -n ows exec ows-redis-0 -c valkey -- sh -c '. /etc/valkey/common.sh; cli $self 26379 sentinel SENTINEL get-master-addr-by-name ows'
```

The pods show `2/2` and `Running`. The second command shows the DNS name of the primary and `6379`.

### Site failover

Each site has its own Valkey group: the chart does not replicate Valkey to the standby site. After a failover to the standby site, the queue messages, nonces and caches of the primary site are lost. This is safe: the jobs find their work in the database again, a wallet unit asks for a new nonce, and the proof replay check refuses a proof from before the new Valkey start.

### Metrics

`redis.metrics.enabled: true` adds the container `metrics` to each Valkey pod: the Prometheus exporter of its data server ([redis_exporter](https://github.com/oliver006/redis_exporter), port 9121, `/metrics`). It connects with TLS to `127.0.0.1:6379` (a name in the certificate) and logs in as the ACL user `metrics` (see [ACL users](#acl-users)). This user reads `INFO` and the lengths of the slow log and of the latency events. It cannot read a key, the slow log arguments or the configuration, so the exporter runs with `--config-command=-`.

| Metric | Use |
| --- | --- |
| `redis_up` | The exporter can read the server. |
| `redis_memory_used_bytes`, `redis_memory_max_bytes` | The memory for the data, and `redis.maxmemory`. With `noeviction`, writes fail when the memory is full: alert well before. |
| `redis_instance_info{role}`, `redis_connected_slaves`, `redis_master_link_up` | The role of each server, and the replication. A primary without an in-sync replica refuses writes (`min-replicas-to-write 1`). |
| `redis_connected_clients`, `redis_rejected_connections_total` | The connections of the processes. |
| `redis_aof_last_bgrewrite_status`, `redis_aof_last_write_status` | The AOF of each server. |
| `redis_slowlog_length`, `redis_latency_spike_duration_seconds` | The slow commands and the latency events. |

The exporter does not read the Sentinels: the data servers show a failover in their role and their replication. The length of each queue is a worker metric (`ows_worker_queue_messages`, see [Workers and clock](workers.md#probes-and-metrics)).

`redis.metrics.serviceMonitor.enabled: true` creates the headless Service `<release>-redis-metrics` of the exporters (it includes the pods that are not ready) and the ServiceMonitor `<release>-redis-metrics` (the Prometheus Operator CRD must exist). `interval` and `labels` go to the ServiceMonitor. With network policies, set `networkPolicy.monitoring` to your monitoring namespace: only it reaches port 9121. With your own Valkey or Redis (`redis.mode: external`), use your own exporter: the chart then refuses `redis.metrics`.

The image `redis.metrics.image` is `docker.io/oliver006/redis_exporter` (MIT License, see [Images](images.md)). The exporter reads its password from the environment variable `REDIS_PASSWORD` (from the Secret `<release>-redis-users`, key `metrics`), because it reads a password only from a variable or a JSON file.

## ACL users

The wallet roles and the gateway each log in with their own user. `redis.users.<key>.username` sets the name. The password is in the chart's Secret `<release>-redis-users` (random, kept across upgrades), or in your own Secret (`redis.users.<key>.passwordSecret`, `.passwordKey`). A password contains only letters, digits and `. _ ~ + / = -`.

The keys of the Secret `<release>-redis-users` are the values keys (`walletService`, `walletConfig`, `walletWorker`, `walletClock`, `gateway`), not the user names. If your own Secret uses the user names as keys (`wallet-service`, `wallet-config`, `wallet-worker`, `wallet-clock`), give each user its key: for example `redis.users.walletWorker: {passwordSecret: <your Secret>, passwordKey: wallet-worker}`.

| User (`redis.users.<key>`) | Process | Rights on the data servers | Rights on the Sentinels |
| --- | --- | --- | --- |
| `walletService` (`wallet-service`), `walletConfig` (`wallet-config`), `walletWorker` (`wallet-worker`) and `walletClock` (`wallet-clock`) | the wallet roles (`walletWorker`: all worker groups) | `resetchannels ~ows:* ~ows-wallet ~ows-wallet:* -@all +@read +@write +@scripting +@connection -@dangerous +info +keys` | `-@all +ping +auth +hello +client\|setinfo +client\|setname +sentinel\|masters +sentinel\|master +sentinel\|get-master-addr-by-name +sentinel\|replicas +sentinel\|slaves +sentinel\|sentinels` |
| `gateway` (`gateway`) | the gateway | `resetchannels ~gw:* -@all +@read +@write +@connection -@dangerous` | the same as the wallet |

The bundled Valkey also has these users, with their passwords in the Secret `<release>-redis-users`:

| User | Rights on the data servers | Rights on the Sentinels |
| --- | --- | --- |
| `replication` | `-@all +psync +replconf +ping` (the replicas) | none |
| `sentinel` | `allchannels -@all +multi +slaveof +replicaof +ping +exec +subscribe +config\|rewrite +role +publish +info +client\|setname +client\|kill +script\|kill` | `resetchannels &__sentinel__:hello -@all +auth +ping +publish +client\|setname +sentinel\|is-master-down-by-addr +sentinel\|get-master-addr-by-name +sentinel\|failover` (the other Sentinels, and the start and stop scripts of the pods) |
| `probe` | `-@all +ping +info` | `-@all +ping` |
| `metrics` (only with `redis.metrics.enabled`) | `-@all +info +client\|setname +slowlog\|len +latency\|latest +latency\|histogram` (the exporter) | none |
| `default` | off | off |

The wallet needs `INFO`: at its start it reads `INFO` and refuses a server that is a Redis Cluster, a version before 7.2, or a queue server with an eviction policy other than `noeviction`. It needs `KEYS` and scripts for the queue (the broker script calls `KEYS`). To change a password, change the Secret, then restart the Valkey pods (`kubectl -n ows rollout restart statefulset/ows-redis`) and the processes of that user.

## The settings of the wallet

The chart writes the `redis` section of each wallet role (`service`, `config`, each worker group, `clock`): the Sentinels, the primary name, the role's user, its password file and the CA. Without separate groups, the wallet also uses this one server for the single-use values (`state`) and the caches (`cache`). With `redis.state` or `redis.cache`, the section also has the endpoint `state` or `cache`, with the same keys (see [Separate groups](#separate-groups-for-the-single-use-values-and-the-caches)).

```yaml
redis:
  queue:
    sentinels: [ows-redis-0.ows-redis-headless.ows.svc:26379, ows-redis-1.ows-redis-headless.ows.svc:26379, ows-redis-2.ows-redis-headless.ows.svc:26379]
    master_name: ows
    username: wallet-service
    password_file: /run/secrets/eudi-wallet/redis-password
    sentinel_username: wallet-service
    sentinel_password_file: /run/secrets/eudi-wallet/redis-password
    tls: true
    ca_file: /run/secrets/eudi-wallet/redis-ca.crt
    connect_timeout_seconds: 2
    timeout_seconds: 2
  replica_wait_milliseconds: 100
```

`redis.client.connectTimeoutSeconds`, `.timeoutSeconds` and `.replicaWaitMilliseconds` set the last three values. Two limits apply:

- `timeoutSeconds` has at most 3 decimals (whole milliseconds).
- `replicaWaitMilliseconds` must be at most half of it: 2 x `replicaWaitMilliseconds` <= `timeoutSeconds` x 1000, in whole milliseconds. The defaults 100 and 2 pass; 2.01 s allows 1005 ms.

A longer `WAIT` ends as a socket timeout: the client drops the connection, and while a replica stalls, each request with a proof or a nonce opens a new TLS connection to the primary. The wallet refuses such a configuration, and the render stops before that.

The gateway gets the password file of its user (`redis-password`) and the CA (`redis-ca.crt`) in its secret folder.

## External Valkey or Redis

With `redis.mode: external`, the chart runs no Valkey. Your server can be Valkey or Redis, under its own licence, if it meets these requirements:

| Requirement | Why |
| --- | --- |
| Redis 7.2 or later, or Valkey 7.2 or later | ACL users, TLS, and the commands below |
| Sentinel, or one primary with replicas; a single-shard Redis Enterprise database is also accepted. **Not Redis Cluster** (sharded). | The broker script of the queue builds key names inside the script and calls `KEYS` |
| `EVAL`/`EVALSHA`, `KEYS`, `WAIT`, `SET NX EX` and `INFO` allowed for the wallet users (the rights of [ACL users](#acl-users)) | The queue; the replica confirmation of the single-use values (`WAIT 1`); the start check reads `INFO` |
| At least one replica and `min-replicas-to-write 1`; at national scale, two replicas or more | A single-use value counts only when it reaches a replica (`WAIT 1`: one replica is enough). With only one replica, a stall or restart of that replica longer than `redis.client.replicaWaitMilliseconds` gives 503 on every route that checks a proof or a nonce, in every pod. With two replicas, the other one confirms. |
| `maxmemory-policy noeviction` and AOF `everysec` | An eviction would delete queue messages or nonces |
| TLS, and one ACL user for each process kind (`redis.users`) | Security |

The values (see `profiles/redis-external.yaml`):

| Value | Description |
| --- | --- |
| `redis.external.sentinels` | The Sentinels (`host:port`). They monitor the primary `redis.masterName`. |
| `redis.external.address` | Without Sentinel: the address (`host:port`) of the primary, for a server that keeps its address across a failover. Set `sentinels` or `address`. |
| `redis.external.sentinelAuth` | `true` (default): the processes log in to the Sentinels with their user. `false`: your Sentinels accept clients without a login. |
| `redis.external.caSecret`, `.caKey` | The CA of your servers. Empty: the system CAs. The certificates must name the hosts that the clients connect to: the Sentinels, and the primary and replicas that the Sentinels give out. |
| `redis.users.<key>.username`, `.passwordSecret`, `.passwordKey` | The users of the processes and the Secrets with their passwords (all required) |
| `networkPolicy.externalRedis` | With network policies: the CIDRs and ports of your servers and Sentinels (required) |

When the wallet starts, it reads `INFO` of the primary. It refuses to start when the server is a Redis Cluster, when the version is too old, or when the eviction policy is not `noeviction`. It logs a warning when AOF is off or when the primary has no replica.

## Separate groups for the single-use values and the caches

By default, one group (the `redis.mode` group, the queue) keeps the work queue, the single-use values and the caches. You can give the single-use values (`redis.state`) and the caches (`redis.cache`) a group of their own: your own Valkey or Redis, with Sentinel or one primary address. For example, a cache group can evict keys when its memory is full (`maxmemory-policy allkeys-lru`), while the queue and the single-use values stay on a group with `noeviction`. The wallet needs no code change.

| Group | Requirements |
| --- | --- |
| `redis.state` | The requirements of [External Valkey or Redis](#external-valkey-or-redis): `noeviction`, AOF `everysec`, a replica and `min-replicas-to-write 1`. The wallet refuses a state server with another eviction policy. |
| `redis.cache` | Redis or Valkey 7.2 or later (not Redis Cluster), TLS, and the wallet's ACL users. Any eviction policy; AOF and replicas are not necessary: the wallet fills the caches again after a loss. |

The values of each group:

| Value | Description |
| --- | --- |
| `redis.state.enabled`, `redis.cache.enabled` | `true`: the wallet uses the group |
| `.sentinels`, `.masterName` | The Sentinels (`host:port`) of the group and the name of the primary that they monitor |
| `.address` | Without Sentinel: the address (`host:port`) of the primary. Set `sentinels` or `address`. |
| `.sentinelAuth` | `true` (default): the processes log in to the Sentinels with their user |
| `.caSecret`, `.caKey` | The CA of the group. Empty: the system CAs. |

The wallet processes log in to each group with their ACL users of `redis.users` and the same passwords (from `redis.users.<key>.passwordSecret`, or from the Secret `<release>-redis-users` of the bundled Valkey). Create these users on the group with the rights of the wallet users (see [ACL users](#acl-users)): `walletService`, `walletConfig`, `walletWorker` and `walletClock`. The gateway and KEDA use only the queue group.

Each wallet file then has the endpoints `state` and `cache` (see [The settings of the wallet](#the-settings-of-the-wallet)), and the wallet pods mount the CA of each group (`redis-state-ca.crt`, `redis-cache-ca.crt`). With network policies, add the addresses of the groups to `networkPolicy.externalRedis`: when Valkey is bundled, the chart gives them only to the wallet roles. The render stops when a group has neither `sentinels` nor `address`, or has both; when a Sentinel group has no `masterName`; or when network policies are on and `networkPolicy.externalRedis` is not set.
