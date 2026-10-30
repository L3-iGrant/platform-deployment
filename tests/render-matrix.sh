#!/usr/bin/env bash
# Tests of the chart. No cluster and no container: only local commands.
#
# 1. The text of the chart files and of the documentation (README.md,
#    docs/): no em dash or en dash, British English, no
#    name of the earlier key store product (only the wallet config section
#    "vault" of OpenBao, the key store types "vault" (an external OpenBao),
#    "external-vault" and "azure-key-vault", and the product name Azure Key
#    Vault), no database KMS, no backup content, no Keycloak, no Aries or SSI
#    name. The relative links of README.md and docs/ resolve
#    (tests/check_links.py). Each image of values.yaml is in docs/images.md,
#    each image of another project (registry docker.io) is in
#    THIRD-PARTY-NOTICES.md, and the licence text of Valkey is in licenses/.
# 2. The matrix of the examples (examples/): every combination of one file of
#    each group, with examples/site.yaml and tests/values/keys.yaml:
#      database   postgresql-bundled, postgresql-external
#      OpenBao    openbao-shamir, openbao-external
#      exposure   exposure-ingress-nginx, exposure-ingress-nginx-cert-manager,
#                 exposure-envoy-gateway, exposure-kgateway, exposure-none
#      policies   none, networkpolicy
#    For each: helm template, kubeconform -strict (when it is installed; the
#    HTTPRoute schema of the Gateway API from the CRDs catalog) and
#    tests/check_render.py. helm lint runs once per database and OpenBao
#    pair. One more render of the bundled server has the DDL and connection
#    logs off. Each render with network policies:
#    tests/check_network_matrix.py (the policies against
#    policies/network-matrix.yaml). Your own Valkey or Redis (redis-external)
#    with two database files, with and without network policies. The
#    certificate of the bundled Valkey.
# 3. The next steps (NOTES.txt).
# 4. The render guards: wrong values stop the render with a clear message
#    (values.schema.json and the template guards).
# 5. Rendered settings.
# 6. Install and upgrade: tests/check_hook_order.py replays the steps of
#    Helm on the renders (each render of the matrix is an install; installs
#    with consent, the api or the organisation wallet off; an upgrade with
#    the same values, and upgrades that turn the organisation wallet,
#    consent or the api on). The Secrets that are hooks keep the values of
#    the earlier Secrets (a copy of the chart reads them from a file in place
#    of lookup).
#
# Usage: tests/render-matrix.sh [--keep <dir>]
#   --keep <dir>: keep the renders in <dir> (else a temporary folder).
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
chart="$(dirname "$here")"
examples="$chart/examples"
keys="$here/values/keys.yaml"
out=""
if [ "${1:-}" = "--keep" ]; then
  out="${2:?--keep needs a folder}"
  mkdir -p "$out"
else
  out="$(mktemp -d)"
  trap 'rm -rf "$out"' EXIT
fi

pass=0
fail=0
ok() { pass=$((pass + 1)); echo "ok   $1"; }
bad() { fail=$((fail + 1)); echo "FAIL $1"; }

# --- 1. The text of the chart files ------------------------------------------
files=("$chart/README.md" "$chart/values.yaml" "$chart/values.schema.json" "$chart/Chart.yaml"
  "$chart/policies/network-matrix.yaml" "$chart/scripts/make-keys.sh" "$chart/THIRD-PARTY-NOTICES.md")
while IFS= read -r -d '' file; do files+=("$file"); done < <(find "$chart/templates" "$chart/files" "$chart/examples" "$chart/docs" "$here" -type f -print0)
text_check() {
  local what="$1" pattern="$2"; shift 2
  local hits
  # Code literals of other programs are not prose: the "bao status" output
  # (Initialized), the JSON key .initialized of OpenBao, and the key store
  # type "vault" and the provider category "external-vault" of the wallet
  # in their values, enums and the providers example.
  # The module "serialization" of the Python package cryptography is code,
  # not prose. For the vault check, these are not the earlier key store
  # product: the key store type ids `vault`, external-vault and
  # azure-key-vault, a list of the types ([vault, ...]), the product name
  # Azure Key Vault and its host names (<vault>.vault.azure.net).
  hits="$(grep -n -i -E "$pattern" "$@" 2>/dev/null | grep -v -F 'tests/render-matrix.sh:' | grep -v -F 'tests/check_render.py:' \
    | grep -v -F 'tests/compose-files.sh:' \
    | grep -v -E '\.initialized|Initialized +true|"Initialized' \
    | grep -v -E '^[^:]*\.py:[0-9]+:.*(\bserialization\.|import .*\bserialization\b)' \
    | grep -v -E '^[^:]*:[0-9]+: +types: \[vault(, [a-z-]+)*\]$|^[^:]*values\.schema\.json:[0-9]+: +"(external-|azure-key-)?vault",?$' \
    | CHECK_WHAT="$what" perl -ne '($t = $_) =~ s/azure[- ]key[- ]vault|external-vault|`vault`|\[vault,|<vault>\.vault\.azure\.net//gi; print if $ENV{CHECK_WHAT} !~ /^no vault/ || $t =~ /vault/i' || true)"
  if [ -n "$hits" ]; then
    bad "text: $what"
    printf '%s\n' "$hits" | sed "s|$chart/||; s/^/  /" | head -10
  else
    ok "text: $what"
  fi
}
text_check "no em dash or en dash" "$(printf '\342\200\224|\342\200\223')" "${files[@]}"
text_check "British English (-ise, -our, -re)" '\b(initializ(e|ed|es|ing)|organiz(e|ed|ation|ations)|behavior|authoriz(e|ed|es|ing)|color|center|optimiz(e|ed|es|ing)|customiz(e|ed|es|ing)|recogniz(e|ed|es|ing)|analyz(e|ed|es|ing)|serializ(e|ed|ation)|favor|honor|neighbor|labor)\b' "${files[@]}"
text_check "no HashiCorp" 'hashicorp' "${files[@]}"
vault_files=()
for file in "${files[@]}"; do
  case "$file" in */templates/wallet/_config.tpl | */templates/wallet/configmap.yaml) ;; *) vault_files+=("$file") ;; esac
done
text_check "no vault (only the wallet config section kms.vault)" 'vault' "${vault_files[@]}"
text_check "no database KMS" 'kms_key|platform: *"?database|data_key|db-backed|dataKey([^/]|$)' "${files[@]}"
text_check "no backup in templates and values" 'backup' "$chart/values.yaml" "$chart/values.schema.json" $(find "$chart/templates" -type f)
text_check "no Keycloak" 'keycloak' "${files[@]}"
text_check "no Aries or SSI" '\baries\b|aca-py|cloud ?agent|\bssi\b' "${files[@]}"
text_check "no API key rotator" 'apikey-?rotator' "${files[@]}"
# The relative links of the documentation: each target file and each
# heading of an anchor exists.
if links="$(python3 "$here/check_links.py" "$chart/README.md" "$chart"/docs/*.md 2>&1)"; then
  ok "text: relative links of README.md and docs/"
else
  bad "text: relative links of README.md and docs/"
  printf '%s\n' "$links" | sed "s|$chart/||; s/^/  /" | head -10
fi
# The images of values.yaml: each in docs/images.md, each image of another
# project in THIRD-PARTY-NOTICES.md; the licence text of Valkey.
if problems="$(python3 - "$chart" <<'PY' 2>&1
import sys, yaml
chart = sys.argv[1]
images, notices = open(f"{chart}/docs/images.md").read(), open(f"{chart}/THIRD-PARTY-NOTICES.md").read()
def walk(node, path):
    if isinstance(node, dict):
        if node.get("repository") and "tag" in node:
            name = f"{node['registry']}/{node['repository']}" if node.get("registry") else node["repository"]
            if f"`{path}`" not in images or f"`{name}`" not in images and f"`{name}` (" not in images:
                print(f"docs/images.md has not {path} ({name})")
            if node.get("registry") and f"`{name}`" not in notices:
                print(f"THIRD-PARTY-NOTICES.md has not {name}")
        for key, value in node.items():
            walk(value, f"{path}.{key}" if path else key)
walk(yaml.safe_load(open(f"{chart}/values.yaml")), "")
if "Copyright (c) 2024-present, Valkey contributors" not in open(f"{chart}/licenses/valkey/COPYING").read():
    print("licenses/valkey/COPYING is not the licence of Valkey")
PY
)" && [ -z "$problems" ]; then
  ok "text: images in docs/images.md and THIRD-PARTY-NOTICES.md"
else
  bad "text: images in docs/images.md and THIRD-PARTY-NOTICES.md"
  printf '%s\n' "$problems" | sed 's/^/  /' | head -10
fi

# --- 2. The matrix of the examples --------------------------------------------
kubeconform_bin="$(command -v kubeconform || true)"
if [ -z "$kubeconform_bin" ]; then
  echo "kubeconform is not installed: the schema check is skipped"
fi
kubeconform_cache="$out/kubeconform-cache"
mkdir -p "$kubeconform_cache"
# The example files of the database are <engine>-<mode>.yaml.
engine_of() { echo "${1%%-*}"; }
mode_of() { case "$1" in *-external) echo external ;; *) echo bundled ;; esac; }
exposure_of() { case "$1" in exposure-ingress-*) echo ingress ;; exposure-none) echo none ;; *) echo gatewayAPI ;; esac; }
for database in postgresql-bundled postgresql-external; do
  for openbao in openbao-shamir openbao-external; do
    base=(-f "$keys" -f "$examples/site.yaml" -f "$examples/$database.yaml" -f "$examples/$openbao.yaml")
    if helm lint "$chart" --quiet "${base[@]}" > "$out/lint.txt" 2>&1; then
      ok "lint $database $openbao"
    else
      bad "lint $database $openbao"
      sed 's/^/  /' "$out/lint.txt" | head -10
    fi
    for exposure in exposure-ingress-nginx exposure-ingress-nginx-cert-manager exposure-envoy-gateway exposure-kgateway exposure-none; do
      for policies in none networkpolicy; do
        name="$database-$openbao-$exposure-$policies"
        args=("${base[@]}" -f "$examples/$exposure.yaml")
        [ "$policies" = networkpolicy ] && args+=(-f "$examples/networkpolicy.yaml")
        if ! helm template t "$chart" --namespace ow "${args[@]}" > "$out/$name.yaml" 2> "$out/$name.err"; then
          bad "$name: helm template"
          sed 's/^/  /' "$out/$name.err" | head -10
          continue
        fi
        good=1
        if [ -n "$kubeconform_bin" ] && ! "$kubeconform_bin" -strict -summary -kubernetes-version 1.30.0 -cache "$kubeconform_cache" \
            -schema-location default \
            -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json' \
            "$out/$name.yaml" > "$out/$name.kubeconform" 2>&1; then
          echo "  kubeconform:"; grep -v '^Summary' "$out/$name.kubeconform" | sed 's/^/  /' | head -10
          good=0
        fi
        if ! python3 "$here/check_render.py" "$out/$name.yaml" "$(engine_of "$database")" "$(mode_of "$database")" \
            "${openbao#openbao-}" "$(exposure_of "$exposure")" "$([ "$policies" = networkpolicy ] && echo on || echo off)"; then
          good=0
        fi
        if ! python3 "$here/check_hook_order.py" install "$out/$name.yaml"; then
          good=0
        fi
        if [ "$policies" = networkpolicy ] && ! python3 "$here/check_network_matrix.py" "$out/$name.yaml" "$chart/policies/network-matrix.yaml"; then
          good=0
        fi
        if [ "$good" = 1 ]; then ok "$name"; else bad "$name"; fi
      done
    done
  done
done
# The DDL and connection logs of the bundled server off
# (database.postgresql.logDdlAndConnections false): no log parameter.
name="postgresql-bundled-openbao-shamir-exposure-none-none-database-logs-off"
if ! helm template t "$chart" --namespace ow -f "$keys" -f "$examples/site.yaml" -f "$examples/postgresql-bundled.yaml" \
    -f "$examples/openbao-shamir.yaml" -f "$examples/exposure-none.yaml" --set database.postgresql.logDdlAndConnections=false \
    > "$out/$name.yaml" 2> "$out/$name.err"; then
  bad "$name: helm template"
  sed 's/^/  /' "$out/$name.err" | head -10
elif python3 "$here/check_render.py" "$out/$name.yaml" postgresql bundled shamir none off off; then
  ok "$name"
else
  bad "$name"
fi

# Your own Valkey or Redis (redis.mode external, examples/redis-external.yaml):
# no Valkey of the chart, the redis section of the wallet roles, the egress
# to your servers.
if helm lint "$chart" --quiet -f "$keys" -f "$examples/site.yaml" -f "$examples/postgresql-bundled.yaml" \
    -f "$examples/openbao-shamir.yaml" -f "$examples/redis-external.yaml" > "$out/lint.txt" 2>&1; then
  ok "lint redis-external"
else
  bad "lint redis-external"
  sed 's/^/  /' "$out/lint.txt" | head -10
fi
for database in postgresql-bundled postgresql-external; do
  for policies in none networkpolicy; do
    name="redis-external-$database-$policies"
    args=(-f "$keys" -f "$examples/site.yaml" -f "$examples/$database.yaml" -f "$examples/openbao-shamir.yaml"
      -f "$examples/exposure-ingress-nginx.yaml" -f "$examples/redis-external.yaml")
    [ "$policies" = networkpolicy ] && args+=(-f "$examples/networkpolicy.yaml")
    if ! helm template t "$chart" --namespace ow "${args[@]}" > "$out/$name.yaml" 2> "$out/$name.err"; then
      bad "$name: helm template"
      sed 's/^/  /' "$out/$name.err" | head -10
      continue
    fi
    good=1
    if [ -n "$kubeconform_bin" ] && ! "$kubeconform_bin" -strict -summary -kubernetes-version 1.30.0 -cache "$kubeconform_cache" \
        -schema-location default \
        -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json' \
        "$out/$name.yaml" > "$out/$name.kubeconform" 2>&1; then
      echo "  kubeconform:"; grep -v '^Summary' "$out/$name.kubeconform" | sed 's/^/  /' | head -10
      good=0
    fi
    netpol="$([ "$policies" = networkpolicy ] && echo on || echo off)"
    if ! python3 "$here/check_render.py" "$out/$name.yaml" "$(engine_of "$database")" "$(mode_of "$database")" shamir ingress "$netpol" on external; then
      good=0
    fi
    if ! python3 "$here/check_hook_order.py" install "$out/$name.yaml"; then
      good=0
    fi
    if [ "$policies" = networkpolicy ] && ! python3 "$here/check_network_matrix.py" "$out/$name.yaml" "$chart/policies/network-matrix.yaml"; then
      good=0
    fi
    if [ "$good" = 1 ]; then ok "$name"; else bad "$name"; fi
  done
done
# The certificate of the bundled Valkey: the pod names, the Service of the
# Sentinels and 127.0.0.1 (the clients check the host name).
if ! helm template t "$chart" --namespace ow -f "$keys" -f "$examples/site.yaml" -f "$examples/openbao-shamir.yaml" \
    --show-only templates/secrets.yaml > "$out/redis-tls.yaml" 2> "$out/redis-tls.err"; then
  bad "Valkey certificate: $(head -c 200 "$out/redis-tls.err")"
elif names="$(python3 -c '
import base64, sys, yaml
for doc in yaml.safe_load_all(open(sys.argv[1])):
    if doc and doc["metadata"]["name"] == "t-redis-tls":
        sys.stdout.write(base64.b64decode(doc["data"]["tls.crt"]).decode())
' "$out/redis-tls.yaml" | openssl x509 -noout -text 2>&1)" \
    && grep -q -F "DNS:*.t-redis-headless.ow.svc," <<< "$names" && grep -q -F "DNS:t-redis-sentinel.ow.svc," <<< "$names" \
    && grep -q -F "IP Address:127.0.0.1" <<< "$names" && grep -q -F "TLS Web Client Authentication" <<< "$names"; then
  ok "Valkey certificate: the pod names, the Sentinel Service and 127.0.0.1, server and client use"
else
  bad "Valkey certificate: the names of the certificate"
fi

# The bundled NATS: the certificate (the client Service, the pod names of the
# routes, 127.0.0.1; server and client use) and the configuration
# (nats-server -t, when nats-server is on this computer).
if ! helm template t "$chart" --namespace ow -f "$keys" -f "$examples/site.yaml" -f "$examples/openbao-shamir.yaml" \
    > "$out/nats-tls.yaml" 2> "$out/nats-tls.err"; then
  bad "NATS certificate: $(head -c 200 "$out/nats-tls.err")"
else
  if names="$(python3 -c '
import base64, sys, yaml
for doc in yaml.safe_load_all(open(sys.argv[1])):
    if doc and doc["kind"] == "Secret" and doc["metadata"]["name"] == "t-nats-tls":
        sys.stdout.write(base64.b64decode(doc["data"]["tls.crt"]).decode())
' "$out/nats-tls.yaml" | openssl x509 -noout -text 2>&1)" \
      && grep -q -F "DNS:t-nats.ow.svc," <<< "$names" && grep -q -F "DNS:*.t-nats-headless," <<< "$names" \
      && grep -q -F "IP Address:127.0.0.1" <<< "$names" && grep -q -F "TLS Web Client Authentication" <<< "$names"; then
    ok "NATS certificate: the client Service, the pod names of the routes and 127.0.0.1, server and client use"
  else
    bad "NATS certificate: the names of the certificate"
  fi
  if command -v nats-server > /dev/null; then
    rm -rf "$out/nats-conf"
    if python3 "$here/write_nats_conf.py" "$out/nats-tls.yaml" "$out/nats-conf" \
        && conf="$(SERVER_NAME=t-nats-0 nats-server -t -c "$out/nats-conf/nats.conf" 2>&1)"; then
      ok "NATS configuration: nats-server -t (TLS of the clients and of the routes)"
    else
      bad "NATS configuration: nats-server -t: $(printf '%s' "${conf:-}" | head -c 300)"
    fi
    rm -rf "$out/nats-conf"
  else
    echo "nats-server is not installed: the check of the NATS configuration is skipped"
  fi
fi

# --- 3. The next steps (NOTES.txt) --------------------------------------------
# helm template does not render NOTES.txt: a copy of the chart renders it as
# a ConfigMap.
notes_chart="$out/notes-chart"
rm -rf "$notes_chart"
mkdir -p "$notes_chart"
cp -R "$chart/Chart.yaml" "$chart/values.yaml" "$chart/values.schema.json" "$chart/templates" "$chart/files" "$chart/policies" "$notes_chart/"
{ printf '{{- define "test.notes" -}}\n'; cat "$chart/templates/NOTES.txt"; printf '\n{{- end }}\n'; } > "$notes_chart/templates/_test_notes.tpl"
rm "$notes_chart/templates/NOTES.txt"
printf 'apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: notes\ndata:\n  notes: |\n{{ include "test.notes" . | indent 4 }}\n' > "$notes_chart/templates/zz-test-notes.yaml"
notes() {
  local name="$1" expect="$2"; shift 2
  local text
  if ! text="$(helm template ows "$notes_chart" --namespace ows -f "$keys" -f "$examples/site.yaml" "$@" --show-only templates/zz-test-notes.yaml 2>&1)"; then
    bad "notes $name: $(printf '%s' "$text" | head -c 200)"
  elif printf '%s' "$text" | grep -q -F -- "$expect"; then
    ok "notes $name"
  else
    bad "notes $name: no \"$expect\""
  fi
}
notes "shamir" "bao operator unseal" -f "$examples/openbao-shamir.yaml"
notes "external OpenBao" "Make the first admin" -f "$examples/openbao-external.yaml"
notes "URLs" "https://api.example.org" -f "$examples/openbao-shamir.yaml"
notes "placeholder tag warning" "global.imageTag is the placeholder" -f "$examples/openbao-shamir.yaml"

# --- 4. The render guards --------------------------------------------------------
# Each case: the values that must stop the render, and a text of the message.
guard() {
  local name="$1" expect="$2"; shift 2
  local err
  if err="$(helm template t "$chart" --namespace ow -f "$keys" -f "$examples/site.yaml" "$@" 2>&1 >/dev/null)"; then
    bad "guard $name: the render did not stop"
  elif printf '%s' "$err" | grep -q -F -- "$expect"; then
    ok "guard $name"
  else
    bad "guard $name: the message has not \"$expect\""
    printf '%s\n' "$err" | sed 's/^/  /' | head -5
  fi
}
shamir=(-f "$examples/openbao-shamir.yaml")
# PostgreSQL is the only engine: the template guard (ow.db.engine) refuses
# another engine with a message that names the components (the schema has
# no enum for it). mysql stops the render also when only one of the api,
# consent and the organisation wallet is on.
only_postgresql="is not supported: the api, consent and the organisation wallet accept only postgresql"
guard "engine" "database.engine \"oracle\" $only_postgresql" "${shamir[@]}" --set database.engine=oracle
guard "engine mysql" "database.engine \"mysql\" $only_postgresql" "${shamir[@]}" --set database.engine=mysql
mysql_external=("${shamir[@]}" -f "$examples/postgresql-external.yaml" --set database.engine=mysql
  --set api.enabled=false --set consent.enabled=false --set organisationWallet.enabled=false)
guard "engine mysql with the api only" "database.engine \"mysql\" $only_postgresql" "${mysql_external[@]}" --set api.enabled=true \
  --set gateway.upstreams.consent.url=http://consent.example.org --set gateway.upstreams.walletConfig.url=http://wallet.example.org
guard "engine mysql with consent only" "database.engine \"mysql\" $only_postgresql" "${mysql_external[@]}" --set consent.enabled=true
guard "engine mysql with the organisation wallet only" "database.engine \"mysql\" $only_postgresql" "${mysql_external[@]}" --set organisationWallet.enabled=true
guard "mode" "database.mode" "${shamir[@]}" --set database.mode=cluster
guard "external host" "database.external.host" "${shamir[@]}" --set database.mode=external --set database.external.admin.user=root --set database.external.admin.passwordSecret=s --set database.tls.caSecret=c
# The roles hook of the wallet makes its database roles with the
# administrator of the server: an external server needs one with the wallet.
guard "external without admin" "database.external.admin.user is required with database.mode external and the organisation wallet" "${shamir[@]}" --set database.mode=external --set database.external.host=db.example.org --set database.tls.caSecret=c
guard "external without admin and wallet" "database.auth.existingSecret" "${shamir[@]}" --set database.mode=external --set database.external.host=db.example.org --set database.tls.caSecret=c --set organisationWallet.enabled=false --set gateway.upstreams.walletConfig.url=http://wallet.example.org
# The wallet database name is the prefix of the database roles of the
# wallet: <prefix>_business_wallet_app has at most 63 characters.
guard "wallet database name too long for the role prefix" "can have at most 43" "${shamir[@]}" --set database.databases.wallet.name=w2345678901234567890123456789012345678901234
guard "seal" "openbao.seal" --set openbao.seal=transit
guard "external OpenBao without address" "openbao.external.address" --set openbao.mode=external --set openbao.wallet.existingSecret=s
guard "external OpenBao without password" "openbao.wallet.existingSecret" --set openbao.mode=external --set openbao.external.address=https://openbao.example.org:8200
guard "exposure type" "exposure.type" "${shamir[@]}" --set exposure.type=route
guard "gatewayAPI without parentRefs" "parentRefs" "${shamir[@]}" --set exposure.type=gatewayAPI
guard "host" "api.host" "${shamir[@]}" --set api.host=
guard "removed file store value" "Additional property storage" "${shamir[@]}" --set organisationWallet.storage.gcsBucket=files
guard "client address" "clientAddress" "${shamir[@]}" --set 'clientAddress.trustedProxies={192.0.2.0/24}'
guard "unknown value" "Additional property" "${shamir[@]}" --set postgres.enabled=true
guard "privacy dashboard network policy without Kubernetes API address" "networkPolicy.egress.profiles.kubeApi" "${shamir[@]}" --set networkPolicy.enabled=true --set privacyDashboard.enabled=true --set privacyDashboard.namespace=privacy-dashboards
guard "sslMode verify-full without CA" "needs the CA of the server" "${shamir[@]}" -f "$examples/postgresql-external.yaml" --set database.tls.caSecret= --set database.tls.sslMode=verify-full
admin=(--set api.jobs.registerAdmin.enabled=true --set api.jobs.registerAdmin.email=admin@example.org --set api.jobs.registerAdmin.passwordSecret=s)
guard "first admin without name" "api.jobs.registerAdmin.name" "${shamir[@]}" "${admin[@]}" --set-string api.jobs.registerAdmin.phone=+4612345678
guard "first admin without phone" "api.jobs.registerAdmin.phone" "${shamir[@]}" "${admin[@]}" --set api.jobs.registerAdmin.name=Admin
guard "OpenBao update strategy" "openbao.updateStrategy" "${shamir[@]}" --set openbao.updateStrategy=Sometimes
organisation=(--set api.jobs.createOrganisation.enabled=true --set api.jobs.createOrganisation.adminEmail=admin@example.org --set api.jobs.createOrganisation.type=Technology)
guard "first organisation without name" "api.jobs.createOrganisation.name" "${shamir[@]}" "${organisation[@]}" --set api.jobs.createOrganisation.location=Stockholm --set api.jobs.createOrganisation.policyUrl=https://example.org/privacy
guard "first organisation without policy URL" "api.jobs.createOrganisation.policyUrl" "${shamir[@]}" "${organisation[@]}" --set api.jobs.createOrganisation.name=Org --set api.jobs.createOrganisation.location=Stockholm
guard "first organisation without admin" "api.jobs.createOrganisation.adminEmail" "${shamir[@]}" --set api.jobs.createOrganisation.enabled=true --set api.jobs.createOrganisation.name=Org --set api.jobs.createOrganisation.location=Stockholm --set api.jobs.createOrganisation.policyUrl=https://example.org/privacy --set api.jobs.createOrganisation.type=Technology
guard "first organisation policy URL not http" "policyUrl" "${shamir[@]}" "${organisation[@]}" --set api.jobs.createOrganisation.name=Org --set api.jobs.createOrganisation.location=Stockholm --set api.jobs.createOrganisation.policyUrl=ftp://example.org/privacy

# --- 5. Rendered settings ----------------------------------------------------------
# Each case: a text that the render must have.
renders() {
  local name="$1" expect="$2"; shift 2
  local text
  if ! text="$(helm template t "$chart" --namespace ow -f "$keys" -f "$examples/site.yaml" "$@" 2>&1)"; then
    bad "renders $name: $(printf '%s' "$text" | head -c 200)"
  elif grep -q -F -- "$expect" <<< "$text"; then
    # A here-string: with pipefail, "printf | grep -q" of a large render
    # fails when grep stops early (SIGPIPE).
    ok "renders $name"
  else
    bad "renders $name: no \"$expect\""
  fi
}
# Each case: a text that the render must not have.
lacks() {
  local name="$1" unexpected="$2"; shift 2
  local text
  if ! text="$(helm template t "$chart" --namespace ow -f "$keys" -f "$examples/site.yaml" "$@" 2>&1)"; then
    bad "lacks $name: $(printf '%s' "$text" | head -c 200)"
  elif grep -q -F -- "$unexpected" <<< "$text"; then
    bad "lacks $name: has \"$unexpected\""
  else
    ok "lacks $name"
  fi
}
# A restarted pod with the seal shamir waits sealed for an operator: the
# StatefulSet must not roll the pods by itself.
renders "OpenBao OnDelete with shamir" "type: OnDelete" "${shamir[@]}"
renders "OpenBao OnDelete removes rollingUpdate" "rollingUpdate: null" "${shamir[@]}"
renders "OpenBao RollingUpdate when set" "type: RollingUpdate" "${shamir[@]}" --set openbao.updateStrategy=RollingUpdate
# The wallet reads a key just after it makes it: no read on a standby.
renders "OpenBao standbys forward reads" "disable_standby_reads = true" "${shamir[@]}"
# The organisation of the first admin: the e-mail and the type of the other
# two Jobs, and the Job tries again until they exist.
first=(--set api.jobs.registerAdmin.enabled=true --set api.jobs.registerAdmin.email=admin@example.org --set api.jobs.registerAdmin.name=Admin
  --set-string api.jobs.registerAdmin.phone=+4612345678 --set api.jobs.registerAdmin.passwordSecret=s
  --set api.jobs.createOrganisationType.enabled=true --set api.jobs.createOrganisationType.type=Technology
  --set api.jobs.createOrganisation.enabled=true --set api.jobs.createOrganisation.name=Org --set api.jobs.createOrganisation.location=Stockholm
  --set api.jobs.createOrganisation.policyUrl=https://example.org/privacy)
renders "first organisation admin from registerAdmin" "--admin-email=admin@example.org" "${shamir[@]}" "${first[@]}"
renders "first organisation type from createOrganisationType" "--type=Technology" "${shamir[@]}" "${first[@]}"
renders "first organisation Job" "name: t-api-create-organisation-1" "${shamir[@]}" "${first[@]}"
# The key store providers and the EU trusted list check of the wallet.
renders "EU trusted list check on by default" "eu_lotl_url: https://ec.europa.eu/tools/lotl/eu-lotl.xml" "${shamir[@]}"
renders "EU trusted list check off" "eu_lotl_url: null" "${shamir[@]}" --set organisationWallet.trustList.euLotlUrl=
renders "added key store provider" "logo_url: https://example.org/qtsp.png" "${shamir[@]}" --set-json 'organisationWallet.keyStores.providers.add=[{"id":"example-qtsp","category":"qtsp","type":"csc","name":"Example QTSP","protection":"provider","qualified":true,"logoUrl":"https://example.org/qtsp.png","region":"SE","order":30}]'
guard "key store provider category" "category" "${shamir[@]}" --set-json 'organisationWallet.keyStores.providers.add=[{"id":"x","category":"cloud","type":"csc","name":"X","protection":"provider"}]'
guard "key store provider type of the category" "add.0.type" "${shamir[@]}" --set-json 'organisationWallet.keyStores.providers.add=[{"id":"x","category":"qtsp","type":"vault","name":"X","protection":"provider"}]'
guard "unknown key store type" "organisationWallet.keyStores.types" "${shamir[@]}" --set 'organisationWallet.keyStores.types={vault,example}'
renders "cloud KMS types by default" "- azure-key-vault" "${shamir[@]}"
# The built-in test CA: kms.test_ca of every wallet role file (the clock
# file names kms too: the schema of the wallet needs it).
test_ca() {
  local name="$1" expect="$2"; shift 2
  local text problems
  # Only stdout is YAML (helm writes its warnings to stderr).
  if ! text="$(helm template t "$chart" --namespace ow -f "$keys" -f "$examples/site.yaml" "$@" --show-only templates/wallet/configmap.yaml 2> "$out/test-ca.err")"; then
    bad "test CA $name: $(head -c 200 "$out/test-ca.err")"
  elif problems="$(python3 -c '
import json, sys, yaml
data = yaml.safe_load(sys.stdin)["data"]
expected = json.loads(sys.argv[1])
for file in ("service.yaml", "config.yaml", "worker-main.yaml", "worker-maintenance.yaml", "clock.yaml", "scheduler.yaml"):
    test_ca = yaml.safe_load(data[file])["kms"].get("test_ca")
    if test_ca != expected:
        print(f"{file} kms.test_ca is {test_ca!r}")
' "$expect" <<< "$text" 2>&1)" && [ -z "$problems" ]; then
    ok "test CA $name"
  else
    bad "test CA $name: $(printf '%s' "$problems" | tr '\n' ';' | head -c 200)"
  fi
}
test_ca "on by default" '{"enabled": true, "leaf_validity_days": 365}' "${shamir[@]}"
test_ca "off, 90 days" '{"enabled": false, "leaf_validity_days": 90}' "${shamir[@]}" --set organisationWallet.keyStores.testCa.enabled=false --set organisationWallet.keyStores.testCa.leafValidityDays=90
guard "test CA validity" "organisationWallet.keyStores.testCa.leafValidityDays" "${shamir[@]}" --set organisationWallet.keyStores.testCa.leafValidityDays=3651
# The audit log: audit.* of every wallet role file (not of the clock, which
# writes no audit event) and of the migration hook; the bucket only in the
# files of the worker groups, and the Secrets of its credentials (the
# access key and the CA of type s3, the service account of type gcs) only
# in the worker pods (the actors audit.anchor and audit.export).
audit() {
  local name="$1" expect="$2"; shift 2
  local problems
  # Only stdout is YAML (helm writes its warnings to stderr).
  if ! helm template t "$chart" --namespace ow -f "$keys" -f "$examples/site.yaml" "$@" > "$out/audit.yaml" 2> "$out/audit.err"; then
    bad "audit $name: $(head -c 200 "$out/audit.err")"
  elif problems="$(python3 - "$out/audit.yaml" "$expect" <<'PY' 2>&1
import json, sys, yaml
docs = [d for d in yaml.safe_load_all(open(sys.argv[1])) if d]
expected = json.loads(sys.argv[2])
def find(kind, name):
    return next(d for d in docs if d.get("kind") == kind and d["metadata"]["name"] == name)
files = find("ConfigMap", "t-wallet")["data"]
for role in ("service", "config", "worker-main", "worker-maintenance", "clock", "scheduler"):
    worker = role.startswith("worker-")
    audit = yaml.safe_load(files[f"{role}.yaml"]).get("audit")
    want = None if role == "clock" else dict(expected["audit"], **({"bucket": expected["bucket"]} if worker and expected["bucket"] else {}))
    if audit != want:
        print(f"{role}.yaml audit is {audit!r}")
    pod = find("Deployment", f"t-wallet-{role}")["spec"]["template"]["spec"]
    mounted = {item["path"]: [source["secret"]["name"], item["key"]] for volume in pod["volumes"] if volume["name"] == "secrets"
               for source in volume["projected"]["sources"] for item in source["secret"]["items"]}
    secrets = {path: secret for path, secret in mounted.items() if path.startswith("audit-bucket-")}
    if secrets != (expected["secrets"] if worker else {}):
        print(f"the {role} pods mount {secrets!r} as the credentials of the audit bucket")
retention = {key: value for key, value in expected["audit"].items() if key != "anchor_key_store"}
migrate = yaml.safe_load(find("ConfigMap", "t-wallet-migrate")["data"]["config.yaml"]).get("audit")
if migrate != retention:
    print(f"the migration hook audit is {migrate!r}")
PY
)" && [ -z "$problems" ]; then
    ok "audit $name"
  else
    bad "audit $name: $(printf '%s' "$problems" | tr '\n' ';' | head -c 300)"
  fi
}
audit "no bucket by default" '{"audit": {"retention_years": 7}, "bucket": null, "secrets": {}}' "${shamir[@]}"
s3=(--set organisationWallet.audit.bucket.name=example-audit --set organisationWallet.audit.bucket.endpoint=https://s3.example.org
    --set organisationWallet.audit.bucket.region=eu-west-1 --set organisationWallet.audit.bucket.accessKey.existingSecret=audit-bucket)
audit "s3 bucket with its access key" \
  '{"audit": {"retention_years": 7}, "bucket": {"type": "s3", "name": "example-audit", "endpoint": "https://s3.example.org", "region": "eu-west-1", "access_key_id_file": "/run/secrets/eudi-wallet/audit-bucket-access-key-id", "secret_access_key_file": "/run/secrets/eudi-wallet/audit-bucket-secret-access-key"}, "secrets": {"audit-bucket-access-key-id": ["audit-bucket", "access-key-id"], "audit-bucket-secret-access-key": ["audit-bucket", "secret-access-key"]}}' \
  "${shamir[@]}" "${s3[@]}"
audit "s3 bucket with a prefix and the CA of the store" \
  '{"audit": {"retention_years": 10, "scope_retention_years": {"kms": 12}}, "bucket": {"type": "s3", "name": "example-audit", "prefix": "audit/production/", "endpoint": "https://s3.example.org", "region": "eu-west-1", "access_key_id_file": "/run/secrets/eudi-wallet/audit-bucket-access-key-id", "secret_access_key_file": "/run/secrets/eudi-wallet/audit-bucket-secret-access-key", "ca_file": "/run/secrets/eudi-wallet/audit-bucket-ca.crt"}, "secrets": {"audit-bucket-access-key-id": ["audit-bucket", "id"], "audit-bucket-secret-access-key": ["audit-bucket", "secret"], "audit-bucket-ca.crt": ["store-ca", "ca.pem"]}}' \
  "${shamir[@]}" "${s3[@]}" --set organisationWallet.audit.retentionYears=10 --set organisationWallet.audit.scopeRetentionYears.kms=12 \
  --set organisationWallet.audit.bucket.prefix=audit/production/ --set organisationWallet.audit.bucket.accessKey.idKey=id \
  --set organisationWallet.audit.bucket.accessKey.secretKey=secret --set organisationWallet.audit.bucket.ca.existingSecret=store-ca \
  --set organisationWallet.audit.bucket.ca.key=ca.pem
audit "gcs bucket with its service account" \
  '{"audit": {"retention_years": 7}, "bucket": {"type": "gcs", "name": "example_audit", "project": "example-project", "prefix": "audit/production/", "credentials_file": "/run/secrets/eudi-wallet/audit-bucket-service-account.json"}, "secrets": {"audit-bucket-service-account.json": ["audit-bucket", "sa.json"]}}' \
  "${shamir[@]}" --set organisationWallet.audit.bucket.type=gcs \
  --set organisationWallet.audit.bucket.name=example_audit --set organisationWallet.audit.bucket.project=example-project \
  --set organisationWallet.audit.bucket.prefix=audit/production/ --set organisationWallet.audit.bucket.credentials.existingSecret=audit-bucket \
  --set organisationWallet.audit.bucket.credentials.key=sa.json
audit "gcs bucket with the Google default credentials" '{"audit": {"retention_years": 7}, "bucket": {"type": "gcs", "name": "example-audit"}, "secrets": {}}' \
  "${shamir[@]}" --set organisationWallet.audit.bucket.type=gcs --set organisationWallet.audit.bucket.name=example-audit
for value in credentials accessKey ca; do
  guard "audit bucket $value without bucket" "organisationWallet.audit.bucket.$value.existingSecret needs organisationWallet.audit.bucket.name" \
    "${shamir[@]}" --set "organisationWallet.audit.bucket.$value.existingSecret=audit-bucket"
done
guard "audit bucket of type s3 without endpoint" "set organisationWallet.audit.bucket.type: gcs" \
  "${shamir[@]}" --set organisationWallet.audit.bucket.name=example-audit
guard "audit bucket of type s3 without region" "organisationWallet.audit.bucket.region is required" \
  "${shamir[@]}" "${s3[@]}" --set organisationWallet.audit.bucket.region=
guard "audit bucket of type s3 without access key" "organisationWallet.audit.bucket.accessKey.existingSecret is required" \
  "${shamir[@]}" "${s3[@]}" --set organisationWallet.audit.bucket.accessKey.existingSecret=
guard "audit bucket of type s3 with an S3 bucket name" "is not an S3 bucket name" \
  "${shamir[@]}" "${s3[@]}" --set organisationWallet.audit.bucket.name=example_audit
guard "audit bucket of type s3 with gcs values" "are values of type gcs" \
  "${shamir[@]}" "${s3[@]}" --set organisationWallet.audit.bucket.project=example-project
guard "audit bucket of type gcs with s3 values" "are values of type s3" \
  "${shamir[@]}" "${s3[@]}" --set organisationWallet.audit.bucket.type=gcs --set organisationWallet.audit.bucket.accessKey.existingSecret=
guard "audit bucket type" "organisationWallet.audit.bucket.type" "${shamir[@]}" --set organisationWallet.audit.bucket.type=minio
guard "audit bucket endpoint" "organisationWallet.audit.bucket.endpoint" "${shamir[@]}" "${s3[@]}" --set organisationWallet.audit.bucket.endpoint=https://s3.example.org/audit
guard "audit bucket name" "organisationWallet.audit.bucket.name" "${shamir[@]}" --set organisationWallet.audit.bucket.name=Audit_Bucket
guard "audit bucket prefix" "organisationWallet.audit.bucket.prefix" "${shamir[@]}" "${s3[@]}" --set organisationWallet.audit.bucket.prefix=/audit
guard "audit retention of at least one year" "organisationWallet.audit.retentionYears" "${shamir[@]}" --set organisationWallet.audit.retentionYears=0
guard "audit retention of a scope without an audit log" "organisationWallet.audit.scopeRetentionYears" "${shamir[@]}" --set organisationWallet.audit.scopeRetentionYears.events=3
guard "retention purge batch size" "organisationWallet.retention.batchSize" "${shamir[@]}" --set organisationWallet.retention.batchSize=20000
renders "retention purge of a deactivated sandbox" "deactivated_sandbox_days: 14" "${shamir[@]}" --set organisationWallet.retention.deactivatedSandboxDays=14

renders "local backend openbao by default" "local_backend: openbao" "${shamir[@]}"
# The longest wallet database name: 43 characters.
renders "wallet database name of 43 characters" "user: w234567890123456789012345678901234567890123_launcher_app" "${shamir[@]}" --set database.databases.wallet.name=w234567890123456789012345678901234567890123
# The WIA pool refill event (core NATS): the scheduler subscribes to it.
renders "WIA pool refill event of the scheduler" 'subscribe: { allow: ["ows.wia_pool.refill_requested", "_INBOX_wallet.>"] }' "${shamir[@]}"
# A value of database.postgresql.parameters wins over a log parameter of
# database.postgresql.logDdlAndConnections: one -c for each name.
renders "server parameter wins over a database log parameter" '"log_statement=all"' "${shamir[@]}" --set database.postgresql.parameters.log_statement=all
lacks "database log parameter under a server parameter" '"log_statement=ddl"' "${shamir[@]}" --set database.postgresql.parameters.log_statement=all

# The workers and the clock (organisationWallet.workers, .clock,
# .serviceMonitor; docs/workers.md). A case gives the whole list of the
# groups (a list value replaces the default list).
main_group='{"name":"main","queues":["realtime","attestation","status","kms"],"replicas":2,"processes":1,"threads":8,"shutdownTimeoutSeconds":600,"terminationGracePeriodSeconds":630}'
maintenance_group='{"name":"maintenance","queues":["maintenance"],"replicas":1,"processes":1,"threads":2,"shutdownTimeoutSeconds":14400,"terminationGracePeriodSeconds":14430}'
workers() { printf 'organisationWallet.workers.groups=[%s]' "$(IFS=,; printf '%s' "$*")"; }
guard "worker group name" "organisationWallet.workers.groups.0.name" "${shamir[@]}" --set-json "$(workers "${main_group/\"main\"/\"Main\"}" "$maintenance_group")"
guard "worker group name without the schema" 'organisationWallet.workers.groups[0].name "Main" is not a name' "${shamir[@]}" --skip-schema-validation --set-json "$(workers "${main_group/\"main\"/\"Main\"}" "$maintenance_group")"
guard "worker group name two times" 'organisationWallet.workers.groups[1].name "main" is the name of another group' "${shamir[@]}" --set-json "$(workers "$main_group" "${maintenance_group/\"name\":\"maintenance\"/\"name\":\"main\"}")"
guard "worker Deployment name too long" "gives the Deployment name" "${shamir[@]}" --set fullnameOverride=ows-installation-of-the-production-site
guard "worker queue" "organisationWallet.workers.groups.1.queues.0" "${shamir[@]}" --set-json "$(workers "$main_group" "${maintenance_group/\[\"maintenance\"\]/[\"default\"]}")"
guard "worker queue without the schema" '"default" is not a queue of the wallet' "${shamir[@]}" --skip-schema-validation --set-json "$(workers "$main_group" "${maintenance_group/\[\"maintenance\"\]/[\"default\"]}")"
guard "worker queues empty without the schema" "organisationWallet.workers.groups[1].queues is empty" "${shamir[@]}" --skip-schema-validation --set-json "$(workers "$main_group" "${maintenance_group/\[\"maintenance\"\]/[]}")"
guard "worker queue two times without the schema" "organisationWallet.workers.groups[1].queues names a queue two times" "${shamir[@]}" --skip-schema-validation --set-json "$(workers "$main_group" "${maintenance_group/\[\"maintenance\"\]/[\"maintenance\",\"maintenance\"]}")"
guard "worker queue that no group runs" "no group runs the queue maintenance" "${shamir[@]}" --set-json "$(workers "$main_group")"
guard "worker grace period below the shutdown timeout" "terminationGracePeriodSeconds (14400) must be at least shutdownTimeoutSeconds (14400) + 30" "${shamir[@]}" --set-json "$(workers "$main_group" "${maintenance_group/14430/14400}")"
guard "worker replicas" "organisationWallet.workers.groups.0.replicas" "${shamir[@]}" --set-json "$(workers "${main_group/\"replicas\":2/\"replicas\":0}" "$maintenance_group")"
guard "worker replicas without the schema" "organisationWallet.workers.groups[0].replicas (0) must be 1 or more" "${shamir[@]}" --skip-schema-validation --set-json "$(workers "${main_group/\"replicas\":2/\"replicas\":0}" "$maintenance_group")"
guard "worker group without threads" "threads" "${shamir[@]}" --set-json "$(workers "${main_group/\"threads\":8,/}" "$maintenance_group")"
guard "clock replicas" "organisationWallet.clock.replicas" "${shamir[@]}" --set organisationWallet.clock.replicas=0
one_group='organisationWallet.workers.groups=[{"name":"all","queues":["realtime","attestation","status","kms","maintenance"],"replicas":1,"processes":2,"threads":4,"shutdownTimeoutSeconds":14400,"terminationGracePeriodSeconds":14430}]'
renders "one worker group for every queue" "name: t-wallet-worker-all" "${shamir[@]}" --set-json "$one_group"
renders "one worker group: its configuration key" "worker-all.yaml: |" "${shamir[@]}" --set-json "$one_group"
lacks "one worker group: no Deployment of the default groups" "name: t-wallet-worker-main" "${shamir[@]}" --set-json "$one_group"
renders "clock replicas" "replicas: 3" "${shamir[@]}" --set organisationWallet.clock.replicas=3 --show-only templates/wallet/clock.yaml
renders "ServiceMonitor of the workers and the clock" "name: t-wallet-metrics" "${shamir[@]}" --set organisationWallet.serviceMonitor.enabled=true
renders "metrics Service of a worker group (also the pods that are not ready)" "publishNotReadyAddresses: true" "${shamir[@]}" --set organisationWallet.serviceMonitor.enabled=true --show-only templates/wallet/servicemonitor.yaml
# The health port of the workers and of the clock (the scrape of
# /metrics): open only to the monitoring namespace (networkPolicy.monitoring).
renders "scrape of the workers and the clock with network policies" "port: health" "${shamir[@]}" -f "$examples/networkpolicy.yaml" \
  --set networkPolicy.monitoring.enabled=true --set-json 'networkPolicy.monitoring.namespaceSelector={"matchLabels":{"kubernetes.io/metadata.name":"monitoring"}}' \
  --show-only templates/networkpolicy/policies.yaml
lacks "no scrape of the workers and the clock without the monitoring namespace" "port: health" "${shamir[@]}" -f "$examples/networkpolicy.yaml" \
  --show-only templates/networkpolicy/policies.yaml

# The bundled NATS (nats.tls, nats.tlsCa).
guard "NATS CA of an external NATS with the bundled NATS" "nats.tlsCa is the CA of an external NATS" "${shamir[@]}" --set nats.tlsCa.existingSecret=my-nats-ca
renders "NATS with own certificate" "secretName: my-nats-tls" "${shamir[@]}" --set nats.tls.existingSecret=my-nats-tls --show-only templates/nats/statefulset.yaml
lacks "the NATS TLS Secret of the chart with own certificate" "name: t-nats-tls" "${shamir[@]}" --set nats.tls.existingSecret=my-nats-tls
external_nats=("${shamir[@]}" --set nats.enabled=false --set nats.external.url=tls://nats.example.org:4222)
renders "external NATS with its CA" "name: my-nats-ca" "${external_nats[@]}" --set nats.tlsCa.existingSecret=my-nats-ca
lacks "external NATS: no TLS Secret of the chart" "t-nats-tls" "${external_nats[@]}" --set nats.tlsCa.existingSecret=my-nats-ca
lacks "external NATS without a CA: no CA file" "nats-ca.crt" "${external_nats[@]}"

# The life of a stored command reply (organisationWallet.nats.commandReplySeconds):
# only in the file of the config role.
renders "command reply life of the config role" "command_reply_seconds: 900" "${shamir[@]}" --set organisationWallet.nats.commandReplySeconds=900
guard "command reply life" "organisationWallet.nats.commandReplySeconds" "${shamir[@]}" --set organisationWallet.nats.commandReplySeconds=119

# The pools of the wallet and of the readers of the api (database.pools).
guard "wallet pool size" "database.pools.walletService.poolSize" "${shamir[@]}" --set database.pools.walletService.poolSize=0
guard "worker pool overflow" "database.pools.walletWorker.maxOverflow" "${shamir[@]}" --set database.pools.walletWorker.maxOverflow=-1
guard "worker threads above the largest pool of the wallet" "organisationWallet.workers.groups.0.threads" "${shamir[@]}" --set-json "$(workers "${main_group/\"threads\":8/\"threads\":101}" "$maintenance_group")"
renders "the session pool of a worker process follows its threads" "pool_size: 16" "${shamir[@]}" --set-json "$(workers "${main_group/\"threads\":8/\"threads\":16}" "$maintenance_group")" \
  --show-only templates/wallet/configmap.yaml
renders "the reader pool of the api" "maxConns: 9" "${shamir[@]}" --set database.pools.apiReadAccess.maxConns=9 --show-only templates/api/configmap.yaml

# Valkey (redis.*): the schema and the template guards.
redis_sts() {
  local name="$1" expect="$2"; shift 2
  local text
  if ! text="$(helm template t "$chart" --namespace ow -f "$keys" -f "$examples/site.yaml" "${shamir[@]}" "$@" --show-only templates/redis/statefulset.yaml 2>&1)"; then
    bad "Valkey pods $name: $(printf '%s' "$text" | head -c 200)"
  elif grep -q -F -- "$expect" <<< "$text"; then
    ok "Valkey pods $name"
  else
    bad "Valkey pods $name: no \"$expect\""
  fi
}
guard "redis mode" "redis.mode" "${shamir[@]}" --set redis.mode=cluster
guard "redis mode without the schema" 'redis.mode "cluster" is not supported' "${shamir[@]}" --skip-schema-validation --set redis.mode=cluster
guard "redis even replicas" "redis.replicas" "${shamir[@]}" --set redis.replicas=4
guard "redis even replicas without the schema" "redis.replicas (4) must be an odd number of 3 or more" "${shamir[@]}" --skip-schema-validation --set redis.replicas=4
guard "redis one replica" "redis.replicas" "${shamir[@]}" --set redis.replicas=1
guard "redis quorum above the replicas" "redis.sentinel.quorum (4) must be 1 to redis.replicas (3)" "${shamir[@]}" --set redis.sentinel.quorum=4
guard "redis maxmemory" "redis.maxmemory" "${shamir[@]}" --set redis.maxmemory=lots
guard "redis maxmemory without the schema" 'redis.maxmemory "lots" is not a size' "${shamir[@]}" --skip-schema-validation --set redis.maxmemory=lots
guard "redis master name" "redis.masterName" "${shamir[@]}" --set 'redis.masterName=my primary'
guard "redis user name" "redis.users.gateway.username" "${shamir[@]}" --set redis.users.gateway.username=-gw
guard "redis user of two processes" 'redis.users.walletConfig.username "wallet-service" is the user of another process' "${shamir[@]}" --set redis.users.walletConfig.username=wallet-service
guard "redis user name of the bundled Valkey" 'redis.users.gateway.username "sentinel" is a user of the bundled Valkey' "${shamir[@]}" --set redis.users.gateway.username=sentinel
guard "redis unknown value" "Additional property" "${shamir[@]}" --set redis.cluster=true
guard "redis client timeout" "redis.client.timeoutSeconds" "${shamir[@]}" --set redis.client.timeoutSeconds=0
guard "redis replica wait" "redis.client.replicaWaitMilliseconds" "${shamir[@]}" --set redis.client.replicaWaitMilliseconds=20000
external_redis=("${shamir[@]}" -f "$examples/redis-external.yaml")
guard "external redis without sentinels or address" "redis.external" "${external_redis[@]}" --set-json 'redis.external.sentinels=[]'
guard "external redis without sentinels or address without the schema" "redis.external.sentinels or redis.external.address is required" "${external_redis[@]}" --skip-schema-validation --set-json 'redis.external.sentinels=[]'
guard "external redis with sentinels and address" "redis.external" "${external_redis[@]}" --set redis.external.address=redis.example.org:6379
guard "external redis with sentinels and address without the schema" "set redis.external.sentinels or redis.external.address, not both" "${external_redis[@]}" --skip-schema-validation --set redis.external.address=redis.example.org:6379
guard "external redis user without password Secret" "redis.users.gateway" "${external_redis[@]}" --set redis.users.gateway.passwordSecret=
guard "external redis user without password Secret without the schema" "redis.users.gateway.passwordSecret is required with redis.mode external" "${external_redis[@]}" --skip-schema-validation --set redis.users.gateway.passwordSecret=
guard "external redis Sentinel without port" "redis.external.sentinels" "${external_redis[@]}" --set-json 'redis.external.sentinels=["redis-1.example.org"]'
guard "external redis Sentinel without port without the schema" '"redis-1.example.org" is not host:port' "${external_redis[@]}" --skip-schema-validation --set-json 'redis.external.sentinels=["redis-1.example.org"]'
guard "external redis with network policies without addresses" "networkPolicy.externalRedis needs the addresses" "${external_redis[@]}" -f "$examples/networkpolicy.yaml" --set-json 'networkPolicy.externalRedis=[]'
redis_sts "with redis.affinity" "requiredDuringSchedulingIgnoredDuringExecution" \
  --set-json 'redis.affinity={"podAntiAffinity":{"requiredDuringSchedulingIgnoredDuringExecution":[{"topologyKey":"kubernetes.io/hostname","labelSelector":{"matchLabels":{"app.kubernetes.io/component":"redis"}}}]}}'
redis_sts "with the password Secret of a user" "name: my-redis-wallet-service" --set redis.users.walletService.passwordSecret=my-redis-wallet-service
redis_sts "with own certificate" "secretName: my-redis-tls" --set redis.tls.existingSecret=my-redis-tls
redis_sts "with 5 pods" "t-redis-4.t-redis-headless.ow.svc" --set redis.replicas=5 --set redis.sentinel.quorum=3
lacks "the TLS Secret of the chart with own certificate" "name: t-redis-tls" "${shamir[@]}" --set redis.tls.existingSecret=my-redis-tls
renders "redis maxmemory" "maxmemory 1gb" "${shamir[@]}" --set redis.maxmemory=1gb
renders "redis 5 Sentinels in the wallet file" "- t-redis-4.t-redis-headless.ow.svc:26379" "${shamir[@]}" --set redis.replicas=5 --set redis.sentinel.quorum=3
renders "external redis address" "address: redis.example.org:6379" "${external_redis[@]}" --set-json 'redis.external.sentinels=[]' --set redis.external.address=redis.example.org:6379
lacks "external redis address without the Sentinel login" "sentinel_username" "${external_redis[@]}" --set-json 'redis.external.sentinels=[]' --set redis.external.address=redis.example.org:6379
lacks "external redis Sentinels without a login" "sentinel_username" "${external_redis[@]}" --set redis.external.sentinelAuth=false
lacks "external redis without CA (the system CAs)" "redis-ca.crt" "${external_redis[@]}" --set redis.external.caSecret=
lacks "no Valkey without the wallet and the api" "t-redis" "${shamir[@]}" --set organisationWallet.enabled=false --set api.enabled=false

# --- 6. Install and upgrade --------------------------------------------------------
# The order of the hooks (tests/check_hook_order.py, no cluster): the Jobs
# of the hooks find their Secrets, ConfigMaps, databases and users when they
# start, and each Job and pod finds its Secrets at the end.
# An install with one component off: no read access Job of a reader that is
# off (the read access Secret has no password for it).
install_order() {
  local name="$1" database="$2"; shift 2
  local case="$out/install-$database-${name// /-}"
  if ! helm template t "$chart" --namespace ow -f "$keys" -f "$examples/site.yaml" -f "$examples/$database.yaml" \
      -f "$examples/openbao-shamir.yaml" -f "$examples/exposure-ingress-nginx.yaml" "$@" > "$case.yaml" 2> "$case.err"; then
    bad "install $name ($database): helm template"
    sed 's/^/  /' "$case.err" | head -5
  elif python3 "$here/check_hook_order.py" install "$case.yaml"; then
    ok "install $name ($database)"
  else
    bad "install $name ($database)"
  fi
}
# An upgrade: the new release has all components on; the earlier release
# has the values of each case.
upgrade_order() {
  local name="$1" database="$2"; shift 2
  local args=(-f "$keys" -f "$examples/site.yaml" -f "$examples/$database.yaml" -f "$examples/openbao-shamir.yaml"
    -f "$examples/exposure-ingress-nginx.yaml")
  local case="$out/upgrade-$database-${name// /-}"
  if ! helm template t "$chart" --namespace ow "${args[@]}" > "$case-after.yaml" 2> "$case.err" \
      || ! helm template t "$chart" --namespace ow "${args[@]}" "$@" > "$case-before.yaml" 2> "$case.err"; then
    bad "upgrade $name ($database): helm template"
    sed 's/^/  /' "$case.err" | head -5
  elif python3 "$here/check_hook_order.py" upgrade "$case-before.yaml" "$case-after.yaml"; then
    ok "upgrade $name ($database)"
  else
    bad "upgrade $name ($database)"
  fi
}
for database in postgresql-bundled postgresql-external; do
  install_order "with consent off" "$database" --set consent.enabled=false --set gateway.upstreams.consent.url=http://consent.example.org
  install_order "with the api off" "$database" --set api.enabled=false
  install_order "with the organisation wallet off" "$database" --set organisationWallet.enabled=false \
    --set gateway.upstreams.walletConfig.url=http://wallet.example.org
  upgrade_order "with the same values" "$database"
  upgrade_order "that turns the organisation wallet on" "$database" --set organisationWallet.enabled=false \
    --set gateway.upstreams.walletConfig.url=http://wallet.example.org
  upgrade_order "that turns consent on" "$database" --set consent.enabled=false --set gateway.upstreams.consent.url=http://consent.example.org
  upgrade_order "that turns the api on" "$database" --set api.enabled=false
  upgrade_order "that turns the database TLS on" "$database" --set database.tls.enabled=false
  # The first upgrade from a release in which the database Secret, the read
  # access Secret and the init Job were resources, not hooks: the earlier
  # release is the render of the new release without their hook annotations
  # (the init Job with the release revision in its name). Helm must not
  # delete the Secrets at the end of the upgrade (keep on the live Secret).
  case="$out/upgrade-$database-with-the-same-values"
  if python3 -c '
import sys, yaml
docs = [doc for doc in yaml.safe_load_all(open(sys.argv[1])) if doc]
for doc in docs:
    if (doc["kind"], doc["metadata"]["name"]) in (("Secret", "t-postgres"), ("Secret", "t-postgres-tls"), ("Secret", "t-read-access"), ("ConfigMap", "t-db-init"), ("Job", "t-db-init")):
        for name in ("helm.sh/hook", "helm.sh/hook-weight", "helm.sh/hook-delete-policy"):
            doc["metadata"]["annotations"].pop(name)
        if doc["kind"] == "Job":
            doc["metadata"]["name"] = "t-db-init-1"
yaml.safe_dump_all(docs, open(sys.argv[2], "w"))
' "$case-after.yaml" "$case-resources-before.yaml" \
      && python3 "$here/check_hook_order.py" upgrade "$case-resources-before.yaml" "$case-after.yaml"; then
    ok "upgrade from Secrets and an init Job that were resources ($database)"
  else
    bad "upgrade from Secrets and an init Job that were resources ($database)"
  fi
done

# The Secrets that are hooks (the database Secret, the read access Secret
# and the role Secret of the wallet) keep the values of the Secrets of the
# earlier release. "helm template" has no cluster, so a copy of the chart
# reads the earlier Secrets from the file earlier-secrets.json in place of
# lookup (ow.lookupSecretKey). The earlier database Secret has no password
# of consent (an upgrade that turns consent on): the render gives a new one.
lookup_chart="$out/lookup-chart"
rm -rf "$lookup_chart"
mkdir -p "$lookup_chart"
cp -R "$chart/Chart.yaml" "$chart/values.yaml" "$chart/values.schema.json" "$chart/templates" "$chart/files" "$chart/policies" "$lookup_chart/"
lookup_line='{{- $secret := lookup "v1" "Secret" $root.Release.Namespace (index . 1) -}}'
stub_line='{{- $secret := index ($root.Files.Get "earlier-secrets.json" | fromJson) (index . 1) -}}'
lookup_args=(-f "$keys" -f "$examples/site.yaml" -f "$examples/postgresql-bundled.yaml" -f "$examples/openbao-shamir.yaml")
if [ "$(grep -c -F -- "$lookup_line" "$lookup_chart/templates/_helpers.tpl")" != 1 ]; then
  bad "upgrade keeps the values of the Secrets: ow.lookupSecretKey has not the lookup line of the test"
elif ! helm template t "$chart" --namespace ow "${lookup_args[@]}" --show-only templates/secrets.yaml > "$out/secrets-new.yaml" 2> "$out/secrets.err"; then
  bad "upgrade keeps the values of the Secrets: $(head -c 200 "$out/secrets.err")"
else
  LOOKUP_LINE="$lookup_line" STUB_LINE="$stub_line" perl -pi -e 's/\Q$ENV{LOOKUP_LINE}\E/$ENV{STUB_LINE}/' "$lookup_chart/templates/_helpers.tpl"
  # The earlier Secrets: the keys of a new render, with known test values
  # (not secrets), without the password of consent.
  python3 -c '
import base64, json, sys, yaml
earlier = {}
for doc in yaml.safe_load_all(open(sys.argv[1])):
    if doc and doc["metadata"]["name"] in ("t-postgres", "t-postgres-tls", "t-read-access", "t-wallet-database-roles"):
        name = doc["metadata"]["name"]
        earlier[name] = {"data": {key: base64.b64encode(f"earlier-{name}-{key}".encode()).decode()
                                  for key in doc["data"] if (name, key) != ("t-postgres", "igrant_consent")}}
json.dump(earlier, open(sys.argv[2], "w"))
' "$out/secrets-new.yaml" "$lookup_chart/earlier-secrets.json"
  if ! helm template t "$lookup_chart" --namespace ow "${lookup_args[@]}" --show-only templates/secrets.yaml > "$out/secrets-kept.yaml" 2> "$out/secrets.err"; then
    bad "upgrade keeps the values of the Secrets: $(head -c 200 "$out/secrets.err")"
  elif problems="$(python3 -c '
import json, sys, yaml
earlier = json.load(open(sys.argv[1]))
rendered = {doc["metadata"]["name"]: doc for doc in yaml.safe_load_all(open(sys.argv[2])) if doc}
for name, secret in sorted(earlier.items()):
    doc = rendered.get(name)
    if doc is None:
        print(f"the Secret {name} is missing")
        continue
    hooks = (doc["metadata"].get("annotations") or {}).get("helm.sh/hook")
    if hooks != "pre-install,pre-upgrade":
        print(f"the Secret {name} is not a pre-install,pre-upgrade hook")
    for key, value in sorted(secret["data"].items()):
        if doc["data"].get(key) != value:
            print(f"the Secret {name} has not the earlier value of {key}")
    for key in sorted(set(doc["data"]) - set(secret["data"])):
        if not doc["data"][key] or doc["data"][key] in secret["data"].values():
            print(f"the Secret {name} has no new value for {key}")
if "igrant_consent" not in rendered.get("t-postgres", {}).get("data", {}):
    print("the Secret t-postgres has no password of consent")
' "$lookup_chart/earlier-secrets.json" "$out/secrets-kept.yaml" 2>&1)" && [ -z "$problems" ]; then
    ok "upgrade keeps the values of the Secrets"
  else
    bad "upgrade keeps the values of the Secrets: $(printf '%s' "$problems" | tr '\n' ';' | head -c 300)"
  fi
fi
# The Secrets of the bundled Valkey and the TLS Secret of the bundled NATS
# are normal resources (no hook), and they keep the passwords of the users
# and the certificates of the earlier release (the copy of the chart reads
# them from earlier-secrets.json). The earlier Secret of the users has no
# password of the gateway: the render gives a new one.
if [ "$(grep -c -F -- "$stub_line" "$lookup_chart/templates/_helpers.tpl")" != 1 ]; then
  bad "upgrade keeps the Valkey Secrets: the copy of the chart has not the lookup stub"
else
  python3 -c '
import base64, json, sys, yaml
earlier = {}
for doc in yaml.safe_load_all(open(sys.argv[1])):
    if doc and doc["metadata"]["name"] in ("t-redis-users", "t-redis-tls", "t-nats-tls"):
        name = doc["metadata"]["name"]
        earlier[name] = {"data": {key: base64.b64encode(f"earlier-{name}-{key}".encode()).decode()
                                  for key in doc["data"] if (name, key) != ("t-redis-users", "gateway")}}
json.dump(earlier, open(sys.argv[2], "w"))
' "$out/secrets-new.yaml" "$lookup_chart/earlier-secrets.json"
  if ! helm template t "$lookup_chart" --namespace ow "${lookup_args[@]}" --show-only templates/secrets.yaml > "$out/redis-kept.yaml" 2> "$out/secrets.err"; then
    bad "upgrade keeps the Valkey Secrets: $(head -c 200 "$out/secrets.err")"
  elif problems="$(python3 -c '
import json, sys, yaml
earlier = json.load(open(sys.argv[1]))
rendered = {doc["metadata"]["name"]: doc for doc in yaml.safe_load_all(open(sys.argv[2])) if doc}
for name, secret in sorted(earlier.items()):
    doc = rendered.get(name, {"metadata": {}, "data": {}})
    if "helm.sh/hook" in (doc["metadata"].get("annotations") or {}):
        print(f"the Secret {name} is a hook")
    for key, value in sorted(secret["data"].items()):
        if doc["data"].get(key) != value:
            print(f"the Secret {name} has not the earlier value of {key}")
gateway = rendered.get("t-redis-users", {}).get("data", {}).get("gateway")
if not gateway or gateway in earlier["t-redis-users"]["data"].values():
    print("the Secret t-redis-users has no new password of the gateway")
' "$lookup_chart/earlier-secrets.json" "$out/redis-kept.yaml" 2>&1)" && [ -z "$problems" ]; then
    ok "upgrade keeps the Valkey Secrets and the NATS TLS Secret"
  else
    bad "upgrade keeps the Valkey Secrets and the NATS TLS Secret: $(printf '%s' "$problems" | tr '\n' ';' | head -c 300)"
  fi
fi

echo "result: ${pass} passed, ${fail} failed"
[ "$fail" -eq 0 ]
