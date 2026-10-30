#!/bin/sh
# The planned stop of a data server (a rolling update, a node drain). When
# the server is the primary, the Sentinel of another pod moves the primary
# to a replica first (SENTINEL FAILOVER), so that the writes stop only for
# the switch and not for down-after-milliseconds. The Sentinel of this pod
# gets its stop signal at the same time, so the script asks the others.
# The script waits at most 30 seconds for the switch.
set -u
. /etc/valkey/common.sh

role=$(cli 127.0.0.1 6379 sentinel ROLE 2> /dev/null | head -n 1)
if [ "$role" != master ]; then
  exit 0
fi
for host in $(other_hosts); do
  answer=$(cli "$host" 26379 sentinel SENTINEL FAILOVER "$VALKEY_MASTER_NAME" 2> /dev/null)
  if [ "$answer" = OK ]; then
    break
  fi
done
tries=0
while [ "$tries" -lt 30 ]; do
  sleep 1
  role=$(cli 127.0.0.1 6379 sentinel ROLE 2> /dev/null | head -n 1)
  if [ "$role" != master ]; then
    exit 0
  fi
  tries=$((tries + 1))
done
exit 0
