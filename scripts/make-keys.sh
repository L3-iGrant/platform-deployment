#!/usr/bin/env bash
# Makes the keys of an installation of the chart, with the igrant-api "keys"
# commands of the api image:
# - the key files of the api (token hash secret, token signing JWKS,
#   database wrapping keys), the private JWKS of the gateway and of the
#   signed NATS envelopes of each service, and one nkey seed per NATS user;
# - <out>/secrets.yaml: the Kubernetes Secrets of these files, with the
#   default names of the chart (<release>-...). It holds private keys: apply
#   it, then keep a copy in your password safe and delete the folder;
# - <out>/values-keys.yaml: the values of the keys (key ids, public JWKS,
#   public nkeys, Secret names). It holds no secret. Give it to helm with -f.
#
# Usage: scripts/make-keys.sh [options]
#   -r, --release NAME     the Helm release name (default: ows). With
#                          fullnameOverride, give that value.
#   -n, --namespace NS     the namespace of the release (default: ows)
#   -o, --out DIR          the output folder; it must not exist (default:
#                          ./<release>-keys)
#   -t, --tag TAG          the release tag of the iGrant.io images (the
#                          value global.imageTag of your installation;
#                          required without --api-image or --igrant-api)
#   --api-image IMAGE      the full api image (default: <global.imageRegistry
#                          of the values.yaml of the chart>/api:<tag>); the
#                          commands run in it with docker. With your own
#                          mirror, give this option.
#   --igrant-api PATH      a local igrant-api program in place of docker
#
# The script needs bash, base64, and docker (or --igrant-api). It does not
# call the cluster.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
release="ows"
namespace="ows"
out=""
image=""
local_program=""
tag=""
while [ $# -gt 0 ]; do
  case "$1" in
    -r | --release) release="${2:?$1 needs a value}"; shift 2 ;;
    -n | --namespace) namespace="${2:?$1 needs a value}"; shift 2 ;;
    -o | --out) out="${2:?$1 needs a value}"; shift 2 ;;
    -t | --tag) tag="${2:?$1 needs a value}"; shift 2 ;;
    --api-image) image="${2:?$1 needs a value}"; shift 2 ;;
    --igrant-api) local_program="${2:?$1 needs a value}"; shift 2 ;;
    -h | --help) sed -n '2,27p' "$0"; exit 0 ;;
    *) echo "make-keys: unknown option $1 (see --help)" >&2; exit 2 ;;
  esac
done
[[ $release =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] || { echo "make-keys: the release name \"$release\" is not a DNS label" >&2; exit 2; }
out="${out:-./${release}-keys}"
if [ -e "$out" ]; then
  echo "make-keys: $out exists: give a new folder (the script never replaces keys)" >&2
  exit 1
fi

# The api image: global.imageRegistry of values.yaml, the repository "api"
# and the release tag.
if [ -z "$local_program" ] && [ -z "$image" ]; then
  if [ -z "$tag" ] || [ "$tag" = "2026.10.x" ]; then
    echo "make-keys: give the release tag of your installation (--tag), for example --tag 2026.10.1" >&2
    exit 2
  fi
  registry="$(sed -n 's/^  imageRegistry: *//p' "$here/../values.yaml" | head -n 1)"
  image="${registry}/api:${tag}"
fi

umask 077
mkdir -p "$out/files"
files="$(cd "$out/files" && pwd)"

# igrant-api <arguments>, in the folder of the key files. The api image is
# linux/amd64: on an Arm workstation, Docker runs it with emulation.
igrant_api() {
  if [ -n "$local_program" ]; then
    (cd "$files" && "$local_program" "$@")
  else
    docker run --rm --platform linux/amd64 --user "$(id -u):$(id -g)" -v "$files:/out" -w /out \
      --entrypoint /app/bin/igrant-api "$image" "$@"
  fi
}

stamp="$(date -u +%Y%m%d)"
token_kid="token-${stamp}"
gateway_kid="gateway-${stamp}"

echo "make-keys: the api keys"
igrant_api keys generate-hash-secret "hash-${stamp}" --file token-hash-secret.json > /dev/null
igrant_api keys generate-token-key "$token_kid" --file jwks.json > /dev/null
igrant_api keys generate-wrapping-key "wrap-${stamp}" --file db-wrapping-keys.json > /dev/null
igrant_api keys export-token-jwks --file jwks.json --out token-verification-jwks.json > /dev/null

echo "make-keys: the gateway key"
igrant_api keys generate-token-key "$gateway_kid" --file internal-token-jwks.json > /dev/null
igrant_api keys export-token-jwks --file internal-token-jwks.json --out gateway-jwks.json > /dev/null

echo "make-keys: the keys of the signed NATS envelopes"
for service in api consent wallet; do
  igrant_api keys generate-token-key "${service}-service-${stamp}" --purpose service --file "${service}-service-jwks.json" > /dev/null 2>&1
  igrant_api keys export-token-jwks --purpose service --file "${service}-service-jwks.json" --out "${service}-service-public.json" > /dev/null 2>&1
done

echo "make-keys: the NATS users"
nats_users="api:api apiWebhook:api-webhook consent:consent walletConfig:wallet-config walletService:wallet-service walletScheduler:wallet-scheduler"
for entry in $nats_users; do
  name="${entry#*:}"
  igrant_api keys generate-nats-seed --file "nats-${name}.seed" > "$files/nats-${name}.nkey"
done

# One Secret manifest (type Opaque) with the files. Call with
# <name> <key>=<file> ...
# The labels select the key Secrets of the release (docs/uninstall.md).
secret() {
  local name="$1" pair key file
  shift
  printf -- '---\napiVersion: v1\nkind: Secret\nmetadata:\n  name: %s\n  namespace: %s\n  labels:\n    app.kubernetes.io/instance: %s\n    app.kubernetes.io/component: keys\ntype: Opaque\ndata:\n' "$name" "$namespace" "$release"
  for pair in "$@"; do
    key="${pair%%=*}"
    file="${pair#*=}"
    printf '  %s: %s\n' "$key" "$(base64 < "$files/$file" | tr -d '\n')"
  done
}

{
  echo "# Secrets of the release ${release} (scripts/make-keys.sh, ${stamp}). PRIVATE KEYS."
  secret "${release}-api-token-hash" token-hash-secret.json=token-hash-secret.json
  secret "${release}-api-token-signing" jwks.json=jwks.json
  secret "${release}-api-db-wrapping" db-wrapping-keys.json=db-wrapping-keys.json
  secret "${release}-gateway-internal-token" internal-token-jwks.json=internal-token-jwks.json
  secret "${release}-api-service-key" service-jwks.json=api-service-jwks.json
  secret "${release}-consent-service-key" service-jwks.json=consent-service-jwks.json
  secret "${release}-wallet-service-key" service-jwks.json=wallet-service-jwks.json
  for entry in $nats_users; do
    name="${entry#*:}"
    secret "${release}-nats-${name}" seed="nats-${name}.seed"
  done
} > "$out/secrets.yaml"

# A JSON file as an indented YAML block (the public JWKS).
block() {
  sed "s/^/$1/" "$files/$2"
}

{
  echo "# Values of the keys of the release ${release} (scripts/make-keys.sh, ${stamp})."
  echo "# No secret: key ids, public keys and Secret names. Use it with helm -f."
  echo "api:"
  echo "  keyStorage:"
  echo "    tokenSigning:"
  echo "      activeKid: ${token_kid}"
  echo "  serviceEnvelope:"
  echo "    activeKid: api-service-${stamp}"
  echo "consent:"
  echo "  serviceEnvelope:"
  echo "    activeKid: consent-service-${stamp}"
  echo "organisationWallet:"
  echo "  serviceEnvelope:"
  echo "    activeKid: wallet-service-${stamp}"
  echo "gateway:"
  echo "  internalToken:"
  echo "    activeKid: ${gateway_kid}"
  echo "  publicKeys:"
  echo "    gatewayJwks: |"
  block "      " gateway-jwks.json
  echo "    tokenVerificationJwks: |"
  block "      " token-verification-jwks.json
  echo "serviceKeys:"
  echo "  publicJwks:"
  echo "    igrant-api: |"
  block "      " api-service-public.json
  echo "    igrant-consent-management: |"
  block "      " consent-service-public.json
  echo "    eudi-wallet: |"
  block "      " wallet-service-public.json
  echo "nats:"
  echo "  auth:"
  echo "    users:"
  for entry in $nats_users; do
    key="${entry%%:*}"
    name="${entry#*:}"
    echo "      ${key}: {nkey: $(tr -d '\n' < "$files/nats-${name}.nkey"), seedSecret: ${release}-nats-${name}}"
  done
} > "$out/values-keys.yaml"

echo "make-keys: done"
echo "  $out/secrets.yaml      the Secrets (private keys): kubectl apply -n ${namespace} -f $out/secrets.yaml"
echo "  $out/values-keys.yaml  the values (no secret): helm install ... -f $out/values-keys.yaml"
echo "  $out/files/            the key files: keep a copy in your password safe, then delete the folder"
