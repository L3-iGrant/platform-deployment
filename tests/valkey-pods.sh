#!/usr/bin/env bash
# Tests the bundled Valkey pods against a real server, without a cluster.
# Three containers of a local image play the three pods of the StatefulSet
# <release>-redis. Each runs one pod's data server and Sentinel with the
# files of a "helm template" of this chart (the ConfigMap with the templates
# and scripts, the TLS Secret, the users Secret), the pod environment and the
# pod DNS names (in /etc/hosts). As in a pod, the two servers of a container
# share one network namespace.
#
# The checks:
# 1. First start of the group: pod 0 is the primary and the other pods are
#    its replicas; all pods are ready (probe.sh); the Sentinels agree, log in
#    to each other and report the replicas by pod DNS name; the settings
#    (AOF, noeviction, min-replicas-to-write); the password files have mode
#    600 and no template field is left.
# 2. ACL users: the rights of the wallet (also the key ows-wallet of the
#    broker script), the gateway, the exporter (metrics) and the probe; no
#    login without a user.
# 3. Planned stop of the primary (prestop.sh): a replica becomes the
#    primary, and a new pod 0 joins as a replica.
# 4. Unplanned stop of the primary (docker pause): the Sentinels promote a
#    replica, it accepts a single-use value (WAIT 1), and the old primary
#    comes back as a replica.
# 5. All Sentinels restart with no state: they monitor the running primary.
# 6. All pods restart at the same time (the data stays): one primary, the
#    Sentinels agree, and the AOF data is still there.
#
# Usage: tests/valkey-pods.sh <image>
#   <image>: a local image of Valkey (or Redis) 7.2 or later, for example
#   valkey/valkey:8.1.11-alpine (the chart's redis.image). The script never
#   pulls (--pull never). For an image without valkey-server and valkey-cli
#   (Redis), the script links them to redis-server and redis-cli. The
#   containers have unique names, and the script removes them at the end.
set -euo pipefail

image="${1:?usage: tests/valkey-pods.sh <image>}"
here="$(cd "$(dirname "$0")" && pwd)"
chart="$(dirname "$here")"
profiles="$chart/profiles"
keys="$here/values/keys.yaml"
# profiles/site.yaml plus the release tag of the tests.
site=(-f "$profiles/site.yaml" -f "$here/values/release.yaml")
work="$(mktemp -d)"
prefix="valkey-pods-test-$(openssl rand -hex 4)"
domain=t-redis-headless.ow.svc
hosts="t-redis-0.$domain t-redis-1.$domain t-redis-2.$domain"
pass=0
fail=0
ok() { pass=$((pass + 1)); echo "ok   $1"; }
bad() { fail=$((fail + 1)); echo "FAIL $1"; }

cleanup() {
  for i in 0 1 2; do
    if [ "$fail" -gt 0 ]; then
      for log in valkey sentinel; do
        echo "--- t-redis-$i $log"
        docker exec "$prefix-$i" tail -n 20 "/tmp/$log.log" 2> /dev/null || true
      done
    fi
    docker rm -f "$prefix-$i" > /dev/null 2>&1 || true
  done
  rm -rf "$work"
}
trap cleanup EXIT

docker image inspect "$image" > /dev/null 2>&1 || { echo "the image $image is not local: the test never pulls" >&2; exit 2; }

# The pod files from a render of the chart (release t, namespace ow), with
# the exporter on (ACL user metrics).
helm template t "$chart" --namespace ow -f "$keys" "${site[@]}" \
  -f "$profiles/exposure-none.yaml" --set redis.metrics.enabled=true > "$work/render.yaml"
python3 - "$work/render.yaml" "$work" <<'PY'
import base64, os, sys, yaml
docs = [d for d in yaml.safe_load_all(open(sys.argv[1])) if d]
work = sys.argv[2]
def find(kind, name):
    return next(d for d in docs if d["kind"] == kind and d["metadata"]["name"] == name)
for folder, doc, encoded in (("cm", find("ConfigMap", "t-redis"), False), ("tls", find("Secret", "t-redis-tls"), True),
                             ("users", find("Secret", "t-redis-users"), True)):
    os.makedirs(f"{work}/{folder}")
    os.chmod(f"{work}/{folder}", 0o755)
    for key, value in doc["data"].items():
        with open(f"{work}/{folder}/{key}", "wb") as handle:
            handle.write(base64.b64decode(value) if encoded else value.encode())
        # Make the test files readable by the image's user (in a pod they
        # have mode 0440 and the fsGroup group).
        os.chmod(f"{work}/{folder}/{key}", 0o644)
PY

for i in 0 1 2; do
  docker run -d --pull never --name "$prefix-$i" --memory 192m \
    -e POD_NAME="t-redis-$i" -e VALKEY_DOMAIN="$domain" -e VALKEY_HOSTS="$hosts" -e VALKEY_MASTER_NAME=ows \
    -v "$work/cm:/etc/valkey:ro" -v "$work/tls:/etc/valkey-tls:ro" -v "$work/users:/etc/valkey-users:ro" \
    --tmpfs /run/valkey:uid=999,gid=1000,mode=0700 --tmpfs /data:uid=999,gid=1000,mode=0700 \
    --entrypoint sh "$image" -c 'sleep infinity' > /dev/null
done
entries=""
for i in 0 1 2; do
  entries="$entries$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$prefix-$i") t-redis-$i.$domain"$'\n'
done
for i in 0 1 2; do
  docker exec -u root "$prefix-$i" sh -c "printf '%s' '$entries' >> /etc/hosts
    for program in server cli; do
      command -v valkey-\$program > /dev/null || ln -s \"\$(command -v redis-\$program)\" /usr/local/bin/valkey-\$program
    done"
done
echo "server: $(docker exec "$prefix-0" valkey-server --version)"

as_valkey() { docker exec -u 999:1000 "$prefix-$1" sh -c "$2"; }
start_data() { docker exec -d -u 999:1000 "$prefix-$1" sh -c 'sh /etc/valkey/valkey.sh >> /tmp/valkey.log 2>&1'; }
start_sentinel() { docker exec -d -u 999:1000 "$prefix-$1" sh -c 'sh /etc/valkey/sentinel.sh >> /tmp/sentinel.log 2>&1'; }
# Simulates a new pod: the processes stop and the emptyDir is emptied;
# /data stays.
stop_pod() { docker exec -u root "$prefix-$1" sh -c 'pkill -9 -f "[v]alkey-server" || true; sleep 1; rm -rf /run/valkey/*'; }
# q <pod> <commands>: runs shell commands in the pod with the common.sh
# functions.
q() { as_valkey "$1" ". /etc/valkey/common.sh; $2" 2>&1 | tr -d '\r'; }
# as_user <pod> <values key> <ACL user> <host> <port> <command>...: runs one
# command as the ACL user of a process.
as_user() {
  local pod="$1" key="$2" user="$3" host="$4" port="$5"
  shift 5
  q "$pod" "REDISCLI_AUTH=\$(password $key) valkey-cli --tls --cacert /etc/valkey-tls/ca.crt -h $host -p $port -t 2 --user $user $*"
}
role_of() { q "$1" "cli t-redis-$1.$domain 6379 sentinel ROLE" | head -n 1; }
primary_of_sentinel() { q "$1" "cli t-redis-$1.$domain 26379 sentinel SENTINEL get-master-addr-by-name ows" | head -n 1; }
wait_until() {
  local what="$1" seconds="$2" check="$3"
  local end=$((SECONDS + seconds))
  while [ "$SECONDS" -lt "$end" ]; do
    if eval "$check" > /dev/null 2>&1; then ok "$what"; return 0; fi
    sleep 1
  done
  bad "$what (after ${seconds}s)"
}
all_ready() {
  for i in 0 1 2; do
    as_valkey "$i" 'sh /etc/valkey/probe.sh ready && sh /etc/valkey/probe.sh alive 6379 && sh /etc/valkey/probe.sh alive 26379' || return 1
  done
}
sentinels_agree() {
  for i in 0 1 2; do [ "$(primary_of_sentinel "$i")" = "$1" ] || return 1; done
}
current_primary() {
  for i in 0 1 2; do
    if [ "$(role_of "$i")" = master ]; then echo "$i"; fi
  done
}
peers_known() {
  for i in 0 1 2; do
    [ "$(as_user "$i" walletService wallet-service "t-redis-$i.$domain" 26379 SENTINEL SENTINELS ows \
      | grep -c -E '^t-redis-[0-9]\.[^:]*$' || true)" = 2 ] || return 1
  done
}

# --- 1. First start of the group -------------------------------------------------
for i in 0 1 2; do start_data "$i"; start_sentinel "$i"; done
wait_until "start: all pods ready" 90 all_ready
wait_until "start: the Sentinels agree on pod 0" 30 "sentinels_agree t-redis-0.$domain"
[ "$(current_primary | tr '\n' ' ')" = "0 " ] && ok "start: one primary, pod 0" || bad "start: the primaries are $(current_primary | tr '\n' ' ')"
wait_until "start: each Sentinel knows the 2 other Sentinels (ACL user sentinel)" 60 peers_known
replicas="$(as_user 2 walletService wallet-service "t-redis-2.$domain" 26379 SENTINEL REPLICAS ows \
  | awk 'NR % 2 == 1 { key = $0; next } key == "ip" { print }' | sort | tr '\n' ' ' || true)"
[ "$replicas" = "t-redis-1.$domain t-redis-2.$domain " ] && ok "start: the Sentinels report the replicas by pod DNS name" || bad "start: the replicas are $replicas"
info="$(q 0 "cli t-redis-0.$domain 6379 probe INFO")"
for setting in aof_enabled:1 maxmemory_policy:noeviction min_slaves_good_slaves:2; do
  grep -q "^$setting" <<< "$info" && ok "settings: $setting" || bad "settings: no $setting"
done
as_valkey 0 'test "$(stat -c %a /run/valkey/valkey.conf)" = 600 && test "$(stat -c %a /run/valkey/sentinel.conf)" = 600' \
  && ok "settings: the password files have mode 600" || bad "settings: wrong mode on the password files"
as_valkey 0 'grep -q "{password:\|{hash:\|{self}\|{primary}" /run/valkey/valkey.conf /run/valkey/users.acl /run/valkey/sentinel.conf' \
  && bad "settings: a template field is left" || ok "settings: no template field is left"

# --- 2. ACL users ----------------------------------------------------------------
primary="t-redis-0.$domain"
wallet() { as_user 2 walletService wallet-service "$primary" "${2:-6379}" "$1"; }
gateway() { as_user 2 gateway gateway "$primary" "${2:-6379}" "$1"; }
session="$(q 2 "printf 'SET ows:n:wp:o1:h1 1 NX EX 300\nWAIT 1 1000\nSET ows:test:persist 1\n' \
  | REDISCLI_AUTH=\$(password walletService) valkey-cli --tls --cacert /etc/valkey-tls/ca.crt -h $primary -p 6379 -t 2 --user wallet-service")"
printf '%s' "$session" | head -n 2 | tr '\n' ' ' | grep -q -E '^OK [12] $' && ok "wallet: SET NX and WAIT 1 (a replica confirms)" \
  || bad "wallet: the session returns $(printf '%s' "$session" | tr '\n' ' ')"
wallet "SET other:key 1" | grep -q NOPERM && ok "wallet: no key outside ows:* and ows-wallet" || bad "wallet: can write a key outside its namespace"
wallet "CONFIG GET maxmemory" | grep -q NOPERM && ok "wallet: no CONFIG" || bad "wallet: CONFIG is allowed"
wallet "KEYS ows-wallet:*" | grep -q -v NOPERM && ok "wallet: KEYS (the broker script)" || bad "wallet: KEYS fails"
wallet "INFO server" | grep -q -E "^(redis|valkey)_version" && ok "wallet: INFO (the server check)" || bad "wallet: INFO fails"
wallet "EVAL \"return redis.call('SET', KEYS[1], '1')\" 1 ows-wallet:test" | grep -q OK && ok "wallet: EVAL on a key in ows-wallet:*" || bad "wallet: EVAL on ows-wallet:* fails"
[ "$(wallet "EVAL \"return redis.call('EXISTS', KEYS[1])\" 1 ows-wallet")" = 0 ] && ok "wallet: EVAL with the key ows-wallet (KEYS[1] of the broker script)" \
  || bad "wallet: EVAL with the key ows-wallet"
wallet "SENTINEL get-master-addr-by-name ows" 26379 | grep -q "^$primary$" && ok "wallet: the Sentinel reports the primary" || bad "wallet: Sentinel discovery fails"
wallet "SENTINEL FAILOVER ows" 26379 | grep -q NOPERM && ok "wallet: no SENTINEL FAILOVER" || bad "wallet: SENTINEL FAILOVER is allowed"
[ "$(gateway "INCR gw:authfail:x")" = 1 ] && ok "gateway: INCR in gw:*" || bad "gateway: INCR in gw:* fails"
[ "$(gateway "EXPIRE gw:authfail:x 60 NX")" = 1 ] && ok "gateway: EXPIRE NX" || bad "gateway: EXPIRE NX fails"
gateway "SET ows:n:wp:o1:h2 1" | grep -q NOPERM && ok "gateway: no access to wallet keys" || bad "gateway: can write a wallet key"
gateway "SENTINEL get-master-addr-by-name ows" 26379 | grep -q "^$primary$" && ok "gateway: the Sentinel reports the primary" || bad "gateway: Sentinel discovery fails"
metrics() { as_user 2 metrics metrics "$primary" 6379 "$1"; }
# A here-string: with pipefail, "metrics | grep -q" on the long INFO ALL
# output fails when grep stops at the first line (the writer gets SIGPIPE).
info="$(metrics "INFO ALL")"
grep -q -E "^(redis|valkey)_version" <<< "$info" && ok "metrics: INFO ALL (the exporter)" || bad "metrics: INFO ALL: $(head -c 200 <<< "$info")"
metrics "SLOWLOG LEN" | grep -q -E "^[0-9]+$" && ok "metrics: SLOWLOG LEN" || bad "metrics: SLOWLOG LEN fails"
for command in "LATENCY LATEST" "LATENCY HISTOGRAM SET" "CLIENT SETNAME redis_exporter"; do
  metrics "$command" | grep -q -E "NOPERM|ERR" && bad "metrics: $command is refused" || ok "metrics: $command"
done
for command in "GET ows:test:persist" "CONFIG GET maxmemory" "SLOWLOG GET 1" "CLIENT LIST" "KEYS ows:x"; do
  metrics "$command" | grep -q NOPERM && ok "metrics: no $command" || bad "metrics: $command is allowed"
done
q 2 "cli $primary 6379 probe GET ows:test:persist" | grep -q NOPERM && ok "probe: no GET" || bad "probe: GET is allowed"
q 2 "REDISCLI_AUTH=x valkey-cli --tls --cacert /etc/valkey-tls/ca.crt -h $primary -p 6379 -t 2 PING" | grep -q -E "NOAUTH|WRONGPASS|AUTH" \
  && ok "default: no login without a user" || bad "default: login without a user works"

# --- 3. Planned stop of the primary (preStop) -----------------------------------------
start=$SECONDS
as_valkey 0 'sh /etc/valkey/prestop.sh'
took=$((SECONDS - start))
if [ "$(role_of 0)" = slave ]; then ok "prestop: the old primary is a replica after ${took}s"; else bad "prestop: pod 0 is $(role_of 0) after ${took}s"; fi
new="$(current_primary | head -n 1)"
if [ -n "$new" ] && [ "$new" != 0 ]; then ok "prestop: the new primary is pod $new"; else bad "prestop: no new primary"; new=1; fi
wait_until "prestop: the Sentinels agree on pod $new" 30 "sentinels_agree t-redis-$new.$domain"
stop_pod 0
start_data 0
start_sentinel 0
wait_until "prestop: the new pod 0 joins, all pods ready" 60 all_ready
[ "$(role_of 0)" = slave ] && ok "prestop: pod 0 is a replica of pod $new" || bad "prestop: pod 0 is $(role_of 0)"
wait_until "prestop: pod 0's new Sentinel reports pod $new" 30 "[ \"\$(primary_of_sentinel 0)\" = t-redis-$new.$domain ]"

# --- 4. Unplanned stop of the primary ---------------------------------------------
old=$new
docker pause "$prefix-$old" > /dev/null
others=""
for i in 0 1 2; do [ "$i" != "$old" ] && others="${others:+$others }$i"; done
failover_done() {
  for i in $others; do
    p="$(primary_of_sentinel "$i")"
    [ -n "$p" ] && [ "$p" != "t-redis-$old.$domain" ] || return 1
  done
}
wait_until "failure: the Sentinels promote a replica after pod $old stops" 60 failover_done
new="$(primary_of_sentinel "${others%% *}" | sed 's/^t-redis-\([0-9]\).*/\1/')"
session="$(q "$new" "printf 'SET ows:n:wp:o1:h3 1 NX EX 300\nWAIT 1 1000\n' \
  | REDISCLI_AUTH=\$(password walletService) valkey-cli --tls --cacert /etc/valkey-tls/ca.crt -h t-redis-$new.$domain -p 6379 -t 2 --user wallet-service")"
printf '%s' "$session" | tr '\n' ' ' | grep -q -E '^OK 1 ?$' && ok "failure: the new primary (pod $new) accepts a single-use value with one replica" \
  || bad "failure: the session returns $(printf '%s' "$session" | tr '\n' ' ')"
docker unpause "$prefix-$old" > /dev/null
wait_until "failure: the old primary (pod $old) becomes a replica" 60 "[ \"\$(role_of $old)\" = slave ]"
wait_until "failure: all pods ready" 60 all_ready

# --- 5. All Sentinels restart with no state; the primary is not pod 0 --------------
primary_pod="$(current_primary | head -n 1)"
if [ "$primary_pod" = 0 ]; then
  as_valkey 0 'sh /etc/valkey/prestop.sh'
  primary_pod="$(current_primary | head -n 1)"
fi
for i in 0 1 2; do docker exec -u root "$prefix-$i" sh -c 'pkill -9 -f "2637[9]" || true; rm -f /run/valkey/sentinel.conf'; done
sleep 1
for i in 0 1 2; do start_sentinel "$i"; done
wait_until "sentinels: the new Sentinels monitor the running primary pod $primary_pod" 60 "sentinels_agree t-redis-$primary_pod.$domain"

# --- 6. All pods restart at the same time (the data stays) --------------------------
for i in 0 1 2; do stop_pod "$i"; done
for i in 0 1 2; do start_data "$i"; start_sentinel "$i"; done
wait_until "restart: all pods ready" 90 all_ready
primaries="$(current_primary | tr '\n' ' ')"
[ "$(printf '%s' "$primaries" | wc -w | tr -d ' ')" = 1 ] && ok "restart: one primary (pod ${primaries% })" || bad "restart: the primaries are $primaries"
p="${primaries%% *}"
wait_until "restart: the Sentinels agree on pod $p" 30 "sentinels_agree t-redis-$p.$domain"
[ "$(as_user "$p" walletService wallet-service "t-redis-$p.$domain" 6379 GET ows:test:persist)" = 1 ] \
  && ok "restart: the AOF data is still there" || bad "restart: the data is lost"

echo "result: ${pass} passed, ${fail} failed"
[ "$fail" -eq 0 ]
