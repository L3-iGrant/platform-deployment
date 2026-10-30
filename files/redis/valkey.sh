#!/bin/sh
# The data container of a Valkey pod. It writes the configuration and the
# ACL file of the server to /run/valkey, then starts the server: the
# primary, or a replica of the primary that the Sentinels give (common.sh,
# find_primary). The Sentinels change the role later (failover).
set -eu
umask 077
. /etc/valkey/common.sh

primary=$(find_primary)
render "$config_dir/valkey.conf" "$run_dir/valkey.conf" "$primary"
render "$config_dir/users.acl" "$run_dir/users.acl" "$primary"
if [ "$primary" = "$self" ]; then
  log "$self starts as the primary"
else
  printf 'replicaof %s 6379\n' "$primary" >> "$run_dir/valkey.conf"
  log "$self starts as a replica of $primary"
fi
exec valkey-server "$run_dir/valkey.conf"
