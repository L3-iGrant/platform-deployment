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
#                 exposure-envoy-gateway, exposure-kgateway, exposure-none,
#                 exposure-on-premise
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
# 5. Rendered settings, also the services of the installation
#    (tests/check_installation.py): all services, consent or the wallet of
#    another release, without consent, without the wallet; the JetStream
#    store of NATS (store-check, and the fsGroupChangePolicy of a rollout
#    from a NATS StatefulSet in the cluster, which a copy of the chart reads
#    from a file in place of lookup); global.podSecurityContext and
#    global.containerSecurityContext under the values of the components.
# 6. Install and upgrade: tests/check_hook_order.py replays the steps of
#    Helm on the renders (each render of the matrix is an install; installs
#    with consent, the api or the organisation wallet off; an upgrade with
#    the same values, upgrades that turn the organisation wallet, consent
#    or the api on, and upgrades that install or remove consent or the
#    wallet). The Secrets that are hooks keep the values of
#    the earlier Secrets (a copy of the chart reads them from a file in place
#    of lookup).
# 7. The security settings of each container of each render:
#    tests/check_security.py and the Pod Security Standard "restricted" with
#    the upstream library (tests/psscheck; needs Go), and both checks refuse
#    the mutants of tests/values/pss-mutant.yaml and tests/fixtures/pss-pods.yaml.
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
  # Azure Key Vault and its host names (<vault>.vault.azure.net). The
  # table "organizations" of the API database in an SQL query is a name of
  # the API, not prose.
  hits="$(grep -n -i -E "$pattern" "$@" 2>/dev/null | grep -v -F 'tests/render-matrix.sh:' | grep -v -F 'tests/check_render.py:' \
    | grep -v -F 'tests/compose-files.sh:' \
    | grep -v -E '^[^:]*docs/upgrade\.md:[0-9]+: +FROM "organizations",$' \
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
# project in THIRD-PARTY-NOTICES.md; the licence texts of Valkey and of
# redis_exporter.
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
if "Copyright (c) 2016 Oliver" not in open(f"{chart}/licenses/redis_exporter/LICENSE").read():
    print("licenses/redis_exporter/LICENSE is not the licence of redis_exporter")
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
exposure_of() { case "$1" in exposure-ingress-*) echo ingress ;; exposure-none) echo none ;; exposure-on-premise) echo on-premise ;; *) echo gatewayAPI ;; esac; }
for database in postgresql-bundled postgresql-external; do
  for openbao in openbao-shamir openbao-external; do
    base=(-f "$keys" -f "$examples/site.yaml" -f "$examples/$database.yaml" -f "$examples/$openbao.yaml")
    if helm lint "$chart" --quiet "${base[@]}" > "$out/lint.txt" 2>&1; then
      ok "lint $database $openbao"
    else
      bad "lint $database $openbao"
      sed 's/^/  /' "$out/lint.txt" | head -10
    fi
    for exposure in exposure-ingress-nginx exposure-ingress-nginx-cert-manager exposure-envoy-gateway exposure-kgateway exposure-none exposure-on-premise; do
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
  elif grep -q -F -- "$expect" <<< "$text"; then
    ok "notes $name"
  else
    bad "notes $name: no \"$expect\""
  fi
}
notes "shamir" "bao operator unseal" -f "$examples/openbao-shamir.yaml"
notes "external OpenBao" "Make the platform operator organisation and its first platform admin" -f "$examples/openbao-external.yaml"
notes "platform operator of an installation that exists" "api.jobs.platformOperator" -f "$examples/openbao-external.yaml"
notes "URLs" "https://api.example.org" -f "$examples/openbao-shamir.yaml"
notes "placeholder tag warning" "global.imageTag is the placeholder" -f "$examples/openbao-shamir.yaml"
notes "connection budget of the bundled server" "can open 221 connections to it, and the hooks 5 more (max_connections" -f "$examples/openbao-shamir.yaml"
notes "connection budget of an external server" "set max_connections of your server to at least 226" -f "$examples/openbao-shamir.yaml" -f "$examples/postgresql-external.yaml"
notes "without consent" "Consent is not installed: the gateway answers 404 to the consent routes" -f "$examples/openbao-shamir.yaml" --set consent.enabled=false
notes "api.webhooks.events of an earlier values file" "WARNING: api.webhooks.events is not used" -f "$examples/openbao-shamir.yaml" \
  --set-json 'api.webhooks.events=["consent.allowed"]'
notes "without the wallet" "The organisation wallet is not installed" -f "$examples/openbao-shamir.yaml" --set organisationWallet.enabled=false
# The readers of the views of a service that is not installed open no
# connection: without the wallet, the api core and the webhook handler have
# no reader pool, and consent one reader (67 = 1 x 15 + 1 x 10 + 2 x 10 +
# 2 x 11); without consent, the wallet config role has one reader (221 less
# 2 x 16 of consent and 10).
notes "connection budget without the wallet" "can open 67 connections to it" -f "$examples/openbao-shamir.yaml" --set organisationWallet.enabled=false
notes "connection budget without consent" "can open 179 connections to it" -f "$examples/openbao-shamir.yaml" --set consent.enabled=false

# --- 4. The render guards --------------------------------------------------------
# Each case: the values that must stop the render, and a text of the message.
guard() {
  local name="$1" expect="$2"; shift 2
  local err
  if err="$(helm template t "$chart" --namespace ow -f "$keys" -f "$examples/site.yaml" "$@" 2>&1 >/dev/null)"; then
    bad "guard $name: the render did not stop"
  elif grep -q -F -- "$expect" <<< "$err"; then
    # A here-string, as in renders: with pipefail, "printf | grep -q"
    # fails when grep stops before printf has written all (SIGPIPE).
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
# The platform operator Jobs: the required values, one path at a time, an
# http or https policy URL, an organisation id without other characters,
# and no password as a value (the password is a file of a Secret).
bootstrap=(-f "$here/values/operator-jobs-bootstrap.yaml")
guard "platform operator without admin e-mail" "api.jobs.bootstrapPlatform.adminEmail" "${shamir[@]}" "${bootstrap[@]}" --set api.jobs.bootstrapPlatform.adminEmail=
guard "platform operator without admin name" "api.jobs.bootstrapPlatform.adminName" "${shamir[@]}" "${bootstrap[@]}" --set api.jobs.bootstrapPlatform.adminName=
guard "platform operator without password Secret" "api.jobs.bootstrapPlatform.passwordSecret" "${shamir[@]}" "${bootstrap[@]}" --set api.jobs.bootstrapPlatform.passwordSecret=
guard "platform operator without organisation name" "api.jobs.bootstrapPlatform.organisationName" "${shamir[@]}" "${bootstrap[@]}" --set api.jobs.bootstrapPlatform.organisationName=
guard "platform operator without organisation type" "api.jobs.bootstrapPlatform.type" "${shamir[@]}" "${bootstrap[@]}" --set api.jobs.bootstrapPlatform.type=
guard "platform operator without location" "api.jobs.bootstrapPlatform.location" "${shamir[@]}" "${bootstrap[@]}" --set api.jobs.bootstrapPlatform.location=
guard "platform operator without policy URL" "api.jobs.bootstrapPlatform.policyUrl" "${shamir[@]}" "${bootstrap[@]}" --set api.jobs.bootstrapPlatform.policyUrl=
guard "platform operator policy URL not http" "policyUrl" "${shamir[@]}" "${bootstrap[@]}" --set api.jobs.bootstrapPlatform.policyUrl=ftp://example.org/privacy
guard "platform operator password as a value" "Additional property password" "${shamir[@]}" "${bootstrap[@]}" --set api.jobs.bootstrapPlatform.password=not-a-value
guard "platform operator with the first admin Job" "api.jobs.bootstrapPlatform cannot run with api.jobs.registerAdmin" "${shamir[@]}" "${bootstrap[@]}" -f "$here/values/operator-jobs-old.yaml"
guard "platform operator of a new and of an existing installation" "enable only one of them" "${shamir[@]}" "${bootstrap[@]}" -f "$here/values/operator-jobs-upgrade.yaml"
guard "existing platform operator without organisation id" "api.jobs.platformOperator.organisationId" "${shamir[@]}" -f "$here/values/operator-jobs-upgrade.yaml" --set api.jobs.platformOperator.organisationId=
guard "existing platform operator without admin e-mail" "api.jobs.platformOperator.adminEmail" "${shamir[@]}" -f "$here/values/operator-jobs-upgrade.yaml" --set api.jobs.platformOperator.adminEmail=
guard "existing platform operator organisation id with a space" "organisationId" "${shamir[@]}" -f "$here/values/operator-jobs-upgrade.yaml" --set-string "api.jobs.platformOperator.organisationId=6731 --allow-last"
guard "feature gate not a boolean" "enforce" "${shamir[@]}" --set-string gateway.features.enforce=off
# The /tmp of the workers is 64Mi in memory (the audit export writes no
# local file): the schema refuses the removed values.
guard "removed worker /tmp size" "Additional property tmp is not allowed" "${shamir[@]}" --set organisationWallet.workers.tmp.sizeLimit=10Gi
# A folder that a process writes must be on an emptyDir of its pod (the
# root file system is read-only).
guard "wallet state folder outside the emptyDir" "has worker.state_directory \"/var/ows\"" "${shamir[@]}" --set organisationWallet.extraConfig.worker.state_directory=/var/ows
# No log file (ow.noLogFile): each process logs to stdout, also with a path
# on an emptyDir (a rotating file of 100 MB x 6 fills the /tmp of 64Mi).
no_log_file="the chart writes no log file in Kubernetes"
guard "no wallet log file" "organisationWallet.extraConfig sets log_file.path \"/tmp/ows.log\": $no_log_file" "${shamir[@]}" --set organisationWallet.extraConfig.log_file.path=/tmp/ows.log
guard "no wallet log file outside /tmp" "organisationWallet.extraConfig sets log_file.path \"/var/log/ows.log\": $no_log_file" "${shamir[@]}" --set organisationWallet.extraConfig.log_file.path=/var/log/ows.log
guard "no api log file" "api.extraConfig sets Log.file.path \"/tmp/api.log\": $no_log_file" "${shamir[@]}" --set api.extraConfig.Log.file.path=/tmp/api.log
guard "no gateway log file" "gateway.extraConfig sets Log.file.path \"/tmp/gateway.log\": $no_log_file" "${shamir[@]}" --set gateway.extraConfig.Log.file.path=/tmp/gateway.log
guard "no consent log file" "consent.extraConfig sets Log.file.path \"/tmp/consent.log\": $no_log_file" "${shamir[@]}" --set consent.extraConfig.Log.file.path=/tmp/consent.log
# /tmp of the api (api.tmp, an emptyDir in memory): it holds one upload of
# the largest body of the gateway above 32 MiB (the multipart parser of Go
# writes such a file part whole to /tmp), and the memory request and /tmp
# fit below the memory limit of the container (ow.api.checkTmp).
guard "api /tmp below the file body limit of the gateway" "api.tmp.sizeLimit (64Mi, 67108864 bytes) is below the largest body that the gateway sends to the api (104857600 bytes" "${shamir[@]}" \
  --set gateway.proxy.maxBodyBytes.file=104857600
guard "api /tmp below the default body limit of the gateway" "is below the largest body that the gateway sends to the api (67108865 bytes" "${shamir[@]}" \
  --set gateway.proxy.maxBodyBytes.default=67108865
guard "api /tmp just below a body above 32 MiB" "api.tmp.sizeLimit (32Mi, 33554432 bytes) is below the largest body that the gateway sends to the api (33554433 bytes" "${shamir[@]}" \
  --set gateway.proxy.maxBodyBytes.file=33554433 --set api.tmp.sizeLimit=32Mi
guard "api memory limit below the request and /tmp" "api.resources: the memory request (272Mi) and api.tmp.sizeLimit (64Mi) together are above the memory limit (300Mi)" "${shamir[@]}" \
  --set api.resources.limits.memory=300Mi
guard "webhook memory limit below the request and /tmp" "api.webhook.resources: the memory request (32Mi) and api.tmp.sizeLimit (64Mi) together are above the memory limit (90Mi)" "${shamir[@]}" \
  --set api.webhook.resources.limits.memory=90Mi
guard "api /tmp size not a size" "api.tmp.sizeLimit" "${shamir[@]}" --set api.tmp.sizeLimit=64MB
# The stop of the HTTP pods (ow.checkStopBudget, the dashboard guard and the
# schema): the grace period covers the preStop sleep and the stop of the
# server; a preStop of 0 seconds and a strategy other than RollingUpdate
# stop the render.
guard "gateway stop budget with the preStop" "gateway.terminationGracePeriodSeconds (35) must be at least preStopSeconds (10) + drainSeconds (5) + gracefulShutdownSeconds (20) + 5 = 40" "${shamir[@]}" \
  --set gateway.terminationGracePeriodSeconds=35
guard "api stop budget with the preStop" "api.server.terminationGracePeriodSeconds (40) must be at least preStopSeconds (15)" "${shamir[@]}" --set api.server.preStopSeconds=15
guard "consent stop budget with the preStop" "consent.server.terminationGracePeriodSeconds (39)" "${shamir[@]}" --set consent.server.terminationGracePeriodSeconds=39
guard "dashboard stop budget" "enterpriseDashboard.terminationGracePeriodSeconds (15) must be at least preStopSeconds (10) + 10" "${shamir[@]}" \
  --set enterpriseDashboard.terminationGracePeriodSeconds=15
guard "wallet stop budget" "organisationWallet.server: preStopSeconds (20) + gracefulShutdownSeconds (20) + backgroundShutdownSeconds (10) = 50 must be below terminationGracePeriodSeconds (45)" "${shamir[@]}" \
  --set organisationWallet.server.preStopSeconds=20
guard "preStop of 0 seconds" "preStopSeconds" "${shamir[@]}" --set api.server.preStopSeconds=0
guard "rollout strategy Recreate" "strategy" "${shamir[@]}" --set gateway.strategy.type=Recreate

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
# The operator Jobs of the api (tests/check_operator_jobs.py): none by
# default; the three Jobs of the earlier releases render as before (their
# values file of the earlier install page); the platform operator of a new
# installation (onboard bootstrap-platform) and of an installation that
# exists (platform set-operator, then platform grant-admin). The password is
# a file of its own Secret, never an argument, a variable or a ConfigMap
# value.
operator_jobs() {
  local case="$1"; shift
  local file="$out/operator-jobs-$case.yaml" result
  if ! result="$(helm template t "$chart" --namespace ow -f "$keys" -f "$examples/site.yaml" "${shamir[@]}" "$@" 2>&1 > "$file")"; then
    bad "operator Jobs $case: $(printf '%s' "$result" | head -c 300)"
  elif result="$(python3 "$here/check_operator_jobs.py" "$file" "$case" 2>&1)"; then
    ok "operator Jobs $case"
  else
    bad "operator Jobs $case"
    printf '%s\n' "$result" | sed 's/^/  /' | head -20
  fi
}
operator_jobs none
operator_jobs old -f "$here/values/operator-jobs-old.yaml"
operator_jobs bootstrap -f "$here/values/operator-jobs-bootstrap.yaml"
operator_jobs operator -f "$here/values/operator-jobs-upgrade.yaml"
# The feature gate of the gateway (Features.enforce): on by default, off
# with gateway.features.enforce false, and gateway.extraConfig still wins.
renders "feature gate on by default" "enforce: true" "${shamir[@]}"
renders "feature gate off" "enforce: false" "${shamir[@]}" --set gateway.features.enforce=false
lacks "feature gate off has no enforce true" "enforce: true" "${shamir[@]}" --set gateway.features.enforce=false
renders "feature gate off with extraConfig" "enforce: false" "${shamir[@]}" --set gateway.extraConfig.Features.enforce=false
# The webhook event types: the effective features of each organisation
# select them, so the api files have no Webhooks.events. A values file of an
# earlier release that sets api.webhooks.events still renders (the schema
# accepts the value for one release), the files do not have it, and the
# notes tell to remove it.
events='api.webhooks.events=["consent.allowed","data.delete.initiated"]'
renders "webhook delivery retention of the api files" "DeliveryRetentionDays: 10" "${shamir[@]}" --show-only templates/api/configmap.yaml
lacks "no webhook event types in the api files" "consent.allowed" "${shamir[@]}" --show-only templates/api/configmap.yaml
lacks "api.webhooks.events of an earlier values file is not rendered" "consent.allowed" "${shamir[@]}" --set-json "$events" --show-only templates/api/configmap.yaml
# The API core publishes the deletion of an organisation (contract/v2 E10).
renders "api publishes the organisation deleted event" '"api.v1.evt.organisation.deleted"' "${shamir[@]}"
# The key store providers and the EU trusted list check of the wallet.
renders "EU trusted list check on by default" "eu_lotl_url: https://ec.europa.eu/tools/lotl/eu-lotl.xml" "${shamir[@]}"
renders "EU trusted list check off" "eu_lotl_url: null" "${shamir[@]}" --set organisationWallet.trustList.euLotlUrl=
# The refresh of the list trust sources (trust_sources.*); the shared trust
# list lookup service is gone (no lookup_url, no lookup token file).
renders "trust sources refresh defaults" "refresh_max_interval_seconds: 86400" "${shamir[@]}"
renders "trust sources stale grace" "stale_grace_seconds: 3600" "${shamir[@]}" --set organisationWallet.trustSources.staleGraceSeconds=3600
lacks "no trust list lookup service" "lookup_url" "${shamir[@]}"
lacks "no trust list lookup token" "trust-list-lookup-token" "${shamir[@]}"
guard "removed trust list lookup value" "Additional property lookupUrl" "${shamir[@]}" --set organisationWallet.trustList.lookupUrl=https://trustlist.example.org/lookup
guard "trust sources refresh interval too short" "refreshMinIntervalSeconds" "${shamir[@]}" --set organisationWallet.trustSources.refreshMinIntervalSeconds=10
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
for file in ("service.yaml", "config.yaml", "worker-main.yaml", "worker-maintenance.yaml"):
    test_ca = yaml.safe_load(data[file])["kms"].get("test_ca")
    if test_ca != expected:
        print(f"{file} kms.test_ca is {test_ca!r}")
if "kms" in yaml.safe_load(data["clock.yaml"]):
    print("clock.yaml has kms")
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
for role in ("service", "config", "worker-main", "worker-maintenance", "clock"):
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
# The Play Integrity keys of the wallet (wallet_unit.play_integrity): only
# the service file names them and only the service pods mount them; the
# service account of the earlier releases is gone.
play_integrity() {
  local name="$1" expect="$2"; shift 2
  local problems
  # Only stdout is YAML (helm writes its warnings to stderr).
  if ! helm template t "$chart" --namespace ow -f "$keys" -f "$examples/site.yaml" "$@" > "$out/play.yaml" 2> "$out/play.err"; then
    bad "play integrity $name: $(head -c 200 "$out/play.err")"
  elif problems="$(python3 - "$out/play.yaml" "$expect" <<'PY' 2>&1
import json, sys, yaml
docs = [d for d in yaml.safe_load_all(open(sys.argv[1])) if d]
expected = json.loads(sys.argv[2])
def find(kind, name):
    return next(d for d in docs if d.get("kind") == kind and d["metadata"]["name"] == name)
files = find("ConfigMap", "t-wallet")["data"]
for role in ("service", "config", "worker-main", "worker-maintenance", "clock"):
    unit = yaml.safe_load(files[f"{role}.yaml"]).get("wallet_unit") or {}
    want = expected["play_integrity"] if role == "service" else None
    if unit.get("play_integrity") != want:
        print(f"{role}.yaml wallet_unit.play_integrity is {unit.get('play_integrity')!r}")
    want = expected["digests"] if role == "service" else None
    if unit.get("android_signing_certificate_digests") != want:
        print(f"{role}.yaml wallet_unit.android_signing_certificate_digests is {unit.get('android_signing_certificate_digests')!r}")
    if "play_integrity_credentials_file" in unit:
        print(f"{role}.yaml names the service account of Play Integrity")
    pod = find("Deployment", f"t-wallet-{role}")["spec"]["template"]["spec"]
    mounted = {item["path"]: [source["secret"]["name"], item["key"]] for volume in pod["volumes"] if volume["name"] == "secrets"
               for source in volume["projected"]["sources"] for item in source["secret"]["items"]}
    secrets = {path: secret for path, secret in mounted.items() if path.startswith("play-integrity")}
    if secrets != (expected["secrets"] if role == "service" else {}):
        print(f"the {role} pods mount {secrets!r} as the Play Integrity keys")
PY
)" && [ -z "$problems" ]; then
    ok "play integrity $name"
  else
    bad "play integrity $name: $(printf '%s' "$problems" | tr '\n' ';' | head -c 300)"
  fi
}
digest=ed5ed923ed30fab5ef5721931f43d1270b13340045bbbef31e0a9927a57e4142
play_integrity "no keys by default" '{"play_integrity": null, "digests": null, "secrets": {}}' "${shamir[@]}"
play_integrity "digests without keys" "{\"play_integrity\": null, \"digests\": [\"$digest\"], \"secrets\": {}}" "${shamir[@]}" \
  --set "organisationWallet.walletUnit.androidSigningCertificateDigests={$digest}"
play_integrity "keys in the service pods only" "{\"play_integrity\": {\"decryption_key_file\": \"/run/secrets/eudi-wallet/play-integrity-decryption-key\", \"verification_key_file\": \"/run/secrets/eudi-wallet/play-integrity-verification-key\", \"package_name\": \"io.igrant.mobileagent\", \"min_version_code\": 42}, \"digests\": [\"$digest\"], \"secrets\": {\"play-integrity-decryption-key\": [\"play\", \"decryption-key\"], \"play-integrity-verification-key\": [\"play\", \"verification-key\"]}}" "${shamir[@]}" \
  --set organisationWallet.walletUnit.playIntegrity.existingSecret=play --set "organisationWallet.walletUnit.androidSigningCertificateDigests={$digest}" \
  --set organisationWallet.walletUnit.playIntegrity.minVersionCode=42
guard "Play Integrity keys without the certificate digest" "androidSigningCertificateDigests needs the SHA-256" "${shamir[@]}" --set organisationWallet.walletUnit.playIntegrity.existingSecret=play
guard "Android signing certificate digest not hex" "androidSigningCertificateDigests" "${shamir[@]}" --set "organisationWallet.walletUnit.androidSigningCertificateDigests={not-a-digest}"
guard "the Play Integrity digest value is gone" "certificateSha256Digests" "${shamir[@]}" --set "organisationWallet.walletUnit.playIntegrity.certificateSha256Digests={$digest}"
guard "the Play Integrity service account is gone" "key" "${shamir[@]}" --set organisationWallet.walletUnit.playIntegrity.key=service_account.json
# The App IDs of the iOS wallet apps (wallet_unit.app_attest.app_ids): only
# the service file names them (the WIA and key attestation requests).
app_attest() {
  local name="$1" expect="$2"; shift 2
  local problems
  # Only stdout is YAML (helm writes its warnings to stderr).
  if ! helm template t "$chart" --namespace ow -f "$keys" -f "$examples/site.yaml" "$@" > "$out/app-attest.yaml" 2> "$out/app-attest.err"; then
    bad "app attest $name: $(head -c 200 "$out/app-attest.err")"
  elif problems="$(python3 - "$out/app-attest.yaml" "$expect" <<'PY' 2>&1
import json, sys, yaml
docs = [d for d in yaml.safe_load_all(open(sys.argv[1])) if d]
expected = json.loads(sys.argv[2])
files = next(d for d in docs if d.get("kind") == "ConfigMap" and d["metadata"]["name"] == "t-wallet")["data"]
for role in ("service", "config", "worker-main", "worker-maintenance", "clock"):
    unit = yaml.safe_load(files[f"{role}.yaml"]).get("wallet_unit") or {}
    want = {"app_ids": expected} if role == "service" else None
    if unit.get("app_attest") != want:
        print(f"{role}.yaml wallet_unit.app_attest is {unit.get('app_attest')!r}")
PY
)" && [ -z "$problems" ]; then
    ok "app attest $name"
  else
    bad "app attest $name: $(printf '%s' "$problems" | tr '\n' ';' | head -c 300)"
  fi
}
app_ids='Y9726WB7V8.io.iGrant.DataWallet,ABCDE12345.com.example.wallet'
app_attest "the iGrant.io Data Wallet app by default" '["Y9726WB7V8.io.iGrant.DataWallet"]' "${shamir[@]}"
app_attest "the App IDs of two iOS apps" '["Y9726WB7V8.io.iGrant.DataWallet", "ABCDE12345.com.example.wallet"]' "${shamir[@]}" \
  --set "organisationWallet.walletUnit.appAttest.appIds={$app_ids}"
app_attest "no App ID without the production checks" '[]' "${shamir[@]}" --set-json 'organisationWallet.walletUnit.appAttest.appIds=[]'
guard "no App ID with the production checks" "appAttest.appIds needs at least one App ID" "${shamir[@]}" \
  --set organisationWallet.walletUnit.productionChecksEnabled=true --set-json 'organisationWallet.walletUnit.appAttest.appIds=[]'
guard "App ID without the Team ID" "appIds" "${shamir[@]}" --set "organisationWallet.walletUnit.appAttest.appIds={io.iGrant.DataWallet}"
# The device roots of the wallet units (wallet_unit.trust_anchors_dir): with
# a ConfigMap, the service, config and worker files name the folder and
# their pods mount the two root files of the ConfigMap; the clock never.
# Without one, no file names the folder (the roots of the image).
trust_anchors() {
  local name="$1" expect="$2"; shift 2
  local problems
  # Only stdout is YAML (helm writes its warnings to stderr).
  if ! helm template t "$chart" --namespace ow -f "$keys" -f "$examples/site.yaml" "$@" > "$out/anchors.yaml" 2> "$out/anchors.err"; then
    bad "trust anchors $name: $(head -c 200 "$out/anchors.err")"
  elif problems="$(python3 - "$out/anchors.yaml" "$expect" <<'PY' 2>&1
import json, sys, yaml
docs = [d for d in yaml.safe_load_all(open(sys.argv[1])) if d]
expected = json.loads(sys.argv[2])
def find(kind, name):
    return next(d for d in docs if d.get("kind") == kind and d["metadata"]["name"] == name)
files = find("ConfigMap", "t-wallet")["data"]
for role in ("service", "config", "worker-main", "worker-maintenance", "clock"):
    mounts = expected["configmap"] is not None and role != "clock"
    unit = yaml.safe_load(files[f"{role}.yaml"]).get("wallet_unit") or {}
    want = "/etc/eudi-wallet-trust-anchors" if mounts else None
    if unit.get("trust_anchors_dir") != want:
        print(f"{role}.yaml wallet_unit.trust_anchors_dir is {unit.get('trust_anchors_dir')!r}")
    pod = find("Deployment", f"t-wallet-{role}")["spec"]["template"]["spec"]
    volumes = [v for v in pod["volumes"] if v["name"] == "trust-anchors"]
    got = [[v["configMap"]["name"], sorted(i["key"] for i in v["configMap"]["items"])] for v in volumes]
    want = [[expected["configmap"], ["apple_app_attestation_root_ca.pem", "google_hardware_attestation_root.pem"]]] if mounts else []
    if got != want:
        print(f"the {role} pods have the trust anchor volumes {got!r}")
    paths = [m["mountPath"] for c in pod["containers"] for m in c["volumeMounts"] if m["name"] == "trust-anchors"]
    if paths != (["/etc/eudi-wallet-trust-anchors"] if mounts else []):
        print(f"the {role} pods mount the trust anchors at {paths!r}")
PY
)" && [ -z "$problems" ]; then
    ok "trust anchors $name"
  else
    bad "trust anchors $name: $(printf '%s' "$problems" | tr '\n' ';' | head -c 300)"
  fi
}
trust_anchors "the roots of the image by default" '{"configmap": null}' "${shamir[@]}"
trust_anchors "the roots of a ConfigMap" '{"configmap": "test-roots"}' "${shamir[@]}" \
  --set organisationWallet.walletUnit.trustAnchors.existingConfigMap=test-roots
# The limits of the installation: Limits.maxOrganisations of the api and
# webhook files (api.limits.maxOrganisations) and
# wallet_unit.organisation_wallet_units_max of the service, config and
# worker files (organisationWallet.walletUnit.organisationWalletUnitsMax),
# as integers, only when a value is set: an api or a wallet of a release
# before the input limits refuses the keys. No other object has them: not
# the gateway file (the gateway refuses the section), the clock, the
# hooks or the Jobs.
installation_limits() {
  local name="$1" expect="$2"; shift 2
  local problems
  # Only stdout is YAML (helm writes its warnings to stderr).
  if ! helm template t "$chart" --namespace ow -f "$keys" -f "$examples/site.yaml" "$@" > "$out/limits.yaml" 2> "$out/limits.err"; then
    bad "installation limits $name: $(head -c 200 "$out/limits.err")"
  elif problems="$(python3 - "$out/limits.yaml" "$expect" <<'PY' 2>&1
import json, sys, yaml
docs = [d for d in yaml.safe_load_all(open(sys.argv[1])) if d]
expected = json.loads(sys.argv[2])
def data(name):
    return next(d for d in docs if d.get("kind") == "ConfigMap" and d["metadata"]["name"] == name)["data"]
checked = set()
want = None if expected["organisations"] is None else {"maxOrganisations": expected["organisations"]}
for file in ("api.yaml", "webhook.yaml"):
    got = yaml.safe_load(data("t-api")[file]).get("Limits")
    if got != want or (got is not None and type(got.get("maxOrganisations")) is not int):
        print(f"{file} Limits is {got!r}")
    checked.add(("t-api", file))
wallet = data("t-wallet")
roles = [file for file in wallet if file in ("service.yaml", "config.yaml") or file.startswith("worker-")]
if len(roles) < 3:
    print(f"the wallet files are {sorted(wallet)}")
for file in roles:
    got = (yaml.safe_load(wallet[file]).get("wallet_unit") or {}).get("organisation_wallet_units_max")
    if got != expected["units"] or (got is not None and type(got) is not int):
        print(f"{file} wallet_unit.organisation_wallet_units_max is {got!r}")
    checked.add(("t-wallet", file))
for doc in docs:
    name = doc["metadata"]["name"]
    parts = (doc.get("data") or {}).items() if doc.get("kind") == "ConfigMap" else [("", yaml.safe_dump(doc))]
    for key, text in parts:
        for word in ("maxOrganisations", "organisation_wallet_units_max"):
            if (name, key) not in checked and word in str(text):
                print(f"{doc['kind']} {name} {key} has {word}")
PY
)" && [ -z "$problems" ]; then
    ok "installation limits $name"
  else
    bad "installation limits $name: $(printf '%s' "$problems" | tr '\n' ';' | head -c 300)"
  fi
}
installation_limits "no key by default" '{"organisations": null, "units": null}' "${shamir[@]}"
installation_limits "no key with empty values" '{"organisations": null, "units": null}' "${shamir[@]}" \
  --set api.limits.maxOrganisations= --set organisationWallet.walletUnit.organisationWalletUnitsMax=
installation_limits "the two limits" '{"organisations": 50, "units": 60}' "${shamir[@]}" \
  --set api.limits.maxOrganisations=50 --set organisationWallet.walletUnit.organisationWalletUnitsMax=60
installation_limits "only the organisation limit" '{"organisations": 40, "units": null}' "${shamir[@]}" --set api.limits.maxOrganisations=40
installation_limits "only the organisation wallet unit limit" '{"organisations": null, "units": 40}' "${shamir[@]}" \
  --set organisationWallet.walletUnit.organisationWalletUnitsMax=40
# A values file gives a number as a float: the files have the integer, not 1e+06.
installation_limits "the largest limits as JSON numbers" '{"organisations": 100, "units": 100}' "${shamir[@]}" \
  --set-json 'api.limits={"maxOrganisations": 100}' --set-json 'organisationWallet.walletUnit.organisationWalletUnitsMax=100'
guard "organisation limit 0" "api.limits.maxOrganisations" "${shamir[@]}" --set api.limits.maxOrganisations=0
guard "organisation limit over 100" "api.limits.maxOrganisations" "${shamir[@]}" --set api.limits.maxOrganisations=101
guard "organisation limit as a string" "api.limits.maxOrganisations" "${shamir[@]}" --set-string api.limits.maxOrganisations=50
guard "organisation wallet unit limit 0" "organisationWallet.walletUnit.organisationWalletUnitsMax" "${shamir[@]}" \
  --set organisationWallet.walletUnit.organisationWalletUnitsMax=0
guard "organisation wallet unit limit over 100" "organisationWallet.walletUnit.organisationWalletUnitsMax" "${shamir[@]}" \
  --set organisationWallet.walletUnit.organisationWalletUnitsMax=101
guard "organisation wallet unit limit as a string" "organisationWallet.walletUnit.organisationWalletUnitsMax" "${shamir[@]}" \
  --set-string organisationWallet.walletUnit.organisationWalletUnitsMax=50
# The services of the installation (docs/components.md): Installation.services
# in the api, webhook and gateway files only when a service is not
# installed, and no upstream, object, read user, trust, NATS user or Valkey
# user of that service (tests/check_installation.py). A release without a
# service needs no key of it: the cases remove its public keys and its NATS
# users. Each case is also an install (tests/check_hook_order.py) and, with
# network policies, the network matrix (tests/check_network_matrix.py).
no_consent=(--set consent.enabled=false --set serviceKeys.publicJwks.igrant-consent-management=null --set nats.auth.users.consent=null)
no_wallet=(--set organisationWallet.enabled=false --set organisationWallet.host= --set serviceKeys.publicJwks.eudi-wallet=null
  --set nats.auth.users.walletConfig=null --set nats.auth.users.walletService=null --set nats.auth.users.walletWorker=null)
installation() {
  local name="$1" case="$2"; shift 2
  local file="$out/installation-${name// /-}.yaml" result good=1
  if ! result="$(helm template t "$chart" --namespace ow -f "$keys" -f "$examples/site.yaml" "$@" 2>&1 > "$file")"; then
    bad "installation $name: $(printf '%s' "$result" | head -c 300)"
    return
  fi
  if ! result="$(python3 "$here/check_installation.py" "$file" "$case" 2>&1)"; then
    good=0
    printf '%s\n' "$result" | sed 's/^/  /' | head -20
  fi
  if ! python3 "$here/check_hook_order.py" install "$file"; then
    good=0
  fi
  if grep -q -x 'kind: NetworkPolicy' "$file" && ! python3 "$here/check_network_matrix.py" "$file" "$chart/policies/network-matrix.yaml"; then
    good=0
  fi
  if [ "$good" = 1 ]; then ok "installation $name"; else bad "installation $name"; fi
}
installation "all services" all "${shamir[@]}"
installation "all services with network policies" all "${shamir[@]}" -f "$examples/networkpolicy.yaml"
installation "consent of another release" consent-elsewhere "${shamir[@]}" --set consent.enabled=false --set gateway.upstreams.consent.url=http://consent.example.org
installation "the wallet of another release" wallet-elsewhere "${shamir[@]}" --set organisationWallet.enabled=false --set gateway.upstreams.walletConfig.url=http://wallet.example.org
installation "without consent" no-consent "${shamir[@]}" "${no_consent[@]}"
installation "without consent, network policies" no-consent "${shamir[@]}" "${no_consent[@]}" -f "$examples/networkpolicy.yaml"
installation "without consent, external database" no-consent "${shamir[@]}" "${no_consent[@]}" -f "$examples/postgresql-external.yaml"
installation "without the wallet" no-wallet "${shamir[@]}" "${no_wallet[@]}"
installation "without the wallet, network policies" no-wallet "${shamir[@]}" "${no_wallet[@]}" -f "$examples/networkpolicy.yaml"
installation "without the wallet, external database" no-wallet "${shamir[@]}" "${no_wallet[@]}" -f "$examples/postgresql-external.yaml"
# api.extraConfig and gateway.extraConfig cannot set another list: the
# same services are accepted, and the files have the form of the chart.
installation "without consent, the same list in api.extraConfig" no-consent "${shamir[@]}" "${no_consent[@]}" \
  --set-json 'api.extraConfig.Installation={"services":["wallet"]}' --set-json 'gateway.extraConfig.Installation={"services":["wallet"]}'
installation "all services, the full list in api.extraConfig" all "${shamir[@]}" --set-json 'api.extraConfig.Installation={"services":["consent","wallet"]}'
guard "no service installed" "the installation has no service" "${shamir[@]}" --set consent.enabled=false --set organisationWallet.enabled=false
guard "privacy dashboard without consent" "privacyDashboard.enabled needs the consent service" "${shamir[@]}" "${no_consent[@]}" \
  --set privacyDashboard.enabled=true --set privacyDashboard.namespace=privacy-dashboards
guard "api.extraConfig.Installation that differs" "api.extraConfig.Installation names other services than this release (wallet, consent)" "${shamir[@]}" \
  --set-json 'api.extraConfig.Installation={"services":["wallet"]}'
guard "gateway.extraConfig.Installation that differs" "gateway.extraConfig.Installation names other services than this release (wallet)" "${shamir[@]}" "${no_consent[@]}" \
  --set-json 'gateway.extraConfig.Installation={"services":["wallet","consent"]}'
guard "api.extraConfig.Installation without services" "api.extraConfig.Installation names other services" "${shamir[@]}" "${no_consent[@]}" \
  --set-json 'api.extraConfig.Installation={}'
guard "without consent, the public keys of the wallet are still required" "serviceKeys.publicJwks.eudi-wallet" "${shamir[@]}" "${no_consent[@]}" \
  --set serviceKeys.publicJwks.eudi-wallet=null
guard "without the wallet, the public keys of consent are still required" "serviceKeys.publicJwks.igrant-consent-management" "${shamir[@]}" "${no_wallet[@]}" \
  --set serviceKeys.publicJwks.igrant-consent-management=null
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
# The wallet provider split replaced the scope wallet_provider with
# individual_wallet_provider and business_wallet_provider.
guard "audit retention of the old wallet provider scope" "organisationWallet.audit.scopeRetentionYears" "${shamir[@]}" --set organisationWallet.audit.scopeRetentionYears.wallet_provider=10
renders "audit retention of the individual wallet provider scope" "individual_wallet_provider: 10" "${shamir[@]}" --set organisationWallet.audit.scopeRetentionYears.individual_wallet_provider=10
renders "audit retention of the business wallet provider scope" "business_wallet_provider: 12" "${shamir[@]}" --set organisationWallet.audit.scopeRetentionYears.business_wallet_provider=12
guard "retention purge batch size" "organisationWallet.retention.batchSize" "${shamir[@]}" --set organisationWallet.retention.batchSize=20000
renders "retention purge of a deactivated sandbox" "deactivated_sandbox_days: 14" "${shamir[@]}" --set organisationWallet.retention.deactivatedSandboxDays=14
renders "retention of the tokens of the issued credentials" "issued_credential_token_days: 90" "${shamir[@]}" --set organisationWallet.retention.issuedCredentialTokenDays=90 --show-only templates/wallet/configmap.yaml
guard "retention of the tokens of the issued credentials" "organisationWallet.retention.issuedCredentialTokenDays" "${shamir[@]}" --set organisationWallet.retention.issuedCredentialTokenDays=0

renders "local backend openbao by default" "local_backend: openbao" "${shamir[@]}"
# The longest wallet database name: 43 characters.
renders "wallet database name of 43 characters" "user: w234567890123456789012345678901234567890123_launcher_app" "${shamir[@]}" --set database.databases.wallet.name=w234567890123456789012345678901234567890123
# The WIA pool refill is an actor of the workers, not a NATS event.
lacks "no WIA pool refill event" "ows.wia_pool.refill_requested" "${shamir[@]}"
# The scheduler is gone (organisation-wallet-suite removed it): no object, user or value of it.
lacks "no scheduler" "scheduler" "${shamir[@]}" -f "$examples/networkpolicy.yaml"
guard "no scheduler value" "Additional property scheduler" "${shamir[@]}" --set organisationWallet.scheduler.replicas=1
guard "no NATS user of the scheduler" "Additional property walletScheduler" "${shamir[@]}" --set nats.auth.users.walletScheduler.nkey=UTESTWALLETSCHEDULER
guard "no egress profiles of the scheduler" 'networkPolicy.egress.roles.wallet-scheduler: "wallet-scheduler" is not a network role' "${shamir[@]}" --set-json 'networkPolicy.egress.roles.wallet-scheduler=["internet"]'
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
# The alert rules (organisationWallet.prometheusRule; tests/alert-rules.sh
# runs them with promtool): none by default, only with the ServiceMonitor.
lacks "no PrometheusRule by default" "kind: PrometheusRule" "${shamir[@]}" --set organisationWallet.serviceMonitor.enabled=true
renders "PrometheusRule of the wallet: the stopped audit exports are critical" "alert: AuditExportStopped" "${shamir[@]}" --set organisationWallet.serviceMonitor.enabled=true --set organisationWallet.prometheusRule.enabled=true --show-only templates/wallet/prometheusrule.yaml
renders "PrometheusRule of the wallet: the labels for the rule selector" "release: kube-prometheus" "${shamir[@]}" --set organisationWallet.serviceMonitor.enabled=true --set organisationWallet.prometheusRule.enabled=true --set-json 'organisationWallet.prometheusRule.labels={"release":"kube-prometheus"}' --show-only templates/wallet/prometheusrule.yaml
guard "PrometheusRule without the ServiceMonitor" "organisationWallet.prometheusRule needs organisationWallet.serviceMonitor.enabled" "${shamir[@]}" --set organisationWallet.prometheusRule.enabled=true
# The servers (service and config): a headless Service of the port metrics
# (9190) and the job wallet-server; the ServiceMonitor names the jobs with
# the label metrics.igrant.io/job.
renders "metrics Service of the service role" "name: t-wallet-service-metrics" "${shamir[@]}" --set organisationWallet.serviceMonitor.enabled=true --show-only templates/wallet/servicemonitor.yaml
renders "metrics Service of the config role" "name: t-wallet-config-metrics" "${shamir[@]}" --set organisationWallet.serviceMonitor.enabled=true --show-only templates/wallet/servicemonitor.yaml
renders "job of the server targets" "metrics.igrant.io/job: wallet-server" "${shamir[@]}" --set organisationWallet.serviceMonitor.enabled=true --show-only templates/wallet/servicemonitor.yaml
renders "job label of the ServiceMonitor" "jobLabel: metrics.igrant.io/job" "${shamir[@]}" --set organisationWallet.serviceMonitor.enabled=true --show-only templates/wallet/servicemonitor.yaml
renders "scrape interval of the servers" "interval: 15s" "${shamir[@]}" --set organisationWallet.serviceMonitor.enabled=true --show-only templates/wallet/servicemonitor.yaml
lacks "no metrics port in the Services of the routes" "9190" "${shamir[@]}" --show-only templates/wallet/svc.yaml
renders "metrics Service of a worker group (also the pods that are not ready)" "publishNotReadyAddresses: true" "${shamir[@]}" --set organisationWallet.serviceMonitor.enabled=true --show-only templates/wallet/servicemonitor.yaml
# The health port of the workers and of the clock (the scrape of
# /metrics): open only to the monitoring namespace (networkPolicy.monitoring).
# The port metrics of the servers: open only to the monitoring namespace.
if problems="$(helm template t "$chart" --namespace ow -f "$keys" -f "$examples/site.yaml" "${shamir[@]}" -f "$examples/networkpolicy.yaml" \
    --set networkPolicy.monitoring.enabled=true --set-json 'networkPolicy.monitoring.namespaceSelector={"matchLabels":{"kubernetes.io/metadata.name":"monitoring"}}' \
    --show-only templates/networkpolicy/policies.yaml 2>&1 | python3 -c '
import sys, yaml
docs = {d["metadata"]["name"]: d for d in yaml.safe_load_all(sys.stdin) if d}
for role in ("wallet-service", "wallet-config"):
    rules = docs[f"t-netpol-ingress-{role}"]["spec"]["ingress"]
    scrape = [r for r in rules if [p["port"] for p in r.get("ports", [])] == ["metrics"]]
    peers = [p for r in scrape for p in r.get("from", [])]
    if not peers or any(p.get("namespaceSelector") != {"matchLabels": {"kubernetes.io/metadata.name": "monitoring"}} for p in peers):
        print(f"{role}: the port metrics is not open to the monitoring namespace only: {scrape}")
' 2>&1)" && [ -z "$problems" ]; then
  ok "scrape of the servers with network policies"
else
  bad "scrape of the servers with network policies: $(printf '%s' "$problems" | head -c 300)"
fi
renders "scrape of the workers and the clock with network policies" "port: health" "${shamir[@]}" -f "$examples/networkpolicy.yaml" \
  --set networkPolicy.monitoring.enabled=true --set-json 'networkPolicy.monitoring.namespaceSelector={"matchLabels":{"kubernetes.io/metadata.name":"monitoring"}}' \
  --show-only templates/networkpolicy/policies.yaml
lacks "no scrape of the workers and the clock without the monitoring namespace" "port: health" "${shamir[@]}" -f "$examples/networkpolicy.yaml" \
  --show-only templates/networkpolicy/policies.yaml
# DNS servers outside the pod network (networkPolicy.dns.cidrs): an ipBlock
# next to the DNS pods in the DNS policy; none by default.
dns_policy() {
  local name="$1" expect="$2"; shift 2
  local problems
  if problems="$(helm template t "$chart" --namespace ow -f "$keys" -f "$examples/site.yaml" "${shamir[@]}" -f "$examples/networkpolicy.yaml" \
      "$@" --show-only templates/networkpolicy/policies.yaml 2>&1 | python3 -c '
import json, sys, yaml
expect = json.loads(sys.argv[1])
for doc in yaml.safe_load_all(sys.stdin):
    if doc and doc["metadata"]["name"].endswith("netpol-dns"):
        peers = doc["spec"]["egress"][0]["to"]
        if peers[0].get("podSelector", {}).get("matchLabels") != {"k8s-app": "kube-dns"}:
            print("the DNS pods are not the first peer:", peers[0])
        blocks = [peer["ipBlock"]["cidr"] for peer in peers if "ipBlock" in peer]
        if blocks != expect:
            print("ipBlocks", blocks, "expected", expect)
        break
else:
    print("no DNS policy")
' "$expect" 2>&1)" && [ -z "$problems" ]; then
    ok "DNS policy: $name"
  else
    bad "DNS policy: $name: $(printf '%s' "$problems" | head -c 300)"
  fi
}
dns_policy "the DNS pods only by default" '[]'
dns_policy "the DNS pods and the DNS server outside the pod network" '["169.254.20.10/32"]' --set-json 'networkPolicy.dns.cidrs=["169.254.20.10/32"]'
# The egress profile platform (the public hosts of this platform): the pods
# of networkPolicy.ingressController are always a target; the wallet roles
# have it by default, the other roles do not.
platform_profile() {
  local name="$1" expect="$2"; shift 2
  local problems
  if problems="$(helm template t "$chart" --namespace ow -f "$keys" -f "$examples/site.yaml" "${shamir[@]}" -f "$examples/networkpolicy.yaml" \
      "$@" 2>&1 | python3 -c '
import json, sys, yaml
expect = json.loads(sys.argv[1])
policy, labelled = None, set()
for doc in yaml.safe_load_all(sys.stdin):
    if not doc:
        continue
    if doc.get("kind") == "NetworkPolicy" and doc["metadata"]["name"] == "t-netpol-egress-profile-platform":
        policy = doc
    template = (doc.get("spec") or {}).get("template") or {}
    labels = (template.get("metadata") or {}).get("labels") or {}
    if labels.get("netpol.igrant.io/egress-platform") == "true":
        labelled.add(labels["netpol.igrant.io/role"])
if policy is None:
    sys.exit("no platform policy")
rule = policy["spec"]["egress"][0]
if rule["to"] != expect["to"]:
    print("targets", rule["to"])
if [p["port"] for p in rule["ports"]] != expect["ports"]:
    print("ports", rule["ports"])
if sorted(labelled) != expect["roles"]:
    print("roles with the profile", sorted(labelled))
' "$expect" 2>&1)" && [ -z "$problems" ]; then
    ok "platform profile: $name"
  else
    bad "platform profile: $name: $(printf '%s' "$problems" | head -c 400)"
  fi
}
ingress_nginx='{"namespaceSelector": {"matchLabels": {"kubernetes.io/metadata.name": "ingress-nginx"}}, "podSelector": {}}'
platform_profile "the ingress controller on 80 and 443, the wallet roles" \
  "{\"to\": [$ingress_nginx], \"ports\": [80, 443], \"roles\": [\"wallet-config\", \"wallet-service\", \"wallet-worker\"]}"
platform_profile "a load balancer address, other ports, also the webhook handler" \
  "{\"to\": [{\"ipBlock\": {\"cidr\": \"192.0.2.80/32\"}}, $ingress_nginx], \"ports\": [8000, 8443], \"roles\": [\"wallet-config\", \"wallet-service\", \"wallet-worker\", \"webhook\"]}" \
  --set-json 'networkPolicy.egress.profiles.platform={"cidrs":["192.0.2.80/32"],"ports":[8000,8443]}' \
  --set-json 'networkPolicy.egress.roles.webhook=["internet-any-port","platform"]'
guard "no platform profile for the clock" 'the egress profile "platform" is not allowed for the network role "wallet-clock"' "${shamir[@]}" --set-json 'networkPolicy.egress.roles.wallet-clock=["platform"]'

# NATS 2.14 (pinned by digest); the render stops for 2.15 and later (the
# acks of the format v2 and the permissions of the format v1); the routes
# of a NATS cluster use mutual TLS (verify).
renders "NATS 2.14.10 by digest" "image: docker.io/library/nats@sha256:311da47e2f31c26e99c623cd78d486a1e8ab039c49b32652770bb91a4f70512e" "${shamir[@]}"
guard "NATS 2.15 (the acks of the format v2)" "NATS 2.15 and later send the JetStream acks on subjects of the format v2" "${shamir[@]}" --set nats.image.tag=2.15.3-alpine
guard "NATS 3" "NATS 2.15 and later send the JetStream acks" "${shamir[@]}" --set nats.image.tag=3.0.0
renders "NATS with an own tag without a version" "nats.conf" "${shamir[@]}" --set nats.image.tag=mirror --set nats.image.digest=
renders "the routes of NATS with mutual TLS" "verify: true" "${shamir[@]}" --set nats.replicas=3 --show-only templates/nats/configmap.yaml
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
# The interval of the writes of the issuer status lists
# (organisationWallet.statusList.writeIntervalSeconds): only in the files of
# the workers (each file is checked in each render).
renders "status list write interval of the workers" "write_interval_seconds: 10" "${shamir[@]}" --set organisationWallet.statusList.writeIntervalSeconds=10 --show-only templates/wallet/configmap.yaml
renders "status list write interval 0" "write_interval_seconds: 0" "${shamir[@]}" --set organisationWallet.statusList.writeIntervalSeconds=0 --show-only templates/wallet/configmap.yaml
guard "status list write interval" "organisationWallet.statusList.writeIntervalSeconds" "${shamir[@]}" --set organisationWallet.statusList.writeIntervalSeconds=51
# The nonce limit of the anonymous nonce routes (server.nonce_requests_per_minute).
renders "nonce limit of the server roles" "nonce_requests_per_minute: 300" "${shamir[@]}" --show-only templates/wallet/configmap.yaml
renders "nonce limit value" "nonce_requests_per_minute: 1200" "${shamir[@]}" --set organisationWallet.server.nonceRequestsPerMinute=1200 --show-only templates/wallet/configmap.yaml
guard "nonce limit" "organisationWallet.server.nonceRequestsPerMinute" "${shamir[@]}" --set organisationWallet.server.nonceRequestsPerMinute=0

# The pools of the wallet and of the readers of the api (database.pools).
guard "wallet pool size" "database.pools.walletService.poolSize" "${shamir[@]}" --set database.pools.walletService.poolSize=0
guard "worker pool overflow" "database.pools.walletWorker.maxOverflow" "${shamir[@]}" --set database.pools.walletWorker.maxOverflow=-1
guard "worker threads above the largest pool of the wallet" "organisationWallet.workers.groups.0.threads" "${shamir[@]}" --set-json "$(workers "${main_group/\"threads\":8/\"threads\":101}" "$maintenance_group")"
# The connection budget (docs/database.md, "Connection budget"): the pools
# of the release, with the most pods of each Deployment, and the hooks fit
# in max_connections of the bundled server less its reserved connections.
renders "connection budget at the limit of the bundled server" "max_connections=229" "${shamir[@]}" --set database.postgresql.parameters.max_connections=229
guard "connection budget one over the limit" "can open 221 connections to the bundled database server" "${shamir[@]}" --set database.postgresql.parameters.max_connections=228
guard "connection budget counts the reserved connections" "less the 13 reserved connections" "${shamir[@]}" \
  --set database.postgresql.parameters.max_connections=229 --set-string database.postgresql.parameters.reserved_connections=10
guard "connection budget counts the replicas" "wallet config 3 x 36" "${shamir[@]}" --set organisationWallet.config.replicas=3 \
  --set database.postgresql.parameters.max_connections=229
renders "no connection budget check with an external server" "kind: StatefulSet" "${shamir[@]}" -f "$examples/postgresql-external.yaml" --set api.replicas=20
# The connection pooler (database.pooler): the wallet files of the
# processes with sessions name it, and the budget counts its server
# connections in place of the session pools of the wallet.
pooler=(--set database.pooler.host=pgbouncer.ow.svc --set database.pooler.serverConnections=40)
renders "pooler in the wallet files" "host: pgbouncer.ow.svc" "${shamir[@]}" "${pooler[@]}" --show-only templates/wallet/configmap.yaml
lacks "no pooler without its host" "pooler" "${shamir[@]}" --show-only templates/wallet/configmap.yaml
if problems="$(helm template t "$chart" --namespace ow -f "$keys" -f "$examples/site.yaml" "${shamir[@]}" "${pooler[@]}" \
    --show-only templates/wallet/configmap.yaml 2>&1 | python3 -c '
import sys, yaml
data = yaml.safe_load(sys.stdin)["data"]
for key, text in sorted(data.items()):
    pooler = yaml.safe_load(text)["database"].get("pooler")
    want = None if key == "clock.yaml" else {"host": "pgbouncer.ow.svc", "port": 6432}
    if pooler != want:
        print(f"{key}: database.pooler is {pooler!r}, not {want!r}")
' 2>&1)" && [ -z "$problems" ]; then
  ok "pooler: every wallet file with sessions has it, the clock file not"
else
  bad "pooler: $(printf '%s' "$problems" | tr '\n' ';' | head -c 300)"
fi
guard "pooler without its server connections" "database.pooler.serverConnections is required" "${shamir[@]}" --set database.pooler.host=pgbouncer.ow.svc
guard "pooler port" "database.pooler.port" "${shamir[@]}" "${pooler[@]}" --set database.pooler.port=0
guard "connection budget with a pooler counts its server connections" "connection pooler 1 x 40" "${shamir[@]}" "${pooler[@]}" --set database.postgresql.parameters.max_connections=100
renders "the session pool of a worker process follows its threads" "pool_size: 16" "${shamir[@]}" --set database.postgresql.parameters.max_connections=600 --set-json "$(workers "${main_group/\"threads\":8/\"threads\":16}" "$maintenance_group")" \
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

# The metrics of the bundled Valkey (redis.metrics): the exporter in each
# pod with the ACL user metrics, its password, the ServiceMonitor, and the
# scrape port open only to the monitoring namespace.
metrics=(--set redis.metrics.enabled=true)
redis_sts "with the exporter" "--redis.user=metrics" "${metrics[@]}"
redis_sts "the exporter reads no CONFIG" "--config-command=-" "${metrics[@]}"
redis_sts "the exporter gets only the CA" "mountPath: /etc/valkey-metrics" "${metrics[@]}"
renders "the ACL user metrics" "user metrics on {hash:metrics} -@all +info +client|setname +slowlog|len +latency|latest +latency|histogram" "${shamir[@]}" "${metrics[@]}"
renders "the password of the user metrics" "  metrics: " "${shamir[@]}" "${metrics[@]}" --show-only templates/secrets.yaml
lacks "no exporter by default" "redis_exporter" "${shamir[@]}"
lacks "no ACL user metrics by default" "user metrics on" "${shamir[@]}"
lacks "no password of the user metrics by default" "  metrics: " "${shamir[@]}" --show-only templates/secrets.yaml
renders "ServiceMonitor of Valkey" "name: t-redis-metrics" "${shamir[@]}" "${metrics[@]}" --set redis.metrics.serviceMonitor.enabled=true
lacks "no ServiceMonitor of Valkey without its value" "t-redis-metrics" "${shamir[@]}" "${metrics[@]}"
renders "scrape of Valkey with network policies" "port: metrics" "${shamir[@]}" -f "$examples/networkpolicy.yaml" \
  --set networkPolicy.monitoring.enabled=true --set-json 'networkPolicy.monitoring.namespaceSelector={"matchLabels":{"kubernetes.io/metadata.name":"monitoring"}}' \
  --show-only templates/networkpolicy/policies.yaml
guard "redis ServiceMonitor without the exporter" "redis.metrics.serviceMonitor.enabled needs redis.metrics.enabled" "${shamir[@]}" --set redis.metrics.serviceMonitor.enabled=true
guard "redis metrics with an external Valkey" "redis.metrics is for the bundled Valkey" "${external_redis[@]}" "${metrics[@]}"
guard "redis user name metrics" 'redis.users.gateway.username "metrics" is a user of the bundled Valkey' "${shamir[@]}" --set redis.users.gateway.username=metrics

# Separate groups of the wallet (redis.state, redis.cache): the guards; one
# endpoint for each group in each wallet file, the CA of a group in the
# wallet pods (not in the gateway), and the egress to
# networkPolicy.externalRedis only for the wallet roles (also with the
# bundled Valkey).
guard "redis state without sentinels or address" "redis.state.sentinels or redis.state.address is required with redis.state.enabled" "${shamir[@]}" --set redis.state.enabled=true
guard "redis cache with sentinels and address" "set redis.cache.sentinels or redis.cache.address, not both" "${shamir[@]}" --set redis.cache.enabled=true \
  --set-json 'redis.cache.sentinels=["cache.example.org:26379"]' --set redis.cache.masterName=cache --set redis.cache.address=cache.example.org:6379
guard "redis state Sentinels without a master name" 'redis.state.masterName "" is not a name' "${shamir[@]}" --set redis.state.enabled=true \
  --set-json 'redis.state.sentinels=["state.example.org:26379"]'
guard "redis state address without port" "redis.state.address" "${shamir[@]}" --set redis.state.enabled=true --set redis.state.address=state.example.org
guard "redis state address without port without the schema" '"state.example.org" is not host:port' "${shamir[@]}" --skip-schema-validation \
  --set redis.state.enabled=true --set redis.state.address=state.example.org
guard "redis state with network policies without addresses" "networkPolicy.externalRedis needs the addresses of the group redis.state" "${shamir[@]}" \
  -f "$examples/networkpolicy.yaml" --set redis.state.enabled=true --set redis.state.address=state.example.org:6379
groups=(--set redis.state.enabled=true --set-json 'redis.state.sentinels=["state-1.example.org:26379","state-2.example.org:26379"]'
  --set redis.state.masterName=state --set redis.state.caSecret=state-ca
  --set redis.cache.enabled=true --set redis.cache.address=cache.example.org:6380 --set redis.cache.sentinelAuth=false)
if ! helm template t "$chart" --namespace ow -f "$keys" -f "$examples/site.yaml" "${shamir[@]}" -f "$examples/networkpolicy.yaml" \
    --set-json 'networkPolicy.externalRedis=[{"cidrs":["198.51.100.0/24"]}]' "${groups[@]}" > "$out/redis-groups.yaml" 2> "$out/redis-groups.err"; then
  bad "Valkey groups: $(head -c 200 "$out/redis-groups.err")"
elif problems="$(python3 - "$out/redis-groups.yaml" <<'PY' 2>&1
import sys, yaml
docs = [d for d in yaml.safe_load_all(open(sys.argv[1])) if d]
def find(kind, name):
    return next((d for d in docs if d["kind"] == kind and d["metadata"]["name"] == name), None)
sentinels = [f"t-redis-{i}.t-redis-headless.ow.svc:26379" for i in range(3)]
files = 0
for key, text in find("ConfigMap", "t-wallet")["data"].items():
    redis = yaml.safe_load(text).get("redis")
    if redis is None:
        continue
    files += 1
    queue, state, cache = redis.get("queue", {}), redis.get("state", {}), redis.get("cache", {})
    user = queue.get("username")
    if queue.get("sentinels") != sentinels or queue.get("ca_file") != "/run/secrets/eudi-wallet/redis-ca.crt":
        print(f"{key}: the queue is not the bundled Valkey: {queue}")
    if (state.get("sentinels") != ["state-1.example.org:26379", "state-2.example.org:26379"] or state.get("master_name") != "state"
            or state.get("username") != user or state.get("sentinel_username") != user
            or state.get("password_file") != "/run/secrets/eudi-wallet/redis-password"
            or state.get("ca_file") != "/run/secrets/eudi-wallet/redis-state-ca.crt"):
        print(f"{key}: the state endpoint is wrong: {state}")
    if (cache.get("address") != "cache.example.org:6380" or cache.get("username") != user or "sentinel_username" in cache
            or "ca_file" in cache or "sentinels" in cache):
        print(f"{key}: the cache endpoint is wrong: {cache}")
if files < 5:
    print(f"only {files} wallet files have a redis section")
def items(doc):
    spec = doc["spec"]["template"]["spec"]
    return [(source["secret"]["name"], item["key"], item["path"]) for volume in spec.get("volumes", []) if "projected" in volume
            for source in volume["projected"]["sources"] if "secret" in source for item in source["secret"].get("items", [])]
wallet = [d for d in docs if d["kind"] == "Deployment" and d["metadata"]["name"].startswith("t-wallet-") and d["metadata"]["name"] != "t-wallet-signer-manager"]
if len(wallet) < 5:
    print(f"only {len(wallet)} wallet Deployments")
for doc in wallet:
    if ("state-ca", "ca.crt", "redis-state-ca.crt") not in items(doc):
        print(f"{doc['metadata']['name']} does not mount the CA of the state group")
if any(path == "redis-state-ca.crt" for _, _, path in items(find("Deployment", "t-gateway"))):
    print("the gateway mounts the CA of the state group")
def egress_cidrs(role):
    doc = find("NetworkPolicy", f"t-netpol-egress-{role}")
    return {peer["ipBlock"]["cidr"] for rule in (doc or {}).get("spec", {}).get("egress", []) for peer in rule.get("to", []) if "ipBlock" in peer}
for role in ("wallet-service", "wallet-config", "wallet-worker", "wallet-clock"):
    if "198.51.100.0/24" not in egress_cidrs(role):
        print(f"the role {role} does not reach the separate groups")
for role in ("gateway", "redis"):
    if "198.51.100.0/24" in egress_cidrs(role):
        print(f"the role {role} reaches the separate groups of the wallet")
PY
)" && [ -z "$problems" ]; then
  ok "Valkey groups: the state and cache endpoints, their CA, the egress of the wallet roles"
else
  bad "Valkey groups"
  printf '%s\n' "$problems" | sed 's/^/  /' | head -10
fi
lacks "no state or cache endpoint by default" "redis-state-ca.crt" "${shamir[@]}"
# /tmp of the api: an upload of 100 MiB with a /tmp of 100Mi (and the
# memory limits for it); a body of 32 MiB stays in memory, so a small /tmp
# is enough for it.
renders "api /tmp for uploads of 100 MiB" "sizeLimit: 100Mi" "${shamir[@]}" --set gateway.proxy.maxBodyBytes.file=104857600 \
  --set api.tmp.sizeLimit=100Mi --show-only templates/api/deploy.yaml
renders "api /tmp: a body of 32 MiB stays in memory" "sizeLimit: 1Mi" "${shamir[@]}" --set gateway.proxy.maxBodyBytes.file=33554432 \
  --set api.tmp.sizeLimit=1Mi --show-only templates/api/deploy.yaml
worker_group='{"name":"all","queues":["realtime","attestation","status","kms","maintenance"],"replicas":1,"processes":1,"threads":2,"shutdownTimeoutSeconds":14400,"terminationGracePeriodSeconds":14430'
guard "removed /tmp of a worker group" "Additional property tmp is not allowed" "${shamir[@]}" --set-json "organisationWallet.workers.groups=[${worker_group},\"tmp\":{\"sizeLimit\":\"300Gi\"}}]"
# The writable paths of the pods that run as a non-root user with a
# read-only root file system: /tmp of each api, webhook, dashboard and wallet
# pod (in memory, 64Mi; the worker /tmp too), the socket folder of the
# bundled server.
if ! helm template t "$chart" --namespace ow -f "$keys" -f "$examples/site.yaml" "${shamir[@]}" > "$out/writable.yaml" 2> "$out/writable.err"; then
  bad "writable paths: $(head -c 200 "$out/writable.err")"
elif problems="$(python3 - "$out/writable.yaml" <<'PY' 2>&1
import sys, yaml
docs = [d for d in yaml.safe_load_all(open(sys.argv[1])) if d]
expected = {
    ("Deployment", "t-api"): {"/tmp": {"medium": "Memory", "sizeLimit": "64Mi"}},
    ("Deployment", "t-webhook"): {"/tmp": {"medium": "Memory", "sizeLimit": "64Mi"}},
    ("Deployment", "t-dashboard"): {"/tmp": {"sizeLimit": "64Mi"}},
    ("Deployment", "t-wallet-service"): {"/tmp": {"medium": "Memory", "sizeLimit": "64Mi"}, "/run/ows-server": {"medium": "Memory", "sizeLimit": "64Mi"}},
    ("Deployment", "t-wallet-config"): {"/tmp": {"medium": "Memory", "sizeLimit": "64Mi"}, "/run/ows-server": {"medium": "Memory", "sizeLimit": "64Mi"}},
    ("Deployment", "t-wallet-worker-main"): {"/tmp": {"medium": "Memory", "sizeLimit": "64Mi"}, "/run/ows-worker": {"medium": "Memory", "sizeLimit": "64Mi"}},
    ("Deployment", "t-wallet-worker-maintenance"): {"/tmp": {"medium": "Memory", "sizeLimit": "64Mi"}, "/run/ows-worker": {"medium": "Memory", "sizeLimit": "64Mi"}},
    ("Deployment", "t-wallet-clock"): {"/tmp": {"medium": "Memory", "sizeLimit": "64Mi"}},
    ("StatefulSet", "t-postgres"): {"/tmp": {"sizeLimit": "64Mi"}, "/var/run/postgresql": {"medium": "Memory", "sizeLimit": "1Mi"}},
    ("StatefulSet", "t-nats"): {"/var/run/nats": {"medium": "Memory", "sizeLimit": "1Mi"}},
}
for (kind, name), paths in expected.items():
    doc = next((d for d in docs if d["kind"] == kind and d["metadata"]["name"] == name), None)
    if doc is None:
        print(f"{kind} {name} is missing")
        continue
    spec = doc["spec"]["template"]["spec"]
    volumes = {v["name"]: v for v in spec["volumes"]}
    for container in spec.get("initContainers", []) + spec["containers"]:
        mounts = {m["mountPath"]: m["name"] for m in container.get("volumeMounts", [])}
        if name == "t-nats" and container["name"] == "store-check":
            # The check of the store writes nothing: each mount is read-only.
            writable = [m["mountPath"] for m in container.get("volumeMounts", []) if m.get("readOnly") is not True]
            if writable or sorted(mounts) != ["/data", "/etc/nats-config"]:
                print(f"{name}:store-check: mounts {sorted(mounts)}, writable {writable}")
            continue
        for path, empty_dir in paths.items():
            if name == "t-nats" and container["name"] == "reloader" and path != "/var/run/nats":
                continue
            volume = volumes.get(mounts.get(path), {})
            if volume.get("emptyDir") != empty_dir:
                print(f"{name}:{container['name']}: {path} is {volume or 'not mounted'}, not the emptyDir {empty_dir}")
PY
)" && [ -z "$problems" ]; then
  ok "writable paths: the emptyDir volumes of the pods with a read-only root file system"
else
  bad "writable paths"
  printf '%s\n' "$problems" | sed 's/^/  /' | head -10
fi

# The JetStream store of the bundled NATS: the user 65532, the init
# container store-check (the script files/nats/store-check.sh in the
# ConfigMap, the mounts read-only, before nats-server), and the
# fsGroupChangePolicy of the rollout. A copy of the chart reads the NATS
# StatefulSet "in the cluster" from the file live-nats.json in place of
# lookup (ow.nats.liveStatefulSet): Always when it runs NATS as root (the
# earlier release, or a rollback to it) or when its rollout is not
# complete; else the value (OnRootMismatch). The notes of the copy (a
# ConfigMap, as in section 3) tell the operator.
if ! helm template t "$chart" --namespace ow -f "$keys" -f "$examples/site.yaml" "${shamir[@]}" \
    --show-only templates/nats/statefulset.yaml --show-only templates/nats/configmap.yaml > "$out/nats-store.yaml" 2> "$out/nats-store.err"; then
  bad "NATS store: $(head -c 200 "$out/nats-store.err")"
elif problems="$(python3 - "$out/nats-store.yaml" "$chart/files/nats/store-check.sh" <<'PY'
import sys, yaml
docs = {d["kind"]: d for d in yaml.safe_load_all(open(sys.argv[1])) if d}
script = open(sys.argv[2]).read()
spec = docs["StatefulSet"]["spec"]["template"]["spec"]
context = spec["securityContext"]
for key, value in (("runAsUser", 65532), ("runAsGroup", 65532), ("fsGroup", 65532), ("fsGroupChangePolicy", "OnRootMismatch")):
    if context.get(key) != value:
        print(f"the pod {key} is {context.get(key)!r}, not {value!r}")
inits = spec.get("initContainers") or []
if [c["name"] for c in inits] != ["store-check"]:
    print(f"the init containers are {[c['name'] for c in inits]}, not [store-check]")
else:
    check = inits[0]
    if check["command"] != ["/bin/sh", "/etc/nats-config/store-check.sh", "/data"]:
        print(f"store-check runs {check['command']}")
    if check["image"] != spec["containers"][0]["image"]:
        print("store-check has not the image of nats")
    mounts = {m["mountPath"]: m for m in check["volumeMounts"]}
    if mounts.get("/data", {}).get("name") != "data" or mounts.get("/etc/nats-config", {}).get("name") != "config":
        print(f"store-check mounts {sorted(mounts)}")
    if any(m.get("readOnly") is not True for m in mounts.values()):
        print("a mount of store-check is not read-only")
if docs["ConfigMap"]["data"].get("store-check.sh", "").strip() != script.strip():
    print("the ConfigMap has not files/nats/store-check.sh")
if not docs["StatefulSet"]["spec"]["template"]["metadata"]["annotations"].get("checksum/store-check"):
    print("no checksum of the store check")
PY
)" && [ -z "$problems" ]; then
  ok "NATS store: the user 65532, OnRootMismatch, the init container store-check with the script of the chart, read-only"
else
  bad "NATS store: $(printf '%s' "$problems" | tr '\n' ';' | head -c 300)"
fi
nats_chart="$out/nats-lookup-chart"
rm -rf "$nats_chart"
mkdir -p "$nats_chart"
cp -R "$chart/Chart.yaml" "$chart/values.yaml" "$chart/values.schema.json" "$chart/templates" "$chart/files" "$chart/policies" "$nats_chart/"
nats_lookup_line='{{- $live := lookup "apps/v1" "StatefulSet" $root.Release.Namespace (include "ow.name" (list $root "nats")) -}}'
nats_stub_line='{{- $live := $root.Files.Get "live-nats.json" | fromJson -}}'
{ printf '{{- define "test.notes" -}}\n'; cat "$chart/templates/NOTES.txt"; printf '\n{{- end }}\n'; } > "$nats_chart/templates/_test_notes.tpl"
rm "$nats_chart/templates/NOTES.txt"
printf 'apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: notes\ndata:\n  notes: |\n{{ include "test.notes" . | indent 4 }}\n' > "$nats_chart/templates/zz-test-notes.yaml"
printf '{}' > "$nats_chart/live-nats.json"
if [ "$(grep -c -F -- "$nats_lookup_line" "$nats_chart/templates/nats/_nats.tpl")" != 1 ]; then
  bad "NATS store repair: ow.nats.liveStatefulSet has not the lookup line of the test"
else
  NATS_LOOKUP_LINE="$nats_lookup_line" NATS_STUB_LINE="$nats_stub_line" perl -pi -e 's/\Q$ENV{NATS_LOOKUP_LINE}\E/$ENV{NATS_STUB_LINE}/' "$nats_chart/templates/nats/_nats.tpl"
  # live <case> <expected fsGroupChangePolicy> <text of the notes, or -> <JSON of the StatefulSet in the cluster> [helm args]
  # -: the notes have no repair text.
  live() {
    local name="$1" policy="$2" note="$3" json="$4"; shift 4
    local rendered got
    printf '%s' "$json" > "$nats_chart/live-nats.json"
    if ! rendered="$(helm template t "$nats_chart" --namespace ow -f "$keys" -f "$examples/site.yaml" "${shamir[@]}" "$@" \
        --show-only templates/nats/statefulset.yaml --show-only templates/zz-test-notes.yaml 2>&1)"; then
      bad "NATS store repair, $name: $(printf '%s' "$rendered" | head -c 200)"
      return
    fi
    printf '%s\n' "$rendered" > "$out/nats-live.yaml"
    got="$(python3 -c '
import sys, yaml
for doc in yaml.safe_load_all(open(sys.argv[1])):
    if doc and doc["kind"] == "StatefulSet":
        print(doc["spec"]["template"]["spec"]["securityContext"].get("fsGroupChangePolicy"))
' "$out/nats-live.yaml")"
    rm -f "$out/nats-live.yaml"
    if [ "$got" != "$policy" ]; then
      bad "NATS store repair, $name: fsGroupChangePolicy $got, not $policy"
    elif [ "$note" != - ] && ! grep -q -F -- "$note" <<< "$rendered"; then
      bad "NATS store repair, $name: the notes have not \"$note\""
    elif [ "$note" = - ] && grep -q -F -- "This rollout gives the group" <<< "$rendered"; then
      bad "NATS store repair, $name: the notes have the repair text"
    else
      ok "NATS store repair, $name: $policy"
    fi
  }
  status_done='"status":{"observedGeneration":4,"currentRevision":"t-nats-1","updateRevision":"t-nats-1","replicas":3,"updatedReplicas":3}'
  hardened='"template":{"spec":{"securityContext":{"runAsUser":65532,"fsGroup":65532},"containers":[{"name":"nats"},{"name":"reloader"}]}}'
  repair_note="This rollout gives the group and the group rights to each file of the JetStream store again (fsGroupChangePolicy Always)"
  live "install (no StatefulSet)" OnRootMismatch - '{}'
  live "upgrade from the earlier release (NATS as root)" Always "$repair_note" \
    "{\"metadata\":{\"generation\":4},\"spec\":{\"replicas\":3,\"template\":{\"spec\":{\"containers\":[{\"name\":\"nats\"}]}}},$status_done}"
  live "roll forward after a rollback (container user 0)" Always "$repair_note" \
    "{\"metadata\":{\"generation\":4},\"spec\":{\"replicas\":3,\"template\":{\"spec\":{\"securityContext\":{\"runAsUser\":65532},\"containers\":[{\"name\":\"nats\",\"securityContext\":{\"runAsUser\":0}}]}}},$status_done}"
  live "upgrade of the release with non-root NATS" OnRootMismatch - \
    "{\"metadata\":{\"generation\":4},\"spec\":{\"replicas\":3,$hardened},$status_done}"
  live "rollout not complete" Always "$repair_note" \
    "{\"metadata\":{\"generation\":4},\"spec\":{\"replicas\":3,$hardened},\"status\":{\"observedGeneration\":4,\"currentRevision\":\"t-nats-1\",\"updateRevision\":\"t-nats-2\",\"replicas\":3,\"updatedReplicas\":1}}"
  live "rollout not seen by the controller" Always "$repair_note" \
    "{\"metadata\":{\"generation\":5},\"spec\":{\"replicas\":3,$hardened},$status_done}"
  live "Always of the values" Always "WARNING: nats.podSecurityContext.fsGroupChangePolicy is Always" \
    "{\"metadata\":{\"generation\":4},\"spec\":{\"replicas\":3,$hardened},$status_done}" --set nats.podSecurityContext.fsGroupChangePolicy=Always
  printf '{}' > "$nats_chart/live-nats.json"
fi

# global.podSecurityContext and global.containerSecurityContext: each pod
# and each container gets the keys that the component does not set (here
# the SELinux options and the supplemental groups of a cluster); a key of
# the component stays (runAsUser). The notes name each component whose own
# value sets a global key (values.yaml: the jobs without their own value
# use the value of the component).
global_security=(--set-json 'global.podSecurityContext={"seLinuxOptions":{"level":"s0:c123,c456"},"supplementalGroups":[4321],"runAsUser":4242}'
  --set-json 'global.containerSecurityContext={"seLinuxOptions":{"type":"container_t"}}')
if ! helm template t "$chart" --namespace ow -f "$keys" -f "$examples/site.yaml" "${shamir[@]}" -f "$here/values/operator-jobs-bootstrap.yaml" \
    --set redis.metrics.enabled=true "${global_security[@]}" > "$out/global-security.yaml" 2> "$out/global-security.err"; then
  bad "global security contexts: $(head -c 200 "$out/global-security.err")"
elif problems="$(python3 - "$out/global-security.yaml" <<'PY'
import sys, yaml
pods = 0
for doc in yaml.safe_load_all(open(sys.argv[1])):
    if not doc or doc.get("kind") not in ("Deployment", "StatefulSet", "Job"):
        continue
    pods += 1
    spec = doc["spec"]["template"]["spec"]
    name = f"{doc['kind']}/{doc['metadata']['name']}"
    context = spec.get("securityContext") or {}
    if context.get("seLinuxOptions") != {"level": "s0:c123,c456"} or context.get("supplementalGroups") != [4321]:
        print(f"{name}: the pod has not the global keys: {context}")
    if context.get("runAsUser") in (None, 4242):
        print(f"{name}: runAsUser {context.get('runAsUser')} (the value of the component must stay)")
    for container in spec.get("initContainers", []) + spec["containers"]:
        container_context = container.get("securityContext") or {}
        if container_context.get("seLinuxOptions") != {"type": "container_t"}:
            print(f"{name}:{container['name']}: the container has not global.containerSecurityContext")
        if container_context.get("readOnlyRootFilesystem") is not True:
            print(f"{name}:{container['name']}: the container lost readOnlyRootFilesystem")
if pods < 25:
    print(f"only {pods} pod templates")
PY
)" && [ -z "$problems" ]; then
  ok "global security contexts: under the values of each component, in each pod and container"
else
  bad "global security contexts: $(printf '%s' "$problems" | tr '\n' ';' | head -c 300)"
fi
expected="$(python3 - "$chart/values.yaml" <<'PY'
import sys, yaml
values = yaml.safe_load(open(sys.argv[1]))
paths = []
for key, component in values.items():
    if key == "global" or not isinstance(component, dict) or "podSecurityContext" not in component:
        continue
    if "runAsUser" in (component["podSecurityContext"] or {}):
        paths.append(key)
    # A part of the component with its own pods (the jobs: an empty value is
    # the value of the component; the HSM signer manager).
    for name, part in component.items():
        if isinstance(part, dict) and "podSecurityContext" in part:
            context = part["podSecurityContext"] or (component["podSecurityContext"] if name == "jobs" else {})
            if "runAsUser" in (context or {}):
                paths.append(f"{key}.{name}")
print(f"global.podSecurityContext.runAsUser does not apply to {', '.join(sorted(paths))}: the podSecurityContext of each sets runAsUser")
PY
)"
if ! text="$(helm template t "$nats_chart" --namespace ow -f "$keys" -f "$examples/site.yaml" "${shamir[@]}" "${global_security[@]}" \
    --show-only templates/zz-test-notes.yaml 2>&1)"; then
  bad "global security contexts: notes: $(printf '%s' "$text" | head -c 200)"
elif grep -q -F -- "$expected" <<< "$text" && ! grep -q -F "global.podSecurityContext.supplementalGroups" <<< "$text" \
    && ! grep -q -F "global.podSecurityContext.seLinuxOptions" <<< "$text"; then
  ok "global security contexts: the notes name each component that sets a global key"
else
  bad "global security contexts: the notes have not \"$expected\" (or they name a key that applies)"
fi

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
# An upgrade that turns a service off: the earlier release has all
# components on; the new release has the values of each case.
upgrade_removes() {
  local name="$1" database="$2"; shift 2
  local args=(-f "$keys" -f "$examples/site.yaml" -f "$examples/$database.yaml" -f "$examples/openbao-shamir.yaml"
    -f "$examples/exposure-ingress-nginx.yaml")
  local case="$out/upgrade-$database-${name// /-}"
  if ! helm template t "$chart" --namespace ow "${args[@]}" > "$case-before.yaml" 2> "$case.err" \
      || ! helm template t "$chart" --namespace ow "${args[@]}" "$@" > "$case-after.yaml" 2> "$case.err"; then
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
  # A service added later (the earlier release does not install it), and a
  # service removed (the new release does not install it).
  upgrade_order "that installs consent" "$database" "${no_consent[@]}"
  upgrade_order "that installs the wallet" "$database" "${no_wallet[@]}"
  upgrade_removes "that removes consent" "$database" "${no_consent[@]}"
  upgrade_removes "that removes the wallet" "$database" "${no_wallet[@]}"
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

# --- 7. The security settings of the containers -------------------------------
# Each container of each render of this test (the matrix, the other cases
# above, and one render with the optional containers: the metrics exporter
# of Valkey and the operator Jobs of the api):
# - tests/check_security.py: a non-root user with a UID and a GID other than
#   0, no privilege escalation, a read-only root file system, all
#   capabilities dropped and none added, not privileged, seccomp
#   RuntimeDefault, no host namespace, and the SELinux, AppArmor, procMount
#   and hostProcess rules of the Pod Security Standard;
# - tests/psscheck: the Pod Security Standard "restricted" (latest, and
#   v1.30, the lowest Kubernetes version of the chart) with the upstream
#   library k8s.io/pod-security-admission, the code of the admission plugin.
#   It must read the same count of containers as check_security.py. It
#   needs Go (the version of tests/psscheck/go.mod) and the modules of
#   go.sum.
# Both checks must refuse a mutant of the values (tests/values/pss-mutant.yaml:
# AppArmor Unconfined, SELinux spc_t, procMount Unmasked, hostProcess), and
# each bad pod of tests/fixtures/pss-pods.yaml (also an ephemeral container
# and an AppArmor annotation, which the chart does not render).
if ! helm template t "$chart" --namespace ow -f "$keys" -f "$examples/site.yaml" "${shamir[@]}" \
    -f "$here/values/operator-jobs-bootstrap.yaml" --set redis.metrics.enabled=true > "$out/security-options.yaml" 2> "$out/security-options.err"; then
  bad "security settings: helm template with the optional containers"
  sed 's/^/  /' "$out/security-options.err" | head -10
fi
renders_of_test=()
while IFS= read -r -d '' file; do renders_of_test+=("$file"); done < <(find "$out" -maxdepth 1 -type f -name '*.yaml' -print0 | sort -z)
containers_of_test=""
if result="$(python3 "$here/check_security.py" "${renders_of_test[@]}" 2>&1)"; then
  ok "security settings of the containers: $(printf '%s' "$result" | tail -n 1)"
  containers_of_test="$(printf '%s' "$result" | tail -n 1 | sed -n 's/^[0-9]* renders, \([0-9]*\) containers, 0 problems$/\1/p')"
else
  bad "security settings of the containers: $(printf '%s' "$result" | tail -n 1)"
  printf '%s\n' "$result" | head -20
fi
mkdir -p "$out/tools" "$out/mutants"
psscheck="$(cd "$out/tools" && pwd)/psscheck"
if ! command -v go > /dev/null; then
  bad "Pod Security Standard (upstream): Go is not installed; tests/psscheck needs the Go of tests/psscheck/go.mod"
elif ! build="$(cd "$here/psscheck" && GOFLAGS=-mod=readonly go build -o "$psscheck" . 2>&1)"; then
  bad "Pod Security Standard (upstream): go build of tests/psscheck: $(printf '%s' "$build" | head -c 300)"
else
  if [ -z "$containers_of_test" ]; then
    bad "Pod Security Standard (upstream): no count of the containers from check_security.py"
  else
    for version in latest v1.30; do
      if result="$("$psscheck" -level restricted -version "$version" -containers "$containers_of_test" "${renders_of_test[@]}" 2>&1)"; then
        ok "Pod Security Standard (upstream) $(printf '%s' "$result" | tail -n 1)"
      else
        bad "Pod Security Standard (upstream) $(printf '%s' "$result" | tail -n 1)"
        printf '%s\n' "$result" | head -20
      fi
    done
  fi
  # The mutant of the values: both checks refuse it, each for the four
  # fields.
  if ! helm template t "$chart" --namespace ow -f "$keys" -f "$examples/site.yaml" "${shamir[@]}" -f "$here/values/pss-mutant.yaml" \
      > "$out/mutants/pss-mutant.yaml" 2> "$out/mutants/pss-mutant.err"; then
    bad "security checks refuse the mutant: helm template: $(head -c 200 "$out/mutants/pss-mutant.err")"
  else
    python_result="$(python3 "$here/check_security.py" "$out/mutants/pss-mutant.yaml" 2>&1)" && python_status=0 || python_status=$?
    upstream_result="$("$psscheck" -level restricted -version latest "$out/mutants/pss-mutant.yaml" 2>&1)" && upstream_status=0 || upstream_status=$?
    missing=""
    for text in "appArmorProfile.type is 'Unconfined'" "seLinuxOptions.type is 'spc_t'" "procMount is 'Unmasked'" "windowsOptions.hostProcess true"; do
      grep -q -F -- "$text" <<< "$python_result" || missing="$missing check_security.py: $text;"
    done
    for text in "forbidden AppArmor profile" "set forbidden securityContext.seLinuxOptions" "must not set securityContext.procMount" "must not set securityContext.windowsOptions.hostProcess=true"; do
      grep -q -F -- "$text" <<< "$upstream_result" || missing="$missing psscheck: $text;"
    done
    if [ "$python_status" = 1 ] && [ "$upstream_status" = 1 ] && [ -z "$missing" ]; then
      ok "security checks refuse the mutant (AppArmor, SELinux, procMount, hostProcess): both"
    else
      bad "security checks refuse the mutant: exit $python_status and $upstream_status;$missing"
    fi
  fi
  # The pods of the fixture: each bad pod is named by both checks, the good
  # pod by none.
  python_result="$(python3 "$here/check_security.py" "$here/fixtures/pss-pods.yaml" 2>&1)" || true
  upstream_result="$("$psscheck" -level restricted -version latest "$here/fixtures/pss-pods.yaml" 2>&1)" || true
  problems=""
  for pod in bad-apparmor-field bad-apparmor-annotation bad-selinux bad-procmount bad-hostprocess bad-ephemeral; do
    grep -q -F -- "Pod/$pod" <<< "$python_result" || problems="$problems check_security.py misses $pod;"
    grep -q -F -- "Pod/$pod" <<< "$upstream_result" || problems="$problems psscheck misses $pod;"
  done
  grep -q -F -- "Pod/good" <<< "$python_result$upstream_result" && problems="$problems a check refuses the good pod;"
  if [ -z "$problems" ]; then
    ok "security checks: each bad pod of tests/fixtures/pss-pods.yaml (also an ephemeral container and an AppArmor annotation), not the good pod"
  else
    bad "security checks of tests/fixtures/pss-pods.yaml:$problems"
  fi
fi

# The probes, the hooks, the rollout and the stop (tests/check_lifecycle.py)
# of each render: no exec probe or hook in an image without a shell, no
# exec of /bin/sleep, no initialDelaySeconds with a startup probe; each HTTP
# Deployment rolls with maxUnavailable 0, minReadySeconds and a preStop
# sleep, and its grace period covers the sleep and the stop of its server.
# The check must refuse each bad pod of tests/fixtures/lifecycle-pods.yaml.
if result="$(python3 "$here/check_lifecycle.py" "${renders_of_test[@]}" 2>&1)"; then
  ok "probes, hooks, rollout and stop: $(printf '%s' "$result" | tail -n 1)"
else
  bad "probes, hooks, rollout and stop: $(printf '%s' "$result" | tail -n 1)"
  printf '%s\n' "$result" | head -20
fi
result="$(python3 "$here/check_lifecycle.py" "$here/fixtures/lifecycle-pods.yaml" 2>&1)" || true
problems=""
for pod in bad-sleep-exec bad-shell-probe bad-initial-delay; do
  grep -q -F -- "Pod/$pod" <<< "$result" || problems="$problems misses $pod;"
done
grep -q -F -- "Pod/good" <<< "$result" && problems="$problems refuses the good pod;"
if [ -z "$problems" ]; then
  ok "probes, hooks, rollout and stop: the check refuses each bad pod of tests/fixtures/lifecycle-pods.yaml"
else
  bad "probes, hooks, rollout and stop: the check$problems"
fi

echo "result: ${pass} passed, ${fail} failed"
[ "$fail" -eq 0 ]
