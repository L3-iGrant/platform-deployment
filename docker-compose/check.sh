#!/usr/bin/env bash
# =============================================================================
# Checks of the Docker Compose platform. No container starts and no image is
# pulled: "docker compose config" needs no Docker daemon.
#
#   ./check.sh  (make check): your installation: the values of .env, the
#               files in secrets/ and docker compose config for DB_ENGINE.
#
# It prints no secret value.
# =============================================================================
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

failures=0
warnings=0
ok() { printf 'ok    %s\n' "$*"; }
bad() { printf 'FAIL  %s\n' "$*" >&2; failures=$((failures + 1)); }
warn() { printf 'WARN  %s\n' "$*" >&2; warnings=$((warnings + 1)); }
finish() {
  if [ "$failures" -gt 0 ]; then
    echo "check: ${failures} check(s) failed" >&2
    exit 1
  fi
  echo "check: $1"
}

# --- The installation (make check) ------------------------------------------

# The effective value of the settings: the value of your shell, else the
# value of .env (the rule of docker compose).
setting() {
  local name="$1" value
  if [ -n "${!name+x}" ]; then
    printf '%s' "${!name}"
    return
  fi
  value="$(sed -n "s/^${name}=//p" .env | tail -n 1)"
  # Remove one pair of quotes around the value.
  value="${value%\"}"
  value="${value#\"}"
  printf '%s' "$value"
}

check_url() {
  local name="$1" value
  value="$(setting "$name")"
  if [[ ! $value =~ ^https?://[A-Za-z0-9.-]+(:[0-9]{1,5})?(/[^[:space:]]*)?$ ]]; then
    bad "$name ($value) is not an http:// or https:// URL"
  elif [[ $value == */ ]]; then
    bad "$name must not end with /"
  elif [[ $value == http://* && ! $value =~ ^http://(localhost|127\.0\.0\.1)(:|/|$) ]]; then
    warn "$name uses http://: mobile wallets and production need https:// (your reverse proxy)"
  else
    ok "$name"
  fi
}

check_port() {
  local name="$1" value
  value="$(setting "$name")"
  if [[ $value =~ ^[0-9]+$ ]] && [ "$value" -ge 1 ] && [ "$value" -le 65535 ]; then
    ok "$name ($value)"
  else
    bad "$name ($value) is not a port (1 to 65535)"
  fi
}

check_installation() {
  [ -f .env ] || { bad ".env does not exist: run make env"; finish ""; }

  local engine profiles
  engine="$(setting DB_ENGINE)"
  case "$engine" in
    postgresql) ok "DB_ENGINE ($engine)" ;;
    *) bad "DB_ENGINE ($engine) must be postgresql" ;;
  esac
  # The derived lines at the end of .env (do not change them).
  local name expected
  for name in COMPOSE_PROFILES; do
    case "$name" in
      COMPOSE_PROFILES) expected='${DB_ENGINE}' ;;
    esac
    if [ -n "${!name+x}" ]; then
      ok "$name (from your shell)"
    elif [ "$(setting "$name")" = "$expected" ]; then
      ok "$name"
    else
      bad "$name must be $expected (the line of .env.example; do not change it)"
    fi
  done

  check_url API_PUBLIC_URL
  check_url WALLET_PUBLIC_URL
  check_url DASHBOARD_PUBLIC_URL

  local address
  address="$(setting PUBLISH_ADDRESS)"
  if [[ $address =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ || $address =~ ^[0-9A-Fa-f:]+$ ]]; then
    ok "PUBLISH_ADDRESS ($address)"
  else
    bad "PUBLISH_ADDRESS ($address) is not an IP address"
  fi
  check_port API_PORT
  check_port WALLET_PORT
  check_port DASHBOARD_PORT
  if [ "$(printf '%s\n' "$(setting API_PORT)" "$(setting WALLET_PORT)" "$(setting DASHBOARD_PORT)" | sort -u | wc -l)" -ne 3 ]; then
    bad "API_PORT, WALLET_PORT and DASHBOARD_PORT must be different"
  fi

  if [[ $(setting CLIENT_ADDRESS_HEADER) =~ ^[A-Za-z0-9-]*$ ]]; then
    ok "CLIENT_ADDRESS_HEADER"
  else
    bad "CLIENT_ADDRESS_HEADER must be a header name (letters, digits, -)"
  fi

  local smtp_host smtp_user
  smtp_host="$(setting SMTP_HOST)"
  smtp_user="$(setting SMTP_USERNAME)"
  if [ -z "$smtp_host" ]; then
    warn "SMTP_HOST is empty: the api sends no e-mail (invitations, password reset)"
  else
    [[ $(setting SMTP_PORT) =~ ^[0-9]+$ ]] || bad "SMTP_PORT is not a port"
    [[ $(setting SMTP_FROM) == *@* ]] || bad "SMTP_FROM must be an e-mail address when SMTP_HOST is set"
    ok "SMTP settings ($smtp_host)"
  fi
  if [ -n "$smtp_user" ] && [ ! -s secrets/api/smtp-password ]; then
    bad "SMTP_USERNAME is set, but secrets/api/smtp-password is empty: run make secrets"
  fi

  local name
  for name in IMAGE_REGISTRY PLATFORM_TAG POSTGRES_IMAGE NATS_IMAGE OPENBAO_IMAGE STORAGE_IMAGE VALKEY_IMAGE; do
    [ -n "$(setting "$name")" ] || bad "$name is not set"
  done
  local tag
  tag="$(setting PLATFORM_TAG)"
  if [ "$tag" = 2026.10.x ]; then
    bad "PLATFORM_TAG is the placeholder 2026.10.x: set the release tag in .env"
  elif [[ ! $tag =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$ ]]; then
    bad "PLATFORM_TAG ($tag) is not an image tag"
  else
    ok "images ($(setting IMAGE_REGISTRY), tag $tag)"
  fi

  # The built-in test CA. Empty: the defaults of compose.platform.yaml.
  local test_ca days
  test_ca="$(setting TEST_CA_ENABLED)"
  days="$(setting TEST_CA_LEAF_VALIDITY_DAYS)"
  case "$test_ca" in
    "" | true | false) ;;
    *) bad "TEST_CA_ENABLED ($test_ca) must be true or false" ;;
  esac
  if [ -n "$days" ] && { [[ ! $days =~ ^[1-9][0-9]{0,3}$ ]] || [ "$days" -gt 3650 ]; }; then
    bad "TEST_CA_LEAF_VALIDITY_DAYS ($days) must be a number of days, 1 to 3650"
  else
    ok "test CA (${test_ca:-true}, ${days:-365} days)"
  fi

  # The retention of the audit log of the wallet. Empty: the default of
  # compose.platform.yaml.
  local years
  years="$(setting AUDIT_RETENTION_YEARS)"
  if [ -n "$years" ] && [[ ! $years =~ ^[1-9][0-9]{0,2}$ ]]; then
    bad "AUDIT_RETENTION_YEARS ($years) must be a number of years, 1 to 999"
  else
    ok "audit log (${years:-7} years; no audit bucket: the anchors stay in the database)"
  fi

  # The password file of each login database role of the wallet (make
  # secrets; wallet-database-roles gives them to database-roles apply).
  local role missing_roles=""
  for role in migrator launcher_app jobs audit_reader issuer_app relying_party_app \
    business_wallet_app individual_wp_app business_wp_app admin_app; do
    [ -s "secrets/database/igrant_wallet_${role}-password" ] || missing_roles+=" igrant_wallet_${role}"
  done
  if [ -z "$missing_roles" ]; then
    ok "database roles of the wallet: a password file for each login database role"
  else
    bad "no password file for the database roles${missing_roles}: run make secrets"
  fi

  # docker compose config for the engine of the installation.
  local json
  if ! json="$(docker compose config --format json 2>&1)"; then
    bad "docker compose config: $json"
    finish ""
  fi
  ok "docker compose config"
  local services
  services="$(docker compose config --services)"
  if grep -qx postgres <<< "$services"; then
    ok "database server: postgres"
  else
    bad "the services must have postgres (COMPOSE_PROFILES)"
  fi
  # The DDL and connection logs of the database server (the command of
  # postgres). A Compose override file can remove them: a warning.
  local setting missing_logs=""
  for setting in log_statement=ddl log_connections=on log_disconnections=on; do
    grep -q -F "\"${setting}\"" <<< "$json" || missing_logs+=" ${setting}"
  done
  if [ -z "$missing_logs" ]; then
    ok "database server logs: DDL statements, connections and disconnections"
  else
    warn "the database server does not log DDL and connections (missing:${missing_logs}); see README.md"
  fi

  # Every file of a secret and of a file configuration exists. Only the
  # SMTP password can be empty (no SMTP authentication).
  local missing=0 file
  while IFS= read -r file; do
    if [ ! -f "$file" ]; then
      bad "missing: ${file#"$PWD"/}"
      missing=1
    elif [ ! -s "$file" ] && [[ $file != */secrets/api/smtp-password ]]; then
      bad "empty: ${file#"$PWD"/}"
      missing=1
    fi
  done < <(grep -oE '"file": *"[^"]+"' <<< "$json" | sed -E 's/"file": *"([^"]+)"/\1/' | sort -u)
  if [ "$missing" -eq 0 ]; then ok "secrets and files"; else bad "run make secrets"; fi

  finish "the configuration is valid (DB_ENGINE=${engine}, ${warnings} warning(s))"
}

case "${1:-}" in
  "") check_installation ;;
  *) echo "usage: $0" >&2; exit 2 ;;
esac
