#!/bin/bash
# Start OpenBao. The chart runs this file from the ConfigMap
# <fullname>-openbao. The seal is the Shamir seal: after each start, an
# operator unseals each pod (bao operator unseal).
set -uo pipefail

: "${BAO_CONFIG_FILE:=/openbao/config/openbao.hcl}"

log() {
  printf 'openbao-entrypoint: %s\n' "$*" >&2
}

if [ ! -r "$BAO_CONFIG_FILE" ]; then
  log "ERROR: the configuration file $BAO_CONFIG_FILE is missing"
  exit 1
fi
exec bao server -config="$BAO_CONFIG_FILE"
