{{/*
Valkey helpers. The organisation wallet uses Valkey (or Redis) as a work
queue, a store of short-lived single-use values and a cache, never as a
record: the evidence stays in the database. redis.mode bundled: the chart
runs Valkey with Sentinel (StatefulSet <fullname>-redis; each pod has a data
container and a Sentinel container). redis.mode external: your Valkey or
Redis (the requirements are in docs/redis.md).
*/}}

{{/* "true" when a process of the release uses Valkey (the organisation wallet or the gateway), else "". */}}
{{- define "ow.redis.enabled" -}}
{{- if or .Values.organisationWallet.enabled .Values.api.enabled -}}true{{- end -}}
{{- end }}

{{/* "true" when the chart runs Valkey (redis.mode bundled and a process uses it), else "". */}}
{{- define "ow.redis.bundled" -}}
{{- $mode := .Values.redis.mode | default "bundled" -}}
{{- if not (has $mode (list "bundled" "external")) -}}
{{- fail (printf "redis.mode %q is not supported: use \"bundled\" (the chart runs Valkey) or \"external\" (your Valkey or Redis)" $mode) -}}
{{- end -}}
{{- if and (eq $mode "bundled") (include "ow.redis.enabled" .) -}}true{{- end -}}
{{- end }}

{{/* Name of the StatefulSet (and of its pods: <name>-<ordinal>). */}}
{{- define "ow.redis.name" -}}
{{ include "ow.name" (list . "redis") }}
{{- end }}

{{/* Name of the headless Service (the pod DNS names). */}}
{{- define "ow.redis.headlessName" -}}
{{ include "ow.name" (list . "redis-headless") }}
{{- end }}

{{/* Name of the Service of the Sentinels. */}}
{{- define "ow.redis.sentinelName" -}}
{{ include "ow.name" (list . "redis-sentinel") }}
{{- end }}

{{/* Name of the TLS Secret (tls.crt, tls.key, ca.crt) of the bundled Valkey. */}}
{{- define "ow.redis.tlsSecretName" -}}
{{- .Values.redis.tls.existingSecret | default (include "ow.name" (list . "redis-tls")) -}}
{{- end }}

{{/* Name of the Secret of the chart with the passwords of the ACL users. */}}
{{- define "ow.redis.usersSecretName" -}}
{{ include "ow.name" (list . "redis-users") }}
{{- end }}

{{/* The DNS domain of the pods: <headless Service>.<namespace>.svc. */}}
{{- define "ow.redis.domain" -}}
{{ include "ow.redis.headlessName" . }}.{{ .Release.Namespace }}.svc
{{- end }}

{{/* The DNS names of the pods of the bundled Valkey, pod 0 first. Output: JSON list. */}}
{{- define "ow.redis.podHosts" -}}
{{- $hosts := list -}}
{{- range $i := until (.Values.redis.replicas | int) -}}
{{- $hosts = append $hosts (printf "%s-%d.%s" (include "ow.redis.name" $) $i (include "ow.redis.domain" $)) -}}
{{- end -}}
{{- toJson $hosts -}}
{{- end }}

{{/*
The ACL users of the processes (values keys of redis.users): one user for
each wallet process kind and one for the gateway. The bundled Valkey also
has the users replication (the replicas), sentinel (the Sentinels) and
probe (the probes), with the passwords of the Secret of the chart.
*/}}
{{- define "ow.redis.processUsers" -}}
walletService,walletConfig,walletWorker,walletClock,walletScheduler,gateway
{{- end }}

{{/*
The users of the bundled Valkey itself: replication (the replicas),
sentinel (the Sentinels), probe (the probes) and, with redis.metrics, metrics
(the exporter of each pod). Their passwords are in the Secret of the chart
<fullname>-redis-users (key: the user name).
*/}}
{{- define "ow.redis.serverUsers" -}}
replication,sentinel,probe{{- if .Values.redis.metrics.enabled -}},metrics{{- end -}}
{{- end }}

{{/* The values key of the ACL user of one wallet role (service, config, worker, clock, scheduler). */}}
{{- define "ow.wallet.redisUser" -}}
{{- get (dict "service" "walletService" "config" "walletConfig" "worker" "walletWorker" "clock" "walletClock" "scheduler" "walletScheduler") . -}}
{{- end }}

{{/*
The ACL rights (the ACL file syntax). The wallet: its key namespaces (ows:*,
and the Dramatiq namespace: the key ows-wallet, which the broker script gets
as KEYS[1], and ows-wallet:*), the read, write, script and
connection commands without the dangerous ones, and INFO (the server check
of the wallet) and KEYS (the Dramatiq broker script) again. The gateway:
its key namespace gw:*. The discovery: the commands of the clients on the
Sentinels. replication, sentinel: the commands of the replicas and of the
Sentinels on the data servers. metrics: the commands of the exporter of a
pod (redis.metrics): INFO, the lengths of the slow log and the latency
events, and its client name; no key and no CONFIG. sentinelPeer: the commands of a Sentinel on
the other Sentinels, and the start and stop scripts of the pods. probe: the
probes. Output: JSON.
*/}}
{{- define "ow.redis.rights" -}}
{{- toJson (dict
  "wallet" "resetchannels ~ows:* ~ows-wallet ~ows-wallet:* -@all +@read +@write +@scripting +@connection -@dangerous +info +keys"
  "gateway" "resetchannels ~gw:* -@all +@read +@write +@connection -@dangerous"
  "discovery" "-@all +ping +auth +hello +client|setinfo +client|setname +sentinel|masters +sentinel|master +sentinel|get-master-addr-by-name +sentinel|replicas +sentinel|slaves +sentinel|sentinels"
  "replication" "-@all +psync +replconf +ping"
  "sentinel" "allchannels -@all +multi +slaveof +replicaof +ping +exec +subscribe +config|rewrite +role +publish +info +client|setname +client|kill +script|kill"
  "sentinelPeer" "resetchannels &__sentinel__:hello -@all +auth +ping +publish +client|setname +sentinel|is-master-down-by-addr +sentinel|get-master-addr-by-name +sentinel|failover"
  "probe" "-@all +ping +info"
  "metrics" "-@all +info +client|setname +slowlog|len +latency|latest +latency|histogram"
  "probeSentinel" "-@all +ping") -}}
{{- end }}

{{/*
The ACL user of one process and the Secret of its password. Call with
(list $ "<values key of redis.users>"). Output: JSON {username, secret,
key}. The password: redis.users.<key>.passwordSecret, else (bundled) the
Secret of the chart <fullname>-redis-users (key: the values key).
*/}}
{{- define "ow.redis.user" -}}
{{- $root := index . 0 -}}
{{- $key := index . 1 -}}
{{- $user := index $root.Values.redis.users $key | default dict -}}
{{- if not (regexMatch "^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$" ($user.username | default "")) -}}
{{- fail (printf "redis.users.%s.username %q is not an ACL user name: 1 to 64 letters, digits, . _ - (the first a letter or a digit)" $key ($user.username | default "")) -}}
{{- end -}}
{{- if $user.passwordSecret -}}
{{- toJson (dict "username" $user.username "secret" $user.passwordSecret "key" ($user.passwordKey | default "password")) -}}
{{- else if include "ow.redis.bundled" $root -}}
{{- toJson (dict "username" $user.username "secret" (include "ow.redis.usersSecretName" $root) "key" $key) -}}
{{- else -}}
{{- fail (printf "redis.users.%s.passwordSecret is required with redis.mode external: the Secret with the password of the ACL user %s on your server" $key $user.username) -}}
{{- end -}}
{{- end }}

{{/* The CA of the servers: the TLS Secret of the bundled Valkey, or redis.external.caSecret. Output: JSON {secret, key} or {}. */}}
{{- define "ow.redis.ca" -}}
{{- $external := .Values.redis.external -}}
{{- if include "ow.redis.bundled" . -}}
{{- toJson (dict "secret" (include "ow.redis.tlsSecretName" .) "key" "ca.crt") -}}
{{- else if $external.caSecret -}}
{{- toJson (dict "secret" $external.caSecret "key" ($external.caKey | default "ca.crt")) -}}
{{- else -}}
{{- toJson dict -}}
{{- end -}}
{{- end }}

{{/*
The Valkey groups of the wallet: queue (the group of redis.mode: the work
queue, and also the single-use values and the caches without a group of
their own), and the enabled groups state and cache (redis.state,
redis.cache: your own Valkey or Redis). Output: JSON name -> {sentinels,
address, masterName, sentinelAuth, ca ({secret, key} or {}), caFile (the
file of the CA in ow.wallet.secretDir, or "")}.
*/}}
{{- define "ow.redis.groups" -}}
{{- $r := .Values.redis -}}
{{- $ca := include "ow.redis.ca" . | fromJson -}}
{{- $queue := dict "masterName" $r.masterName "ca" $ca "caFile" (ternary "redis-ca.crt" "" (not (empty $ca.secret))) -}}
{{- if include "ow.redis.bundled" . -}}
{{- $sentinels := list -}}
{{- range $host := include "ow.redis.podHosts" . | fromJsonArray -}}
{{- $sentinels = append $sentinels (printf "%s:26379" $host) -}}
{{- end -}}
{{- $queue = merge $queue (dict "sentinels" $sentinels "address" "" "sentinelAuth" true) -}}
{{- else -}}
{{- $queue = merge $queue (dict "sentinels" ($r.external.sentinels | default list) "address" ($r.external.address | default "") "sentinelAuth" $r.external.sentinelAuth) -}}
{{- end -}}
{{- $groups := dict "queue" $queue -}}
{{- range $name := list "state" "cache" -}}
{{- $g := index $r $name -}}
{{- if $g.enabled -}}
{{- $groupCa := dict -}}
{{- if $g.caSecret -}}{{- $groupCa = dict "secret" $g.caSecret "key" ($g.caKey | default "ca.crt") -}}{{- end -}}
{{- $_ := set $groups $name (dict "sentinels" ($g.sentinels | default list) "address" ($g.address | default "") "masterName" $g.masterName "sentinelAuth" $g.sentinelAuth "ca" $groupCa "caFile" (ternary (printf "redis-%s-ca.crt" $name) "" (not (empty $g.caSecret)))) -}}
{{- end -}}
{{- end -}}
{{- toJson $groups -}}
{{- end }}

{{/*
The redis section of one wallet role (the keys of the wallet settings,
docs/redis.md): one endpoint for each group of ow.redis.groups. Without a
group state or cache, the wallet uses the endpoint queue for them. The
role logs in to each group with its ACL user and the same password. The
password and the CA files are in ow.wallet.secretDir
(ow.wallet.secretFiles). Call with (list $ "<role>"). Output: JSON.
*/}}
{{- define "ow.wallet.redis" -}}
{{- $root := index . 0 -}}
{{- $r := $root.Values.redis -}}
{{- $dir := include "ow.wallet.secretDir" $root -}}
{{- $user := include "ow.redis.user" (list $root (include "ow.wallet.redisUser" (index . 1))) | fromJson -}}
{{- $section := dict "replica_wait_milliseconds" ($r.client.replicaWaitMilliseconds | int) -}}
{{- range $name, $group := include "ow.redis.groups" $root | fromJson -}}
{{- $endpoint := dict
    "username" $user.username
    "password_file" (printf "%s/redis-password" $dir)
    "tls" true
    "connect_timeout_seconds" $r.client.connectTimeoutSeconds
    "timeout_seconds" $r.client.timeoutSeconds -}}
{{- if $group.sentinels -}}
{{- $_ := set $endpoint "sentinels" $group.sentinels -}}
{{- $_ := set $endpoint "master_name" $group.masterName -}}
{{- if $group.sentinelAuth -}}
{{- $_ := set $endpoint "sentinel_username" $user.username -}}
{{- $_ := set $endpoint "sentinel_password_file" (printf "%s/redis-password" $dir) -}}
{{- end -}}
{{- else -}}
{{- $_ := set $endpoint "address" $group.address -}}
{{- end -}}
{{- with $group.caFile -}}
{{- $_ := set $endpoint "ca_file" (printf "%s/%s" $dir .) -}}
{{- end -}}
{{- $_ := set $section $name $endpoint -}}
{{- end -}}
{{- toJson $section -}}
{{- end }}

{{/*
The files of the Valkey user of one process in its secret folder: the
password (redis-password) and the CA of the servers (redis-ca.crt). Call
with (list $ "<values key of redis.users>"). Output: JSON "<file name>" ->
{secret, key}.
*/}}
{{- define "ow.redis.secretFiles" -}}
{{- $root := index . 0 -}}
{{- $user := include "ow.redis.user" . | fromJson -}}
{{- $files := dict "redis-password" (dict "secret" $user.secret "key" $user.key) -}}
{{- with include "ow.redis.ca" $root | fromJson -}}
{{- if .secret -}}{{- $_ := set $files "redis-ca.crt" . -}}{{- end -}}
{{- end -}}
{{- toJson $files -}}
{{- end }}

{{/*
Render guards of the Valkey values. The values go into the configuration
files of Valkey and of the wallet, so the guards also allow only safe
characters. Output: nothing.
*/}}
{{- define "ow.redis.check" -}}
{{- $v := .Values -}}
{{- $r := $v.redis -}}
{{- $bundled := include "ow.redis.bundled" . -}}
{{- if not (regexMatch "^[A-Za-z0-9._-]{1,64}$" ($r.masterName | default "")) -}}
{{- fail (printf "redis.masterName %q is not a name: 1 to 64 letters, digits, . _ -" ($r.masterName | default "")) -}}
{{- end -}}
{{- $names := list -}}
{{- range $key := include "ow.redis.processUsers" . | splitList "," -}}
{{- $user := include "ow.redis.user" (list $ $key) | fromJson -}}
{{- if has $user.username $names -}}
{{- fail (printf "redis.users.%s.username %q is the user of another process: each process kind has its own ACL user" $key $user.username) -}}
{{- end -}}
{{- if and $bundled (has $user.username (list "default" "replication" "sentinel" "probe" "metrics")) -}}
{{- fail (printf "redis.users.%s.username %q is a user of the bundled Valkey itself (default, replication, sentinel, probe, metrics): choose another name" $key $user.username) -}}
{{- end -}}
{{- $names = append $names $user.username -}}
{{- end -}}
{{- if $bundled -}}
{{- $replicas := $r.replicas | int -}}
{{- if or (lt $replicas 3) (eq (mod $replicas 2) 0) -}}
{{- fail (printf "redis.replicas (%v) must be an odd number of 3 or more: the Sentinels need a majority, and the primary needs a replica for each write" $r.replicas) -}}
{{- end -}}
{{- $quorum := $r.sentinel.quorum | int -}}
{{- if or (lt $quorum 1) (gt $quorum $replicas) -}}
{{- fail (printf "redis.sentinel.quorum (%v) must be 1 to redis.replicas (%v)" $r.sentinel.quorum $r.replicas) -}}
{{- end -}}
{{- if not (regexMatch "^[1-9][0-9]*([kKmMgG][bB]?)?$" ($r.maxmemory | toString)) -}}
{{- fail (printf "redis.maxmemory %q is not a size: a number with an optional unit kb, mb or gb (for example 512mb)" ($r.maxmemory | toString)) -}}
{{- end -}}
{{- if and $r.metrics.serviceMonitor.enabled (not $r.metrics.enabled) -}}
{{- fail "redis.metrics.serviceMonitor.enabled needs redis.metrics.enabled: the ServiceMonitor scrapes the exporters of the pods" -}}
{{- end -}}
{{- else if include "ow.redis.enabled" . -}}
{{- $external := $r.external -}}
{{- if and (not $external.sentinels) (not $external.address) -}}
{{- fail "redis.external.sentinels or redis.external.address is required with redis.mode external: the Sentinels (host:port) of your Valkey or Redis, or the address of the primary of a server without Sentinel" -}}
{{- end -}}
{{- if and $external.sentinels $external.address -}}
{{- fail "set redis.external.sentinels or redis.external.address, not both" -}}
{{- end -}}
{{- range $entry := concat ($external.sentinels | default list) (ternary (list $external.address) list (not (empty $external.address))) -}}
{{- if not (regexMatch "^(\\[[0-9A-Fa-f:.]+\\]|[A-Za-z0-9.-]+):([1-9][0-9]{0,4})$" $entry) -}}
{{- fail (printf "redis.external: %q is not host:port (an IPv6 address in brackets)" $entry) -}}
{{- end -}}
{{- end -}}
{{- if and $v.networkPolicy.enabled (not $v.networkPolicy.externalRedis) -}}
{{- fail "networkPolicy.externalRedis needs the addresses of your Valkey or Redis (cidrs, and ports such as [6379, 26379]) when networkPolicy.enabled and redis.mode external: else the default deny blocks it" -}}
{{- end -}}
{{- if or $r.metrics.enabled $r.metrics.serviceMonitor.enabled -}}
{{- fail "redis.metrics is for the bundled Valkey (redis.mode bundled): monitor your own Valkey or Redis with your own exporter" -}}
{{- end -}}
{{- end -}}
{{- /* The separate groups of the wallet (redis.state, redis.cache). */ -}}
{{- if $v.organisationWallet.enabled -}}
{{- range $name := list "state" "cache" -}}
{{- $g := index $r $name -}}
{{- if $g.enabled -}}
{{- $key := printf "redis.%s" $name -}}
{{- if and (not $g.sentinels) (not $g.address) -}}
{{- fail (printf "%s.sentinels or %s.address is required with %s.enabled: the Sentinels (host:port) of the group, or the address of its primary" $key $key $key) -}}
{{- end -}}
{{- if and $g.sentinels $g.address -}}
{{- fail (printf "set %s.sentinels or %s.address, not both" $key $key) -}}
{{- end -}}
{{- range $entry := concat ($g.sentinels | default list) (ternary (list $g.address) list (not (empty $g.address))) -}}
{{- if not (regexMatch "^(\\[[0-9A-Fa-f:.]+\\]|[A-Za-z0-9.-]+):([1-9][0-9]{0,4})$" $entry) -}}
{{- fail (printf "%s: %q is not host:port (an IPv6 address in brackets)" $key $entry) -}}
{{- end -}}
{{- end -}}
{{- if and $g.sentinels (not (regexMatch "^[A-Za-z0-9._-]{1,64}$" ($g.masterName | default ""))) -}}
{{- fail (printf "%s.masterName %q is not a name: the name of the primary that the Sentinels of the group monitor (1 to 64 letters, digits, . _ -)" $key ($g.masterName | default "")) -}}
{{- end -}}
{{- if and $v.networkPolicy.enabled (not $v.networkPolicy.externalRedis) -}}
{{- fail (printf "networkPolicy.externalRedis needs the addresses of the group %s (cidrs, and ports such as [6379, 26379]) when networkPolicy.enabled and %s.enabled: else the default deny blocks it" $key $key) -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end }}

{{/*
The configuration of a data server: the template of /run/valkey/valkey.conf.
valkey.sh writes the file: it puts in the passwords ({password:<user>}), the
DNS name of the pod ({self}) and, on a replica, the line replicaof. No
secret is in the template.
*/}}
{{- define "ow.redis.serverConfig" -}}
# The data server of the bundled Valkey (the template of
# /run/valkey/valkey.conf; valkey.sh puts in the passwords and the names).
bind * -::*
port 0
tls-port 6379
tls-cert-file /etc/valkey-tls/tls.crt
tls-key-file /etc/valkey-tls/tls.key
tls-ca-cert-file /etc/valkey-tls/ca.crt
# The clients log in with their ACL user, not with a certificate.
tls-auth-clients no
# The replication and the Sentinel links also use TLS.
tls-replication yes
dir /data
aclfile /run/valkey/users.acl
# At most about one second of writes is lost when a server stops.
appendonly yes
appendfsync everysec
aof-use-rdb-preamble yes
# Never evict a key: an eviction would delete queue messages or nonces.
maxmemory {{ .Values.redis.maxmemory }}
maxmemory-policy noeviction
# A primary without a replica in sync refuses the writes: the wallet
# accepts a single-use value only when a replica has it.
min-replicas-to-write 1
min-replicas-max-lag 10
# The replication login. After a failover the old primary is a replica.
masteruser replication
masterauth {password:replication}
# The Sentinels and the clients use the pod DNS names: the pod addresses
# change.
replica-announce-ip {self}
{{- end }}

{{/*
The ACL file of a data server: the template of /run/valkey/users.acl.
valkey.sh puts in the SHA-256 of each password ({hash:<user>}).
*/}}
{{- define "ow.redis.serverAcl" -}}
{{- $rights := include "ow.redis.rights" . | fromJson -}}
user default off
{{- range $key := include "ow.redis.processUsers" . | splitList "," }}
user {{ (index $.Values.redis.users $key).username }} on {hash:{{ $key }}} {{ ternary $rights.gateway $rights.wallet (eq $key "gateway") }}
{{- end }}
user replication on {hash:replication} {{ $rights.replication }}
user sentinel on {hash:sentinel} {{ $rights.sentinel }}
user probe on {hash:probe} {{ $rights.probe }}
{{- if .Values.redis.metrics.enabled }}
user metrics on {hash:metrics} {{ $rights.metrics }}
{{- end }}
{{- end }}

{{/*
The configuration of a Sentinel: the template of /run/valkey/sentinel.conf.
sentinel.sh writes the file: it puts in the passwords, the hashes, the DNS
name of the pod ({self}) and of the primary ({primary}). The Sentinel
rewrites the file (its state).
*/}}
{{- define "ow.redis.sentinelConfig" -}}
{{- $r := .Values.redis -}}
{{- $rights := include "ow.redis.rights" . | fromJson -}}
{{- $master := $r.masterName -}}
# The Sentinel of the bundled Valkey (the template of
# /run/valkey/sentinel.conf; sentinel.sh puts in the passwords and the
# names).
bind * -::*
port 0
tls-port 26379
tls-cert-file /etc/valkey-tls/tls.crt
tls-key-file /etc/valkey-tls/tls.key
tls-ca-cert-file /etc/valkey-tls/ca.crt
tls-auth-clients no
# The links to the data servers and to the other Sentinels use TLS.
tls-replication yes
dir /run/valkey
# The Sentinels give the pod DNS names to the clients (the names of the
# server certificate).
sentinel resolve-hostnames yes
sentinel announce-hostnames yes
sentinel announce-ip {self}
sentinel announce-port 26379
sentinel sentinel-user sentinel
sentinel sentinel-pass {password:sentinel}
sentinel monitor {{ $master }} {primary} 6379 {{ $r.sentinel.quorum | int }}
sentinel down-after-milliseconds {{ $master }} {{ $r.sentinel.downAfterMilliseconds | int }}
sentinel failover-timeout {{ $master }} {{ $r.sentinel.failoverTimeoutMilliseconds | int }}
sentinel parallel-syncs {{ $master }} 1
sentinel auth-user {{ $master }} sentinel
sentinel auth-pass {{ $master }} {password:sentinel}
user default off
user sentinel on {hash:sentinel} {{ $rights.sentinelPeer }}
user probe on {hash:probe} {{ $rights.probeSentinel }}
{{- range $key := include "ow.redis.processUsers" . | splitList "," }}
user {{ (index $.Values.redis.users $key).username }} on {hash:{{ $key }}} {{ $rights.discovery }}
{{- end }}
{{- end }}
