#!/usr/bin/env bash
# Test of the JetStream store of the bundled NATS across an upgrade, a
# rollback and a roll forward, against a real nats-server, without a
# cluster. Containers of a local NATS image play the NATS pod: the earlier
# release (NATS as root, no fsGroup), and the pods of this chart (the
# kubelet change of the volume for fsGroup, the init container store-check
# with files/nats/store-check.sh, then nats-server as the user 65532 with
# the group 65532). A container as root does what the kubelet does for
# fsGroup (pkg/volume/volume_linux.go): with OnRootMismatch nothing when
# the top folder has the group 65532, g+rwx and setgid; else, and always
# with Always, it gives each file the group 65532 and g+rw, each folder
# g+rwxs, and the top folder last.
#
# The steps:
# 1. The earlier release: the streams OLD (100 messages) as root.
# 2. The upgrade (the chart gives Always: the StatefulSet in the cluster
#    runs NATS as root): store-check passes, NATS as 65532 has OLD, takes
#    100 more messages and makes the stream NEW1.
# 3. A rollback to the earlier release: NATS as root makes the stream
#    ROLLBACK (100 messages) and the consumer C1, and adds 50 messages to
#    OLD. The files of root have the mode 0600.
# 4. The roll forward with OnRootMismatch (what the review found): the
#    kubelet changes nothing.
#    a. On a copy of the volume, without store-check (the chart before this
#       fix): nats-server starts without the stream ROLLBACK, and a
#       publish to it fails. This is the failure that the fix prevents.
#    b. With store-check: the pod does not start (exit 1, the message names
#       a file of root and the repair), and no file of the store changes.
# 5. The roll forward with Always (the chart gives it, because the
#    StatefulSet in the cluster runs NATS as root after the rollback):
#    store-check passes, and NATS as 65532 has all streams with all
#    messages (OLD 250, NEW1, ROLLBACK 100 with the consumer C1), and takes
#    new messages.
# 6. The next start with OnRootMismatch (the next upgrade): the kubelet
#    changes nothing, store-check passes, all streams are there.
# 7. The scale of store-check (with --files N, default 200000): a store of
#    N files of root in 100 stream folders; the time of the kubelet change
#    (Always), of a start with OnRootMismatch, and of store-check (it reads
#    only the metadata).
#
# Usage: tests/nats-store.sh <nats image> <nats-box image> [--files N] [--earlier-image <nats image>]
#   --earlier-image: the NATS image of the earlier release (steps 1 and 3,
#   NATS as root), for example nats:2.12.3-alpine; default: <nats image>.
#   The store must stay readable across the change of the version.
#   The images must be local (the script never pulls), for example the
#   image of nats.image (nats:2.14.10-alpine) and natsio/nats-box. The
#   containers, the volumes and the network have unique names, and the
#   script removes them at the end. On a shared Docker host, run it inside
#   your lock of the Docker tests.
set -euo pipefail

usage="usage: tests/nats-store.sh <nats image> <nats-box image> [--files N] [--earlier-image <nats image>]"
nats_image="${1:?$usage}"
box_image="${2:?$usage}"
shift 2
files=200000
earlier_image="$nats_image"
while [ $# -gt 0 ]; do
  case "$1" in
    --files) files="${2:?--files needs a number}"; shift 2 ;;
    --earlier-image) earlier_image="${2:?--earlier-image needs an image}"; shift 2 ;;
    *) echo "$usage" >&2; exit 2 ;;
  esac
done
here="$(cd "$(dirname "$0")" && pwd)"
chart="$(dirname "$here")"
prefix="nats-store-test-$(openssl rand -hex 4)"
net="$prefix-net"
vol="$prefix-store"
copy="$prefix-copy"
scale="$prefix-scale"
uid=65532
pass=0
fail=0
ok() { pass=$((pass + 1)); echo "ok   $1"; }
bad() { fail=$((fail + 1)); echo "FAIL $1"; }

cleanup() {
  docker rm -f "$prefix-nats" > /dev/null 2>&1 || true
  docker volume rm -f "$vol" "$copy" "$scale" "$prefix-script" > /dev/null 2>&1 || true
  docker network rm "$net" > /dev/null 2>&1 || true
}
trap cleanup EXIT
docker network create "$net" > /dev/null
docker volume create "$vol" > /dev/null
# The ConfigMap of the chart: the script of store-check, read-only.
docker volume create "$prefix-script" > /dev/null
docker run --rm --pull never --user 0:0 -v "$prefix-script:/s" -v "$chart/files/nats:/in:ro" --entrypoint sh "$nats_image" \
  -c 'cp /in/store-check.sh /s/store-check.sh && chmod 0444 /s/store-check.sh'

# kubelet <volume> <policy>: the change of the volume for fsGroup 65532.
kubelet() {
  docker run --rm --pull never --user 0:0 --network none -v "$1:/data" --entrypoint sh "$nats_image" -c '
    policy="$1"; gid="$2"
    mode="$(stat -c %a /data)"; group="$(stat -c %g /data)"
    if [ "$policy" = OnRootMismatch ] && [ "$group" = "$gid" ] && [ "$(( 0$mode & 02770 ))" = "$(( 02770 ))" ]; then
      echo skipped; exit 0
    fi
    find /data -mindepth 1 -exec chown -h ":$gid" {} +
    find /data -mindepth 1 -type f -exec chmod g+rw {} +
    find /data -mindepth 1 -type d -exec chmod g+rwxs {} +
    chown ":$gid" /data && chmod g+rwxs /data
    echo changed' sh "$2" "$uid"
}
# store_check <volume> [peak]: the init container store-check of the chart,
# with its memory limit (nats.storeCheck.resources: 64Mi). peak: print the
# peak memory of the container (cgroup v2 memory.peak) after the check.
store_check() {
  local script='/bin/sh /etc/nats-config/store-check.sh /data'
  [ "${2:-}" = peak ] && script="$script > /dev/null && cat /sys/fs/cgroup/memory.peak"
  docker run --rm --pull never --user "$uid:$uid" --group-add "$uid" --read-only --cap-drop ALL \
    --security-opt no-new-privileges:true --network none --memory 64m --memory-swap 64m \
    -v "$1:/data:ro" -v "$prefix-script:/etc/nats-config:ro" --entrypoint /bin/sh "$nats_image" -c "$script"
}
# start <volume> <user>: nats-server with JetStream (store_dir /data). As
# root: the earlier release (its image); else this chart (its image).
start() {
  docker rm -f "$prefix-nats" > /dev/null 2>&1 || true
  local user=(--user 0:0) run_image="$earlier_image"
  [ "$2" = root ] || { user=(--user "$uid:$uid" --group-add "$uid" --read-only --cap-drop ALL --security-opt no-new-privileges:true); run_image="$nats_image"; }
  docker run -d --pull never --name "$prefix-nats" --network "$net" "${user[@]}" -v "$1:/data" "$run_image" -js -sd /data > /dev/null
  for _ in $(seq 1 50); do
    nats_cli account info > /dev/null 2>&1 && return 0
    sleep 0.2
  done
  echo "nats-server did not start"; docker logs "$prefix-nats" 2>&1 | tail -5
}
stop() { docker stop -t 10 "$prefix-nats" > /dev/null; }
nats_cli() { docker run --rm --pull never --network "$net" "$box_image" nats -s "nats://$prefix-nats:4222" "$@"; }
messages() { nats_cli stream info "$1" --json 2>/dev/null | sed -n 's/^ *"messages": \([0-9]*\),*$/\1/p' | head -1; }
publish() { nats_cli pub --jetstream "$1" hello --count "$2" > /dev/null 2>&1; }
listing() { docker run --rm --pull never --user 0:0 --network none -v "$1:/data:ro" --entrypoint sh "$nats_image" -c 'find /data -exec stat -c "%n %u %g %a %s %Y" {} + | sort | md5sum'; }

echo "== the images: earlier release $earlier_image ($(docker run --rm --pull never "$earlier_image" nats-server --version)), this chart $nats_image ($(docker run --rm --pull never "$nats_image" nats-server --version))"
echo "== 1. the earlier release: NATS as root"
start "$vol" root
nats_cli stream add OLD --subjects 'old.>' --storage file --defaults > /dev/null
publish old.a 100
[ "$(messages OLD)" = 100 ] && ok "earlier release: OLD has 100 messages" || bad "earlier release: OLD has $(messages OLD) messages"
stop

echo "== 2. the upgrade: Always (the StatefulSet runs NATS as root), store-check, NATS as $uid"
change="$(kubelet "$vol" Always)"
if check="$(store_check "$vol" 2>&1)"; then ok "upgrade: store-check passes after the kubelet change ($change)"; else bad "upgrade: store-check: $check"; fi
start "$vol" "$uid"
publish old.a 100
nats_cli stream add NEW1 --subjects 'new1.>' --storage file --defaults > /dev/null
publish new1.a 10
[ "$(messages OLD)" = 200 ] && [ "$(messages NEW1)" = 10 ] && ok "upgrade: OLD 200 and NEW1 10 messages as $uid" \
  || bad "upgrade: OLD $(messages OLD), NEW1 $(messages NEW1)"
stop

echo "== 3. a rollback to the earlier release: NATS as root"
start "$vol" root
nats_cli stream add ROLLBACK --subjects 'rb.>' --storage file --defaults > /dev/null
publish rb.a 100
publish old.a 50
nats_cli consumer add ROLLBACK C1 --pull --deliver all --ack explicit --defaults > /dev/null 2>&1
[ "$(messages ROLLBACK)" = 100 ] && [ "$(messages OLD)" = 250 ] && ok "rollback: ROLLBACK 100 and OLD 250 messages as root" \
  || bad "rollback: ROLLBACK $(messages ROLLBACK), OLD $(messages OLD)"
stop
closed="$(docker run --rm --pull never --user 0:0 --network none -v "$vol:/data:ro" --entrypoint sh "$nats_image" -c "find /data ! -user $uid ! -perm -0060 | wc -l")"
echo "   $closed files and folders of root without the group rights"

# The copy of the volume for 4a.
docker volume create "$copy" > /dev/null
docker run --rm --pull never --user 0:0 --network none -v "$vol:/from:ro" -v "$copy:/to" --entrypoint sh "$nats_image" -c 'cp -a /from/. /to/'

echo "== 4a. the roll forward with OnRootMismatch, without store-check (the chart before this fix), on a copy"
change="$(kubelet "$copy" OnRootMismatch)"
start "$copy" "$uid"
if [ -z "$(messages ROLLBACK)" ] && ! publish rb.a 1 && docker logs "$prefix-nats" 2>&1 | grep -q "permission denied"; then
  ok "before the fix: the kubelet $change the files, nats-server starts without the stream ROLLBACK, and a publish to it fails (the finding)"
else
  bad "before the fix: the failure did not happen (ROLLBACK has $(messages ROLLBACK) messages)"
fi
stop

echo "== 4b. the roll forward with OnRootMismatch and store-check"
before="$(listing "$vol")"
change="$(kubelet "$vol" OnRootMismatch)"
if check="$(store_check "$vol" 2>&1)"; then
  bad "roll forward with OnRootMismatch: store-check passed"
elif grep -q -F "cannot read and write this entry" <<< "$check" && grep -q -F "fsGroupChangePolicy Always" <<< "$check"; then
  ok "roll forward with OnRootMismatch: the kubelet $change the files, store-check stops the start and names the repair"
  printf '%s\n' "$check" | sed -n '2p' | sed 's/^/     /'
else
  bad "roll forward with OnRootMismatch: store-check failed without the message: $check"
fi
[ "$(listing "$vol")" = "$before" ] && ok "roll forward with OnRootMismatch: no file of the store changed" || bad "roll forward with OnRootMismatch: the store changed"

echo "== 5. the roll forward with Always (the chart gives it after the rollback)"
change="$(kubelet "$vol" Always)"
if check="$(store_check "$vol" 2>&1)"; then ok "roll forward with Always: store-check passes ($change)"; else bad "roll forward with Always: store-check: $check"; fi
start "$vol" "$uid"
if [ "$(messages OLD)" = 250 ] && [ "$(messages NEW1)" = 10 ] && [ "$(messages ROLLBACK)" = 100 ] \
    && nats_cli consumer next ROLLBACK C1 --count 1 --ack > /dev/null 2>&1 && publish rb.a 10 && [ "$(messages ROLLBACK)" = 110 ]; then
  ok "roll forward with Always: OLD 250, NEW1 10, ROLLBACK 100 with the consumer C1, and new messages: no loss"
else
  bad "roll forward with Always: OLD $(messages OLD), NEW1 $(messages NEW1), ROLLBACK $(messages ROLLBACK)"
fi
stop

echo "== 6. the next start with OnRootMismatch"
change="$(kubelet "$vol" OnRootMismatch)"
if [ "$change" = skipped ] && check="$(store_check "$vol" 2>&1)"; then ok "next start: the kubelet skipped, store-check passes"; else bad "next start: $change $check"; fi
start "$vol" "$uid"
[ "$(messages ROLLBACK)" = 110 ] && [ "$(messages OLD)" = 250 ] && ok "next start: all streams" || bad "next start: ROLLBACK $(messages ROLLBACK), OLD $(messages OLD)"
stop

echo "== 7. the scale of store-check: a store of $files files of root in 100 stream folders"
docker volume create "$scale" > /dev/null
docker run --rm --pull never --user 0:0 --network none -v "$scale:/data" --entrypoint sh "$nats_image" -c '
  per=$(( $1 / 100 ))
  for s in $(seq 1 100); do
    d="/data/jetstream/\$G/streams/S$s/msgs"; mkdir -p "$d"; cd "$d"
    seq 1 "$per" | sed "s/$/.blk/" | xargs touch
  done' sh "$files"
# seconds <command>: run it; print its time in seconds (one decimal); its exit code.
seconds() {
  local start end status=0 ms
  start="$(date +%s%N)"
  "$@" > /dev/null 2>&1 || status=$?
  end="$(date +%s%N)"
  ms=$(( (end - start) / 1000000 ))
  printf '%d.%d' $((ms / 1000)) $(((ms % 1000) / 100))
  return "$status"
}
always="$(seconds kubelet "$scale" Always)"
skip="$(seconds kubelet "$scale" OnRootMismatch)"
check_times=()
for _ in 1 2 3; do
  if t="$(seconds store_check "$scale")"; then check_times+=("$t"); else bad "scale: store-check failed on the changed store"; fi
done
peak="$(store_check "$scale" peak 2>/dev/null || true)"
ok "scale ($files files): the kubelet change with Always ${always} s (a write of each inode), OnRootMismatch ${skip} s, store-check ${check_times[*]} s (one stat of each entry, no write), peak memory of store-check $(( ${peak:-0} / 1024 )) KiB (limit 64Mi)"
docker run --rm --pull never --user 0:0 --network none -v "$scale:/data" --entrypoint sh "$nats_image" -c 'touch /data/jetstream/\$G/streams/S100/msgs/late.blk && chmod 0600 /data/jetstream/\$G/streams/S100/msgs/late.blk'
if t="$(seconds store_check "$scale")"; then bad "scale: store-check passed with a file of root among the good files"; else ok "scale: one file of root among $files good files stops the start (${t} s)"; fi

echo "result: ${pass} passed, ${fail} failed"
[ "$fail" -eq 0 ]
