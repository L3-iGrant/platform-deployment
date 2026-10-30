#!/bin/sh
# The Sentinel container of a Valkey pod. The Sentinel keeps its state
# (the primary, the replicas, the other Sentinels, the epochs) in its
# configuration file /run/valkey/sentinel.conf and rewrites it. A new pod
# writes the file from the template, with the primary that the group gives
# (common.sh, find_primary); a restart of the container uses the file
# again.
set -eu
umask 077
. /etc/valkey/common.sh

if [ ! -s "$run_dir/sentinel.conf" ]; then
  primary=$(find_primary)
  wait_for_name "$primary"
  render "$config_dir/sentinel.conf" "$run_dir/sentinel.conf" "$primary"
  log "the Sentinel of $self monitors $primary"
fi
exec valkey-server "$run_dir/sentinel.conf" --sentinel
