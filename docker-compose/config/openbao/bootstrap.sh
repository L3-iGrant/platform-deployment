#!/bin/sh
# The openbao-init service: bootstraps the wallet KMS in the OpenBao of the
# Docker Compose platform. Same steps as the Helm chart's bootstrap
# (files/openbao/bootstrap.sh), in POSIX sh because the OpenBao image has no
# bash and no jq. Idempotent: a second run changes nothing that is already
# correct.
#
# 1. First run only: "bao operator init" with one recovery key. The root
#    token and the recovery key go to init.json in OPENBAO_STATE_DIR
#    (secrets/openbao/, mode 0600). The static seal unseals OpenBao.
# 2. The Transit engine at transit/.
# 3. The userpass auth method at userpass/ (the wallet logs in at
#    auth/userpass/login/eudi-wallet).
# 4. The policy wallet-kms: only the wallet's Transit paths (the signing
#    keys, and the key wallet-key-store-credentials that encrypts the
#    credentials of the organisation key stores).
# 5. The user eudi-wallet, with the password from
#    OPENBAO_STATE_DIR/wallet-password (make secrets) and only that policy.
#
# Prints no secret values.
set -eu

: "${OPENBAO_STATE_DIR:=/openbao/state}"
MOUNT=transit
POLICY=wallet-kms
USER_NAME=eudi-wallet
INIT_FILE="${OPENBAO_STATE_DIR}/init.json"

say() { printf 'openbao-init: %s\n' "$*"; }
fail() { printf 'openbao-init: ERROR: %s\n' "$*" >&2; exit 1; }

# The state folder is your secrets/openbao/ folder (mode 0700). This service
# runs as your user without capabilities (make sets HOST_UID and HOST_GID);
# any other user, for example root when HOST_UID is not set, cannot open it.
# Check the owner and list the folder instead of "test -r": the BusyBox test
# returns true for root on every file.
if [ ! -O "$OPENBAO_STATE_DIR" ] || ! ls "$OPENBAO_STATE_DIR" > /dev/null 2>&1; then
  fail "the user $(id -u):$(id -g) cannot open secrets/openbao/: start the platform with make up (it sets HOST_UID and HOST_GID to your user), or set HOST_UID and HOST_GID in your shell"
fi

# Exit code of "bao status": 0 unsealed, 2 sealed (or not initialised),
# 1 no answer.
status_code() {
  rc=0
  bao status > /dev/null 2>&1 || rc=$?
  echo "$rc"
}

i=0
while [ "$(status_code)" = 1 ]; do
  i=$((i + 1))
  [ "$i" -le 60 ] || fail "OpenBao at ${BAO_ADDR} does not answer after 120 seconds (docker compose logs openbao)"
  sleep 2
done

# 1. Initialisation.
rc=0
bao operator init -status > /dev/null 2>&1 || rc=$?
case "$rc" in
  0)
    [ -s "$INIT_FILE" ] || fail "OpenBao is initialised, but secrets/openbao/init.json is missing. Put your copy of the file back."
    say "initialised (no change)" ;;
  2)
    [ ! -e "$INIT_FILE" ] || fail "secrets/openbao/init.json exists, but OpenBao is not initialised (a new volume openbao-data?). Move the old file away first."
    umask 077
    bao operator init -recovery-shares=1 -recovery-threshold=1 -format=json > "${INIT_FILE}.tmp"
    mv "${INIT_FILE}.tmp" "$INIT_FILE"
    say "initialised: the root token and the recovery key are in secrets/openbao/init.json (keep a copy in a safe place)" ;;
  *)
    fail "bao operator init -status failed" ;;
esac

i=0
while [ "$(status_code)" != 0 ]; do
  i=$((i + 1))
  [ "$i" -le 30 ] || fail "OpenBao is still sealed after 60 seconds: check the static seal key (docker compose logs openbao)"
  sleep 2
done

BAO_TOKEN="$(sed -n 's/^[[:space:]]*"root_token":[[:space:]]*"\([^"]*\)".*/\1/p' "$INIT_FILE")"
[ -n "$BAO_TOKEN" ] || fail "no root token in secrets/openbao/init.json"
export BAO_TOKEN

# 2. Transit engine.
if bao secrets list | awk '{print $1}' | grep -qx "${MOUNT}/"; then
  say "Transit engine at ${MOUNT}/: exists (no change)"
else
  bao secrets enable -path="$MOUNT" -description="Wallet KMS (iGrant.io)" transit > /dev/null
  say "Transit engine at ${MOUNT}/: enabled"
fi

# 3. userpass auth method.
if bao auth list | awk '{print $1}' | grep -qx "userpass/"; then
  say "auth method userpass/: exists (no change)"
else
  bao auth enable -path=userpass -description="Wallet KMS login (iGrant.io)" userpass > /dev/null
  say "auth method userpass/: enabled"
fi

# 4. Policy (the same paths as in the Helm chart).
bao policy write "$POLICY" - > /dev/null <<EOF
path "${MOUNT}/keys" {
  capabilities = ["list"]
}

path "${MOUNT}/keys/*" {
  capabilities = ["create", "read", "update", "delete"]
}

path "${MOUNT}/sign/*" {
  capabilities = ["update"]
}

path "${MOUNT}/wrapping_key" {
  capabilities = ["read"]
}

path "${MOUNT}/datakey/plaintext/wallet-key-store-credentials" {
  capabilities = ["update"]
}

path "${MOUNT}/decrypt/wallet-key-store-credentials" {
  capabilities = ["update"]
}
EOF
say "policy ${POLICY}: written"

# 5. The wallet user. The password reaches bao on stdin, never as an
# argument.
[ -s "${OPENBAO_STATE_DIR}/wallet-password" ] || fail "secrets/openbao/wallet-password is missing (run make secrets)"
tr -d '\r\n' < "${OPENBAO_STATE_DIR}/wallet-password" \
  | bao write "auth/userpass/users/${USER_NAME}" password=- token_policies="$POLICY" > /dev/null
say "user ${USER_NAME}: password of secrets/openbao/wallet-password, policy ${POLICY}"
say "done"
