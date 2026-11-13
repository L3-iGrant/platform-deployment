#!/usr/bin/env bash
# Test of the Valkey services of docker-compose/ (valkey, valkey-replica,
# valkey-sentinel) against a real server. The script reads the services
# from "docker compose config" (the image, the user, the entrypoint and
# command, the tmpfs, the configuration files, the healthchecks and the
# security settings: the read-only root file system, the dropped
# capabilities and no-new-privileges) and runs each in a container of a
# local image with these settings, with test passwords in place of
# secrets/valkey/, a new volume of the test for each volume of the service
# (the root file system is read-only), on a network of the test where each
# container has its service name. It starts them in the order of
# depends_on.
#
# The checks:
# 1. The start: each service is healthy (its healthcheck), the replica is
#    in sync, the Sentinel gives valkey as the primary; the files with the
#    passwords have the mode 600 and no field is left.
# 2. The ACL users: the rights of the wallet (also the key ows-wallet of the
#    broker script) and of the gateway, the Sentinel login of the wallet,
#    and the redis section of each wallet role (the user of the role).
# 3. A failover: the primary stops (docker pause), the Sentinel promotes
#    valkey-replica, and valkey comes back as its replica; a new start of
#    valkey asks the Sentinel and starts as a replica of valkey-replica,
#    which then takes a single-use value (WAIT 1).
#
# Usage: tests/compose-valkey.sh <image>
#   <image>: a local image of Valkey 7.2 or later (the services run as its
#   user valkey), for example the VALKEY_IMAGE of docker-compose/.env.example.
#   The script never pulls (--pull never). The containers have unique names
#   and the script removes them at the end. On a shared Docker host, run it
#   inside your lock of the Docker tests.
set -euo pipefail

image="${1:?usage: tests/compose-valkey.sh <image>}"
here="$(cd "$(dirname "$0")" && pwd)"
compose="$(dirname "$here")/docker-compose"
work="$(mktemp -d)"
prefix="compose-valkey-test-$(openssl rand -hex 4)"
services=(valkey valkey-replica valkey-sentinel)
pass=0
fail=0
ok() { pass=$((pass + 1)); echo "ok   $1"; }
bad() { fail=$((fail + 1)); echo "FAIL $1"; }
created_env=""
created_generated=""

cleanup() {
  local service
  for service in "${services[@]}"; do
    if [ "$fail" -gt 0 ]; then
      echo "--- $service"
      docker exec "$prefix-$service" tail -n 20 /tmp/service.log 2> /dev/null || true
    fi
    docker rm -f "$prefix-$service" > /dev/null 2>&1 || true
  done
  docker network rm "$prefix" > /dev/null 2>&1 || true
  if [ -f "$work/volumes" ]; then
    xargs -r docker volume rm < "$work/volumes" > /dev/null 2>&1 || true
  fi
  [ -z "$created_env" ] || rm -f "$compose/.env"
  [ -z "$created_generated" ] || rm -rf "$compose/generated"
  rm -rf "$work"
}
trap cleanup EXIT

docker image inspect "$image" > /dev/null 2>&1 || { echo "the image $image is not local: the test never pulls" >&2; exit 2; }

if [ ! -f "$compose/.env" ]; then
  cp "$compose/.env.example" "$compose/.env"
  created_env=1
fi
# The project needs the files of make configs (generated/configs.env).
[ -d "$compose/generated" ] || created_generated=1
(cd "$compose" && python3 -I ./render-configs.py > /dev/null)
(cd "$compose" && VALKEY_IMAGE="$image" docker compose config --format json) > "$work/project.json"

# The arguments of docker run and of docker exec of each service: one file
# of lines for each. The secret files of the services are test passwords.
python3 - "$work" "$prefix" <<'PY'
import json, os, secrets, sys
work, prefix = sys.argv[1], sys.argv[2]
volumes = []
project = json.load(open(f"{work}/project.json"))
os.makedirs(f"{work}/secrets")
os.chmod(f"{work}/secrets", 0o755)
for name in ("valkey", "valkey-replica", "valkey-sentinel"):
    service = project["services"][name]
    run = ["--user", service["user"], "--network-alias", name]
    if service.get("read_only"):
        run += ["--read-only"]
    for capability in service.get("cap_drop", []):
        run += ["--cap-drop", capability]
    for capability in service.get("cap_add", []):
        run += ["--cap-add", capability]
    for option in service.get("security_opt", []):
        run += ["--security-opt", option]
    for tmpfs in service.get("tmpfs", []):
        run += ["--tmpfs", tmpfs]
    for index, volume in enumerate(v for v in service.get("volumes", []) if v.get("type") == "volume"):
        volumes.append(f"{prefix}-{name}-{index}")
        run += ["-v", f"{volumes[-1]}:{volume['target']}"]
    for config in service.get("configs", []):
        run += ["-v", f"{project['configs'][config['source']]['file']}:{config['target']}:ro"]
    for secret in service.get("secrets", []):
        path = f"{work}/secrets/{secret['source']}"
        if not os.path.exists(path):
            with open(path, "w") as handle:
                handle.write(secrets.token_hex(24))
            os.chmod(path, 0o644)
        run += ["-v", f"{path}:{secret['target']}:ro"]
    with open(f"{work}/{name}.run", "w") as handle:
        handle.write("\n".join(run) + "\n")
    with open(f"{work}/{name}.start", "w") as handle:
        handle.write("\n".join(service["entrypoint"] + service["command"]) + "\n")
    test = service["healthcheck"]["test"]
    assert test[0] == "CMD-SHELL"
    # docker compose config writes $$ for the $ of the healthcheck.
    with open(f"{work}/{name}.health", "w") as handle:
        handle.write(test[1].replace("$$", "$"))
with open(f"{work}/volumes", "w") as handle:
    handle.write("".join(f"{volume}\n" for volume in volumes))
PY

# A network of the test: each container has its service name (the DNS of
# Docker), as in the Compose network.
docker network create "$prefix" > /dev/null
for service in "${services[@]}"; do
  run=()
  while IFS= read -r line; do run+=("$line"); done < "$work/$service.run"
  docker run -d --pull never --name "$prefix-$service" --network "$prefix" --memory 128m "${run[@]}" --entrypoint sh "$image" -c 'sleep infinity' > /dev/null
done
echo "server: $(docker exec "$prefix-valkey" valkey-server --version)"
docker inspect -f '{{.HostConfig.ReadonlyRootfs}} {{.HostConfig.CapDrop}} {{.HostConfig.SecurityOpt}} {{.Config.User}}' "$prefix-valkey" \
  | grep -q -F 'true [ALL] [no-new-privileges:true] 999:1000' \
  && ok "start: the containers have the settings of the services (read-only, no capability, no new privileges, 999:1000)" \
  || bad "start: the containers have not the settings of the services"

start() {
  local start_args=() line
  while IFS= read -r line; do start_args+=("$line"); done < "$work/$1.start"
  docker exec -d "$prefix-$1" sh -c "$(printf '%q ' "${start_args[@]}") >> /tmp/service.log 2>&1"
}
healthy() { docker exec "$prefix-$1" sh -c "$(cat "$work/$1.health")" > /dev/null 2>&1; }
wait_until() {
  local what="$1" seconds="$2" check="$3"
  local end=$((SECONDS + seconds))
  while [ "$SECONDS" -lt "$end" ]; do
    if eval "$check" > /dev/null 2>&1; then ok "$what"; return 0; fi
    sleep 1
  done
  bad "$what (after ${seconds}s)"
}
# as <service> <user> <host> <port> <command>...: one command as an ACL user
# (its password is the file of its secret).
as() {
  local service="$1" user="$2" host="$3" port="$4"
  shift 4
  docker exec "$prefix-$service" sh -c "REDISCLI_AUTH=\"\$(cat /run/secrets/valkey/$user)\" valkey-cli -h $host -p $port -t 2 --user $user $*" 2>&1 | tr -d '\r'
}
role_of() { as valkey-sentinel sentinel "$1" 6379 ROLE | head -n 1; }
primary() { as valkey-sentinel wallet-service valkey-sentinel 26379 SENTINEL get-master-addr-by-name ows | head -n 1; }

# --- 1. The start, in the order of depends_on --------------------------------------
start valkey
wait_until "start: valkey is healthy" 60 "healthy valkey"
start valkey-replica
wait_until "start: valkey-replica is healthy (in sync)" 60 "healthy valkey-replica"
start valkey-sentinel
wait_until "start: valkey-sentinel is healthy" 60 "healthy valkey-sentinel"
[ "$(role_of valkey)" = master ] && [ "$(role_of valkey-replica)" = slave ] && ok "start: valkey is the primary, valkey-replica its replica" \
  || bad "start: the roles are $(role_of valkey) and $(role_of valkey-replica)"
wait_until "start: the Sentinel gives valkey to the wallet user" 30 '[ "$(primary)" = valkey ]'
docker exec "$prefix-valkey" sh -c 'test "$(stat -c %a /run/valkey/valkey.conf)" = 600 && test "$(stat -c %a /run/valkey/users.acl)" = 600' \
  && ok "start: the files with the passwords have the mode 600" || bad "start: the mode of the files with the passwords"
docker exec "$prefix-valkey-sentinel" sh -c 'grep -q "{password:\|{hash:\|{self}\|{primary}" /run/valkey/sentinel.conf' \
  && bad "start: a field is left" || ok "start: no field is left"

# --- 2. The ACL users and the wallet sections ---------------------------------------
session="$(docker exec "$prefix-valkey-sentinel" sh -c "printf 'SET ows:n:wp:o1:h1 1 NX EX 300\nWAIT 1 1000\n' \
  | REDISCLI_AUTH=\"\$(cat /run/secrets/valkey/wallet-service)\" valkey-cli -h valkey -p 6379 -t 2 --user wallet-service" | tr -d '\r' | tr '\n' ' ')"
[ "$session" = "OK 1 " ] && ok "wallet: SET NX and WAIT 1 (the replica confirms)" || bad "wallet: the session gives $session"
as valkey-sentinel wallet-config valkey 6379 SET other:key 1 | grep -q NOPERM && ok "wallet: no key outside ows:* and ows-wallet" || bad "wallet: a key outside its namespace"
as valkey-sentinel wallet-config valkey 6379 CONFIG GET maxmemory | grep -q NOPERM && ok "wallet: no CONFIG" || bad "wallet: CONFIG"
[ "$(as valkey-sentinel wallet-worker valkey 6379 "EVAL \"return redis.call('EXISTS', KEYS[1])\" 1 ows-wallet")" = 0 ] \
  && ok "wallet: EVAL with the key ows-wallet (KEYS[1] of the broker script)" || bad "wallet: EVAL with the key ows-wallet"
[ "$(as valkey-sentinel gateway valkey 6379 INCR gw:authfail:x)" = 1 ] && ok "gateway: INCR in gw:*" || bad "gateway: INCR"
as valkey-sentinel gateway valkey 6379 SET ows:n:wp:o1:h2 1 | grep -q NOPERM && ok "gateway: no key of the wallet" || bad "gateway: a key of the wallet"
if problems="$(python3 - "$work/project.json" <<'PY' 2>&1
import json, sys, yaml
project = json.load(open(sys.argv[1]))
for role in ("config", "service", "worker", "clock"):
    redis = yaml.safe_load(open(project["configs"][f"wallet-{role}-config"]["file"], encoding="utf-8"))["redis"]
    user = f"wallet-{role}"
    expected = {"queue": {"sentinels": ["valkey-sentinel:26379"], "master_name": "ows", "username": user,
                          "password_file": "/run/secrets/eudi-wallet/redis-password", "sentinel_username": user,
                          "sentinel_password_file": "/run/secrets/eudi-wallet/redis-password", "tls": False}}
    if redis != expected:
        print(f"wallet-{role}: redis {redis!r}")
    mounted = {s["target"]: s["source"] for s in project["services"][f"wallet-{role}"]["secrets"]}
    if mounted.get("/run/secrets/eudi-wallet/redis-password") != f"valkey-{user}-password":
        print(f"wallet-{role} does not mount the password of {user}")
PY
)" && [ -z "$problems" ]; then
  ok "wallet: the redis section and the password of each role (the users of the ACL file)"
else
  bad "wallet: $(printf '%s' "$problems" | tr '\n' ';')"
fi

# --- 3. A failover ---------------------------------------------------------------
docker pause "$prefix-valkey" > /dev/null
wait_until "failover: the Sentinel promotes valkey-replica" 60 '[ "$(primary)" = valkey-replica ]'
[ "$(role_of valkey-replica)" = master ] && ok "failover: valkey-replica is the primary" || bad "failover: valkey-replica is $(role_of valkey-replica)"
docker unpause "$prefix-valkey" > /dev/null
wait_until "failover: valkey comes back as a replica" 60 '[ "$(role_of valkey)" = slave ]'
# A new start of valkey (the service restarts): it asks the Sentinel. The
# user of the service stops its own server (no capability for root).
docker exec "$prefix-valkey" sh -c 'pkill -9 -f "[v]alkey-server" || true; sleep 1; rm -rf /run/valkey/*'
start valkey
# in_sync <service>: the data server is a replica with its primary link up.
in_sync() { as valkey-sentinel probe "$1" 6379 INFO replication | grep -q "^master_link_status:up"; }
wait_until "failover: a new start of valkey is a replica of valkey-replica, in sync" 60 \
  'healthy valkey && in_sync valkey && docker exec '"$prefix-valkey"' grep -q "^replicaof valkey-replica 6379" /run/valkey/valkey.conf'
session="$(docker exec "$prefix-valkey-sentinel" sh -c "printf 'SET ows:n:wp:o1:h3 1 NX EX 300\nWAIT 1 1000\n' \
  | REDISCLI_AUTH=\"\$(cat /run/secrets/valkey/wallet-service)\" valkey-cli -h valkey-replica -p 6379 -t 2 --user wallet-service" | tr -d '\r' | tr '\n' ' ')"
[ "$session" = "OK 1 " ] && ok "failover: the new primary takes a single-use value, valkey confirms" || bad "failover: the session gives $session"

echo "result: ${pass} passed, ${fail} failed"
[ "$fail" -eq 0 ]
