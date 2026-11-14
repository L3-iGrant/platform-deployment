#!/usr/bin/env bash
# Tests the routes of the bundled NATS (port 6222): only a server with a
# certificate from the chart's CA can open a route. Containers of a local
# NATS image play the 3 NATS pods, with the configuration and TLS Secret of
# a render (nats.replicas 3; the network aliases are the headless Service
# names). Three intruders try to open a route to t-nats-0:
#   - a nats-server with its own CA and certificate (TLS, same cluster
#     name);
#   - a nats-server without the TLS block for its routes (it still has its
#     own CA files for its clients);
#   - a raw TCP client that sends a route CONNECT without TLS.
# The checks: the 3 servers form the cluster (each sees the 2 others in
# /routez); after the intruders, each server still sees only the 2 others,
# all 3 still run, and the t-nats-0 log shows the refusals. The network
# policies (only the NATS pods reach 6222) are checked by
# tests/check_network_matrix.py in tests/render-matrix.sh.
#
# Usage: tests/nats-routes.sh <nats image>
#   The image must be local (the script never pulls), for example the
#   chart's nats.image (nats:2.14.10-alpine). The containers and the network
#   have unique names, and the script removes them at the end.
set -euo pipefail

image="${1:?usage: tests/nats-routes.sh <nats image>}"
here="$(cd "$(dirname "$0")" && pwd)"
chart="$(dirname "$here")"
prefix="nats-routes-test-$(openssl rand -hex 4)"
net="$prefix-net"
work="$(mktemp -d)"
pass=0
fail=0
ok() { pass=$((pass + 1)); echo "ok   $1"; }
bad() { fail=$((fail + 1)); echo "FAIL $1"; }
cleanup() {
  for c in t-nats-0 t-nats-1 t-nats-2 intruder-tls intruder-plain intruder-raw; do
    docker rm -f "$prefix-$c" > /dev/null 2>&1 || true
  done
  docker network rm "$net" > /dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT

if ! docker image inspect "$image" > /dev/null 2>&1; then
  echo "the image $image is not local (the test never pulls)" >&2
  exit 2
fi

# The configuration and TLS files of a render with 3 servers.
helm template t "$chart" --namespace ow -f "$here/values/keys.yaml" -f "$chart/profiles/site.yaml" -f "$here/values/release.yaml" \
  --set nats.replicas=3 > "$work/render.yaml"
python3 "$here/write_nats_conf.py" "$work/render.yaml" "$work/conf" --container
chmod 0644 "$work/conf"/*
docker network create "$net" > /dev/null

server() {
  local name="$1" conf="$2"
  docker run -d --name "$prefix-$name" --network "$net" --network-alias "$name.t-nats-headless" \
    --user 65532:65532 --read-only --cap-drop ALL --security-opt no-new-privileges \
    --tmpfs /data:uid=65532,gid=65532 --tmpfs /var/run/nats:uid=65532,gid=65532 \
    -e SERVER_NAME="$name" -v "$conf:/etc/nats:ro" -v "$conf:/etc/nats-tls:ro" \
    "$image" nats-server -c /etc/nats/nats.conf > /dev/null
}
routes_of() {
  docker exec "$prefix-$1" wget -q -O - http://127.0.0.1:8222/routez 2>/dev/null \
    | python3 -c 'import json, sys; print(" ".join(sorted({r.get("remote_name", "?") for r in json.load(sys.stdin).get("routes") or []})))' 2>/dev/null || echo "no answer"
}

for i in 0 1 2; do server "t-nats-$i" "$work/conf"; done
formed=""
for _ in $(seq 1 30); do
  formed="$(routes_of t-nats-0)|$(routes_of t-nats-1)|$(routes_of t-nats-2)"
  [ "$formed" = "t-nats-1 t-nats-2|t-nats-0 t-nats-2|t-nats-0 t-nats-1" ] && break
  sleep 1
done
if [ "$formed" = "t-nats-1 t-nats-2|t-nats-0 t-nats-2|t-nats-0 t-nats-1" ]; then
  ok "the 3 servers form the cluster with mutual TLS ($formed)"
else
  bad "the cluster does not form: $formed"
  docker logs "$prefix-t-nats-0" 2>&1 | tail -5
fi

# Intruder 1: a server with its own CA (TLS, the same cluster name).
mkdir -p "$work/intruder-tls" "$work/intruder-plain"
(
  cd "$work/intruder-tls"
  openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out ca.key 2> /dev/null
  openssl req -x509 -new -key ca.key -subj "/CN=intruder-ca" -days 1 -out ca.crt 2> /dev/null
  openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out tls.key 2> /dev/null
  openssl req -new -key tls.key -subj "/CN=intruder" -out tls.csr 2> /dev/null
  printf 'subjectAltName = DNS:intruder-tls.t-nats-headless\nextendedKeyUsage = serverAuth, clientAuth\n' > ext
  openssl x509 -req -in tls.csr -CA ca.crt -CAkey ca.key -CAcreateserial -days 1 -extfile ext -out tls.crt 2> /dev/null
)
python3 - "$work/conf/nats.conf" "$work/intruder-tls/nats.conf" "$work/intruder-plain/nats.conf" <<'PY'
import re, sys
source, with_tls, without_tls = sys.argv[1:4]
config = open(source).read()
# The intruders route only to t-nats-0 and have no authorization block
# (they have no users).
config = re.sub(r"routes: \[[^\]]*\]", "routes: [\n        nats://t-nats-0.t-nats-headless:6222\n      ]", config)
config = re.sub(r"\nauthorization \{.*", "\n", config, flags=re.S)
open(with_tls, "w").write(config)
open(without_tls, "w").write(re.sub(r"(cluster \{.*?)\n      tls \{[^}]*\}", r"\1", config, flags=re.S))
PY
# The plain intruder keeps client TLS (port 4222) with its own CA files.
cp "$work/intruder-tls/tls.crt" "$work/intruder-tls/tls.key" "$work/intruder-tls/ca.crt" "$work/intruder-plain/"
chmod 0644 "$work/intruder-tls"/* "$work/intruder-plain"/*
server intruder-tls "$work/intruder-tls"
server intruder-plain "$work/intruder-plain"
# Intruder 3: a route CONNECT on a plain TCP connection.
docker run -d --name "$prefix-intruder-raw" --network "$net" --user 65532:65532 --read-only --cap-drop ALL "$image" \
  sh -c 'for i in 1 2 3 4 5; do printf "CONNECT {\"verbose\":false,\"name\":\"intruder-raw\"}\r\nPING\r\n" | nc -w 2 t-nats-0.t-nats-headless 6222; sleep 1; done' > /dev/null 2>&1 || true
ip_of() { docker inspect -f "{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}" "$prefix-$1" 2>/dev/null; }
ip_tls="$(ip_of intruder-tls)"; ip_plain="$(ip_of intruder-plain)"; ip_raw="$(ip_of intruder-raw)"
sleep 12

after="$(routes_of t-nats-0)|$(routes_of t-nats-1)|$(routes_of t-nats-2)"
if [ "$after" = "t-nats-1 t-nats-2|t-nats-0 t-nats-2|t-nats-0 t-nats-1" ]; then
  ok "after the intruders, each server sees only the 2 others ($after)"
else
  bad "the routes after the intruders: $after"
fi
intruder_routes="$(routes_of intruder-tls)/$(routes_of intruder-plain)"
if [ "$intruder_routes" = "/" ]; then
  ok "no intruder has a route"
else
  bad "intruder routes: $intruder_routes"
fi
running="$(for i in 0 1 2; do docker inspect -f '{{.State.Running}}' "$prefix-t-nats-$i"; done | sort -u | tr '\n' ' ')"
if [ "$running" = "true " ]; then ok "the 3 servers still run"; else bad "a server stopped: $running"; fi
log="$(docker logs "$prefix-t-nats-0" 2>&1)"
# The t-nats-0 log lines about each intruder's connections (found by its address).
refusal() { grep -F "$1:" <<< "$log" | grep -i -E "TLS|handshake|closed" | head -1 || true; }
for intruder in "own CA:$ip_tls" "no TLS block of the routes:$ip_plain" "raw CONNECT without TLS:$ip_raw"; do
  label="${intruder%%:*}"; address="${intruder#*:}"
  line="$(refusal "$address")"
  if [ -n "$address" ] && [ -n "$line" ]; then
    ok "t-nats-0 refused the intruder ($label, $address): $(sed -E 's/^\[[0-9]+\] [0-9/]+ [0-9:.]+ //' <<< "$line" | cut -c1-150)"
  else
    bad "no refusal of the intruder ($label, ${address:-no address}) in the t-nats-0 log"
  fi
done
echo "result: $pass passed, $fail failed"
[ "$fail" = 0 ]
