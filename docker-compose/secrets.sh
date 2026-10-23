#!/usr/bin/env bash
# =============================================================================
# make secrets: makes all secrets and keys of the iGrant.io platform in the
# folder secrets/ (git ignores it). It prints only file names and counts,
# never a value. It keeps a file that exists, so it is safe to run again.
#
# What it makes:
# - secrets/database/: the password of the admin user of the database
#   server, of the owner user of each database and of each read-only user;
# - secrets/api/: the API secret key, the token hash secret, the database
#   wrapping key, the token signing key, the service key of the NATS
#   messages, the NATS seeds of the api and of the webhook handler, and the
#   SMTP password (asked when SMTP_USERNAME is set in .env);
# - secrets/gateway/: the key of the internal token of the auth gateway;
# - secrets/consent/, secrets/wallet/: the service keys and the NATS seeds;
# - secrets/openbao/: the seal key of OpenBao and the password of the
#   OpenBao user of the wallet (the openbao-init service writes init.json
#   there at the first start);
# - secrets/public/: the public keys (no secret) that the services use to
#   verify each other, and the public nkeys of the NATS users.
#
# The keys come from the operator commands of the api ("igrant-api keys").
# The script runs them in a container of the api image
# (<IMAGE_REGISTRY>/api:<PLATFORM_TAG>) without network. To use a local
# igrant-api binary instead, set IGRANT_API_BIN=<path>.
# =============================================================================
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"
ROOT="$(pwd -P)"
SECRETS="${ROOT}/secrets"

say() { printf 'secrets: %s\n' "$*"; }
fail() { printf 'secrets: ERROR: %s\n' "$*" >&2; exit 1; }

command -v openssl > /dev/null || fail "openssl is required"
[ -f .env ] || fail ".env does not exist: run make env first"

# The values of .env (KEY=value lines), and a value in the shell has
# priority (as in docker compose).
registry_shell="${IMAGE_REGISTRY-}"
tag_shell="${PLATFORM_TAG-}"
smtp_username_shell="${SMTP_USERNAME-}"
set -a
# shellcheck disable=SC1091
. ./.env
set +a
IMAGE_REGISTRY="${registry_shell:-${IMAGE_REGISTRY:-}}"
PLATFORM_TAG="${tag_shell:-${PLATFORM_TAG:-}}"
API_IMAGE="${IMAGE_REGISTRY}/api:${PLATFORM_TAG}"
if [ -z "${IGRANT_API_BIN:-}" ] && [ "$PLATFORM_TAG" = 2026.10.x ]; then
  fail "PLATFORM_TAG is the placeholder 2026.10.x: set the release tag in .env"
fi
SMTP_USERNAME="${smtp_username_shell:-${SMTP_USERNAME:-}}"

# The folders are private (0700). The files are 0644: the services that run
# as a non-root user in their containers must read the mounted files; on
# this computer only your user can open the folders.
umask 077
mkdir -p "$SECRETS"/{database,api,gateway,consent,wallet,openbao,public/service-jwks}

made=0
kept=0
count() {
  if [ "$1" = made ]; then made=$((made + 1)); else kept=$((kept + 1)); fi
}

# igrant-api with the arguments. Its output has only kids and public nkeys.
igrant_api() {
  if [ -n "${IGRANT_API_BIN:-}" ]; then
    "$IGRANT_API_BIN" "$@"
  else
    [ -n "$IMAGE_REGISTRY" ] && [ -n "$PLATFORM_TAG" ] || fail "IMAGE_REGISTRY and PLATFORM_TAG must be set in .env"
    command -v docker > /dev/null || fail "docker is required (or set IGRANT_API_BIN)"
    docker run --rm --network none --user "$(id -u):$(id -g)" \
      --volume "${SECRETS}:${SECRETS}" --entrypoint /app/bin/igrant-api \
      "$API_IMAGE" "$@"
  fi
}

# igrant-api keys, quiet: the output appears only when the command fails.
keys() {
  local output
  if ! output="$(igrant_api keys "$@" 2>&1)"; then
    printf '%s\n' "$output" >&2
    fail "igrant-api keys $1 failed"
  fi
}

# A random password (hexadecimal, no line break) in the file $1.
password() {
  local file="${SECRETS}/$1"
  if [ -s "$file" ]; then count kept; return; fi
  openssl rand -hex 24 | tr -d '\n' > "$file"
  count made
}

# A private ES256 JWKS with the kid $2 in the file $1, for the purpose $3.
private_jwks() {
  local file="${SECRETS}/$1"
  if [ -s "$file" ]; then count kept; return; fi
  keys generate-token-key "$2" --purpose "$3" --file "$file"
  count made
}

# The public JWKS $2 of the private JWKS $1 (made again when the private
# file is newer).
public_jwks() {
  [ "${SECRETS}/$2" -nt "${SECRETS}/$1" ] && return
  keys export-token-jwks --purpose "$3" --file "${SECRETS}/$1" --out "${SECRETS}/$2"
}

# The nkey seed of a NATS user in the file $1, and its public nkey in $1.pub.
nats_seed() {
  local file="${SECRETS}/$1"
  if [ -s "$file" ]; then
    [ -s "${file}.pub" ] || fail "secrets/$1 exists without secrets/$1.pub: delete secrets/$1 to make a new user"
    count kept
    return
  fi
  rm -f "${file}.pub"
  local output
  if ! output="$(igrant_api keys generate-nats-seed --file "$file" 2>&1)"; then
    printf '%s\n' "$output" >&2
    fail "igrant-api keys generate-nats-seed failed"
  fi
  [[ $output =~ ^U[A-Z2-7]{55}$ ]] || fail "unexpected output of generate-nats-seed for secrets/$1"
  printf '%s\n' "$output" > "${file}.pub"
  count made
}

# 1. Databases: the admin user (postgres or root), the owner user of each
# database and the read-only users (<reader>_<owner>_reader).
for name in admin igrant_api igrant_oidc igrant_consent igrant_wallet \
  wallet_api_reader consent_api_reader api_wallet_reader consent_wallet_reader wallet_consent_reader; do
  password "database/${name}-password"
done

# 2. api: the API secret key, the token hash secret, the database wrapping
# key, the token signing key and the service key of the NATS messages.
password api/api-secret-key
if [ -s "${SECRETS}/api/token-hash-secret.json" ]; then count kept; else
  keys generate-hash-secret compose-1 --file "${SECRETS}/api/token-hash-secret.json"
  count made
fi
if [ -s "${SECRETS}/api/db-wrapping-keys.json" ]; then count kept; else
  keys generate-wrapping-key compose-1 --file "${SECRETS}/api/db-wrapping-keys.json"
  count made
fi
private_jwks api/token-signing-jwks.json igrant-api-token-1 token
private_jwks api/service-envelope-jwks.json igrant-api-1 service

# 3. The auth gateway: the key of the internal token.
private_jwks gateway/internal-token-jwks.json gateway-1 token

# 4. consent and the wallet: the service keys of the NATS messages.
private_jwks consent/service-envelope-jwks.json consent-1 service
private_jwks wallet/service-envelope-jwks.json eudi-wallet-1 service

# 5. The NATS users: one for each process.
nats_seed api/nats-api.nk
nats_seed api/nats-api-webhook.nk
nats_seed consent/nats-consent.nk
nats_seed wallet/nats-wallet-config.nk
nats_seed wallet/nats-wallet-service.nk
nats_seed wallet/nats-wallet-scheduler.nk

# 6. OpenBao: the password of the user of the wallet, and the static seal
# key (32 random bytes) that unseals OpenBao at each start.
password openbao/wallet-password
if [ -s "${SECRETS}/openbao/static-seal.key" ]; then count kept; else
  openssl rand -out "${SECRETS}/openbao/static-seal.key" 32
  count made
fi

# 7. The SMTP password. With SMTP_USERNAME: the password of that login
# (asked one time; it is not shown). Without: an empty file (no SMTP
# authentication).
smtp_file="${SECRETS}/api/smtp-password"
if [ -n "$SMTP_USERNAME" ]; then
  if [ -s "$smtp_file" ]; then count kept; else
    [ -t 0 ] || fail "SMTP_USERNAME is set: write its password to secrets/api/smtp-password (no line break), or run make secrets in a terminal"
    IFS= read -r -s -p "SMTP password of ${SMTP_USERNAME} (the input is hidden): " smtp_password
    printf '\n' >&2
    [ -n "$smtp_password" ] || fail "no SMTP password"
    printf '%s' "$smtp_password" > "$smtp_file"
    unset smtp_password
    count made
  fi
elif [ ! -e "$smtp_file" ]; then
  : > "$smtp_file"
fi

# 8. The public files.
public_jwks api/token-signing-jwks.json public/token-verification-jwks.json token
public_jwks gateway/internal-token-jwks.json public/gateway-jwks.json token
public_jwks api/service-envelope-jwks.json public/service-jwks/igrant-api.json service
public_jwks consent/service-envelope-jwks.json public/service-jwks/igrant-consent-management.json service
public_jwks wallet/service-envelope-jwks.json public/service-jwks/eudi-wallet.json service
{
  printf '# The public nkeys of the NATS users (make secrets writes this file from\n'
  printf '# the seeds in secrets/; config/nats/users.conf uses the names).\n'
  for pair in API:api/nats-api API_WEBHOOK:api/nats-api-webhook CONSENT:consent/nats-consent \
    WALLET_CONFIG:wallet/nats-wallet-config WALLET_SERVICE:wallet/nats-wallet-service \
    WALLET_SCHEDULER:wallet/nats-wallet-scheduler; do
    printf 'NATS_NKEY_%s: "%s"\n' "${pair%%:*}" "$(< "${SECRETS}/${pair#*:}.nk.pub")"
  done
} > "${SECRETS}/public/nats-nkeys.conf"

find "$SECRETS" -type d -exec chmod 700 {} +
find "$SECRETS" -type f ! -name init.json -exec chmod 644 {} +

say "secrets/: ${made} new, ${kept} kept (no value printed)"
say "next: make check"
