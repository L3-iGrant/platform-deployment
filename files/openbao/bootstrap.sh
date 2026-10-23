#!/bin/bash
# Bootstrap of the wallet KMS in the chart OpenBao. The operator runs it
# after "bao operator init":
#
#   kubectl -n <namespace> exec -it <fullname>-openbao-0 -- /openbao/scripts/bootstrap.sh
#
# It asks for a token with the right to configure OpenBao (the root token
# after the init). The input is hidden, and the token is not stored: it is
# only in the environment of this script and of its bao commands.
#
# It makes, in this order, and changes nothing that is already correct (a
# second run changes nothing):
# 1. the Transit engine at OPENBAO_KMS_TRANSIT_MOUNT;
# 2. the userpass auth method at userpass/ (the wallet logs in at
#    auth/userpass/login/<user>);
# 3. the policy OPENBAO_KMS_POLICY with the Transit paths of the wallet
#    (signing keys, and the key wallet-key-store-credentials that encrypts
#    the credentials of the organisation key stores);
# 4. the wallet user (OPENBAO_WALLET_USER) with the password of the Secret of
#    the wallet login (file wallet-password) and only that policy. For a
#    user that exists, one login checks the password (the token of that
#    login is revoked at once); the script sets the password only when the
#    login fails.
set -euo pipefail

: "${OPENBAO_KMS_TRANSIT_MOUNT:=transit}"
: "${OPENBAO_KMS_POLICY:=wallet-kms}"
: "${OPENBAO_BOOTSTRAP_DIR:=/openbao/bootstrap}"
: "${OPENBAO_WALLET_USER:=wallet}"
mount="${OPENBAO_KMS_TRANSIT_MOUNT%/}"
policy_name="$OPENBAO_KMS_POLICY"

say() {
  printf 'bootstrap: %s\n' "$*"
}

fail() {
  printf 'bootstrap: ERROR: %s\n' "$*" >&2
  exit 1
}

# The text of a secret file without its trailing CR and LF characters (the
# rule of the iGrant.io services, so the wallet reads the same value).
read_secret_file() {
  local value
  value="$(< "$1")"
  while [[ $value == *$'\r' || $value == *$'\n' ]]; do
    value="${value%?}"
  done
  printf '%s' "$value"
}

[ -r "${OPENBAO_BOOTSTRAP_DIR}/wallet-password" ] || fail "${OPENBAO_BOOTSTRAP_DIR}/wallet-password is missing (the Secret of the wallet login)"
user="$OPENBAO_WALLET_USER"
[[ $user =~ ^[A-Za-z0-9][A-Za-z0-9._@-]*$ ]] || fail "the wallet user name in OPENBAO_WALLET_USER is not valid (letters, digits, . _ @ -)"
[[ $mount =~ ^[A-Za-z0-9][A-Za-z0-9._/-]*$ ]] || fail "OPENBAO_KMS_TRANSIT_MOUNT is not a valid mount path"

# The token: hidden input, only in the environment.
if [ -t 0 ]; then
  IFS= read -r -s -p "OpenBao token (the input is hidden): " BAO_TOKEN
  printf '\n' >&2
else
  IFS= read -r BAO_TOKEN || true
fi
[ -n "$BAO_TOKEN" ] || fail "no token"
export BAO_TOKEN

state="$(bao status -format=json 2>/dev/null || true)"
[ "$(jq -r '.initialized == true' <<< "$state")" = true ] || fail "OpenBao is not initialised: run \"bao operator init\" first"
[ "$(jq -r '.sealed == false' <<< "$state")" = true ] || fail "OpenBao is sealed: unseal the pod first (bao operator unseal)"
bao token lookup > /dev/null 2>&1 || fail "the token is not valid"

# 1. Transit engine.
mount_type="$(bao secrets list -format=json | jq -r --arg p "${mount}/" '.[$p].type // empty')"
case "$mount_type" in
  "")
    bao secrets enable -path="$mount" -description="Wallet KMS (iGrant.io)" transit > /dev/null
    say "Transit engine at ${mount}/: enabled" ;;
  transit)
    say "Transit engine at ${mount}/: exists (no change)" ;;
  *)
    fail "${mount}/ is a ${mount_type} mount, not Transit" ;;
esac

# 2. userpass auth method.
auth_type="$(bao auth list -format=json | jq -r '."userpass/".type // empty')"
case "$auth_type" in
  "")
    bao auth enable -path=userpass -description="Wallet KMS login (iGrant.io)" userpass > /dev/null
    say "auth method userpass/: enabled" ;;
  userpass)
    say "auth method userpass/: exists (no change)" ;;
  *)
    fail "userpass/ is a ${auth_type} auth method, not userpass" ;;
esac

# 3. Policy: the Transit paths that the wallet KMS uses, and no other path.
policy="path \"${mount}/keys\" {
  capabilities = [\"list\"]
}

path \"${mount}/keys/*\" {
  capabilities = [\"create\", \"read\", \"update\", \"delete\"]
}

path \"${mount}/sign/*\" {
  capabilities = [\"update\"]
}

path \"${mount}/wrapping_key\" {
  capabilities = [\"read\"]
}

path \"${mount}/datakey/plaintext/wallet-key-store-credentials\" {
  capabilities = [\"update\"]
}

path \"${mount}/decrypt/wallet-key-store-credentials\" {
  capabilities = [\"update\"]
}"
current="$(bao policy read "$policy_name" 2> /dev/null || true)"
if [ "$current" = "$policy" ]; then
  say "policy ${policy_name}: exists (no change)"
elif [ -z "$current" ]; then
  printf '%s\n' "$policy" | bao policy write "$policy_name" - > /dev/null
  say "policy ${policy_name}: written"
else
  printf '%s\n' "$policy" | bao policy write "$policy_name" - > /dev/null
  say "policy ${policy_name}: written again (it was different)"
fi

# 4. Wallet user. The password goes to bao on stdin, never as an argument.
password="$(read_secret_file "${OPENBAO_BOOTSTRAP_DIR}/wallet-password")"
[ -n "$password" ] || fail "the wallet password in ${OPENBAO_BOOTSTRAP_DIR}/wallet-password is empty"
if info="$(bao read -format=json "auth/userpass/users/${user}" 2> /dev/null)"; then
  policies="$(jq -c '.data.token_policies // []' <<< "$info")"
  if [ "$policies" = "[\"${policy_name}\"]" ]; then
    say "user ${user}: policy ${policy_name} (no change)"
  else
    bao write "auth/userpass/users/${user}" token_policies="$policy_name" > /dev/null
    say "user ${user}: policies set to ${policy_name} only"
  fi
  login_token=""
  if login="$(printf '%s' "$password" | bao write -format=json "auth/userpass/login/${user}" password=- 2> /dev/null)"; then
    login_token="$(jq -r '.auth.client_token // empty' <<< "$login")"
  fi
  unset login
  if [ -n "$login_token" ]; then
    BAO_TOKEN="$login_token" bao token revoke -self > /dev/null
    say "user ${user}: the password is the one of the wallet login Secret (no change)"
  else
    printf '%s' "$password" | bao write "auth/userpass/users/${user}/password" password=- > /dev/null
    say "user ${user}: password set from the wallet login Secret"
  fi
  unset login_token
else
  printf '%s' "$password" | bao write "auth/userpass/users/${user}" password=- token_policies="$policy_name" > /dev/null
  say "user ${user}: made with the policy ${policy_name} and the password of the wallet login Secret"
fi
unset password

say "done. The wallet logs in as ${user} and uses ${mount}/."
