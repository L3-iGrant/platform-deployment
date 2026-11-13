#!/bin/sh
# The check of the JetStream store of a NATS pod (the init container
# store-check), before nats-server starts. It runs as the user of NATS with
# the groups of the pod, and it reads only the metadata of the store: one
# stat of each file and folder, no file data, no write (the volume is
# mounted read-only in this container).
#
# Why: NATS of a release before the non-root containers ran as root. A file
# that root writes has the mode 0600 (a folder 0700) and the owner root, so
# the user of NATS cannot read it. The kubelet gives the group (fsGroup) and
# the group rights to each file only when the top folder of the volume does
# not have them (fsGroupChangePolicy OnRootMismatch). After a rollback to
# such a release, the top folder keeps them, so the files of the rollback
# stay closed. nats-server then does not load the streams of these files
# (it logs a warning and continues), and the messages that the services
# publish to these streams are lost. This check stops the start instead:
# the files stay as they are, and the message names the repair.
#
# An entry is good when the process can read and write it: the user of the
# process owns it and has u+rw (u+rwx for a folder), or one group of the
# process (id -G: runAsGroup, fsGroup and supplementalGroups) owns it and
# has g+rw (g+rwx for a folder). The walk stops at the first entry that is
# not good.
#
#   store-check.sh <store folder>
#
# Exit 0: the store is good. Exit 1: an entry is not good, or the walk
# failed (the message names the entry or the error).
set -eu

store="${1:?usage: store-check.sh <store folder>}"
uid="$(id -u)"
groups="$(id -G)"

# The find expression: an entry that is good stops the evaluation (true),
# an entry that is not good is printed, and find stops. -a binds before -o.
set -- "$store" "(" -type d "(" -user "$uid" -perm -0700
for gid in $groups; do set -- "$@" -o -group "$gid" -perm -0070; done
set -- "$@" ")" ")" -o "(" ! -type d "(" -user "$uid" -perm -0600
for gid in $groups; do set -- "$@" -o -group "$gid" -perm -0060; done
set -- "$@" ")" ")" -o -print -quit

started="$(date +%s)"
if ! first="$(find "$@")"; then
  echo "store-check: ERROR: the walk of $store failed (see the find message above): nats-server does not start" >&2
  exit 1
fi
seconds=$(($(date +%s) - started))

if [ -n "$first" ]; then
  entry="$(ls -ldn "$first" 2>/dev/null || echo "$first")"
  cat >&2 <<EOF
store-check: ERROR: the user $uid (groups $groups) cannot read and write this entry of the JetStream store:
  $entry
A NATS process as root wrote it: a release before the non-root containers, or a rollback to such a release.
nats-server does not start, so that no stream is skipped. The files stay as they are.
Repair: one rollout of the NATS StatefulSet with fsGroupChangePolicy Always (the kubelet then gives the
group and the group rights to each file of the store). "helm upgrade" with this chart does it by itself when
the NATS StatefulSet in the cluster runs NATS as root; else set
nats.podSecurityContext.fsGroupChangePolicy=Always for one upgrade (docs/upgrade.md, "A rollback to a
release before the non-root containers").
EOF
  exit 1
fi
echo "store-check: the user $uid (groups $groups) can read and write each file and folder of $store (${seconds} s)"
