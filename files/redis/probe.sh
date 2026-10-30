#!/bin/sh
# The probes of a Valkey pod, as the ACL user probe (PING and INFO only).
#   probe.sh alive <port>  the server on <port> answers: PONG, or LOADING
#                          while it loads its data (startup and liveness)
#   probe.sh ready         the data server has its data, and it is the
#                          primary or a replica in sync with its primary
#                          (readiness: a rolling update waits for it)
set -eu
. /etc/valkey/common.sh

case "${1:-}" in
  alive)
    answer=$(cli 127.0.0.1 "$2" probe PING 2>&1) || true
    case "$answer" in
      PONG | LOADING*) exit 0 ;;
    esac
    log "no answer on port $2: $answer"
    exit 1
    ;;
  ready)
    info=$(cli 127.0.0.1 6379 probe INFO persistence replication 2>&1) || true
    case "$info" in
      *loading:0*) ;;
      *)
        log "the data server has not loaded its data"
        exit 1
        ;;
    esac
    case "$info" in
      *role:master* | *master_link_status:up*) exit 0 ;;
    esac
    log "the replica is not in sync with its primary"
    exit 1
    ;;
  *)
    log "usage: probe.sh alive <port> | ready"
    exit 2
    ;;
esac
