#!/usr/bin/env bash
# Tests of the chart. They need no cluster and no container, only local
# tools.
#
# 1. Text: no em dash or en dash in any text file of the repository (also
#    docker-compose/, scripts/, images/ and .github/; the licence texts of
#    other projects are exempt). The chart files and the docs (README.md,
#    docs/) use British English and name no earlier key store product (only
#    the wallet config section "vault" of OpenBao, the key store types
#    "vault" (an external OpenBao), "external-vault" and "azure-key-vault",
#    and the product name Azure Key Vault), no database KMS, no backup
#    settings, no Keycloak, no Aries or SSI, no API key rotator. The relative
#    links of README.md and docs/ resolve (tests/check_links.py). Each
#    values.yaml image is in docs/images.md, each third-party image
#    (registry docker.io) is in THIRD-PARTY-NOTICES.md, and the Valkey and
#    redis_exporter licence texts are in licenses/.
# 2. The matrix of the profiles (profiles/): every combination of one choice
#    per group, with profiles/site.yaml, tests/values/release.yaml and
#    tests/values/keys.yaml, without consent (the default). A default choice
#    has no file:
#      database   database-bundled (default), database-external
#      OpenBao    openbao-shamir (default), openbao-external
#      exposure   exposure-ingress-nginx, exposure-ingress-nginx-cert-manager,
#                 exposure-envoy-gateway, exposure-kgateway, exposure-none,
#                 exposure-on-premise
#      policies   none, network-policies
#    Each render goes through helm template, kubeconform -strict (if
#    installed; the Gateway API HTTPRoute schema comes from the CRDs
#    catalog), tests/check_render.py, tests/check_hook_order.py and
#    tests/check_installation.py no-consent; with network policies also
#    tests/check_network_matrix.py (the policies against
#    policies/network-matrix.yaml, with a model of the ingress controller
#    pods of the exposure: tests/fixtures/ingress-controller-pods.yaml).
#    helm lint runs once per database and OpenBao pair. More renders: the
#    bundled server with the DDL and connection logs off; your own Valkey or
#    Redis (redis-external) with both database choices, with and without
#    network policies; the minimal profile, with and without network
#    policies; consent (profiles/consent.yaml) with each exposure, with and
#    without network policies (also tests/check_installation.py all). Then
#    the bundled Valkey and NATS certificates and the NATS configuration.
#    The tests after the matrix use profiles/consent.yaml, and
#    profiles/exposure-envoy-gateway.yaml where they pick an exposure. The
#    files of manifests/envoy-gateway/ go through kubeconform -strict.
# 3. The next steps (NOTES.txt).
# 4. Render guards: wrong values stop the render with a clear message
#    (values.schema.json and the template guards).
# 5. Rendered settings, also the installed services
#    (tests/check_installation.py): all services, consent or the wallet from
#    another release, without consent, without the wallet; the user and
#    group of the NATS JetStream store; global.podSecurityContext and
#    global.containerSecurityContext below the component values.
# 6. Install and upgrade: tests/check_hook_order.py replays the Helm steps on
#    the renders (each matrix render is an install; installs with consent,
#    the api or the organisation wallet off; an upgrade with the same values;
#    upgrades that turn the organisation wallet, consent or the api on; and
#    upgrades that install or remove consent or the wallet). Hook Secrets
#    keep the values of the earlier Secrets (a copy of the chart reads them
#    from a file instead of lookup).
# 7. Security settings of every container in every render:
#    tests/check_security.py and the Pod Security Standard "restricted" with
#    the upstream library (tests/psscheck; needs Go). Both checks must refuse
#    the mutants of tests/values/pss-mutant.yaml and
#    tests/fixtures/pss-pods.yaml. Then tests/check_lifecycle.py on each
#    render and on tests/fixtures/lifecycle-pods.yaml.
#
# Usage: tests/render-matrix.sh [--keep <dir>]
#   --keep <dir>: keep the renders in <dir> (default: a temporary folder).
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
chart="$(dirname "$here")"
profiles="$chart/profiles"
keys="$here/values/keys.yaml"
# profiles/site.yaml with the release tag that the tests use.
site=(-f "$profiles/site.yaml" -f "$here/values/release.yaml")
# All services, with consent (off by default): for the tests after the
# matrix.
all=("${site[@]}" -f "$profiles/consent.yaml")
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
while IFS= read -r -d '' file; do files+=("$file"); done < <(find "$chart/templates" "$chart/files" "$chart/profiles" "$chart/manifests" "$chart/docs" "$here" -type f -print0)
text_check() {
  local what="$1" pattern="$2"; shift 2
  local hits
  # Skip code literals of other programs, which are not prose: the
  # "bao status" output (Initialized), OpenBao's JSON key .initialized, the
  # "serialization" module of the Python package cryptography, and the
  # "organizations" table of the API database in an SQL query. For the
  # vault check, these do not name the earlier key store product: the key
  # store type ids `vault`, external-vault and azure-key-vault, a list of
  # the types ([vault, ...]), the product name Azure Key Vault and its host
  # names (<vault>.vault.azure.net).
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
# No em dash (U+2014) or en dash (U+2013) in any text file of the
# repository, except the licence texts of other projects.
all_files=()
while IFS= read -r -d '' file; do all_files+=("$file"); done < <(find "$chart" -type f ! -path '*/.git/*' ! -path "$chart/licenses/*" ! -name 'LICENSE*' -print0)
if dashes="$(grep -n -I -E "$(printf '\342\200\224|\342\200\223')" "${all_files[@]}")"; then
  bad "text: no em dash or en dash in any file"
  printf '%s\n' "$dashes" | sed "s|$chart/||; s/^/  /" | head -10
else
  ok "text: no em dash or en dash in any file ($(printf '%s\n' "${all_files[@]}" | wc -l | tr -d ' ') files)"
fi
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
# Relative links in the docs: each target file and each anchor heading
# exists.
if links="$(python3 "$here/check_links.py" "$chart/README.md" "$chart"/docs/*.md 2>&1)"; then
  ok "text: relative links of README.md and docs/"
else
  bad "text: relative links of README.md and docs/"
  printf '%s\n' "$links" | sed "s|$chart/||; s/^/  /" | head -10
fi
# Each values.yaml image is in docs/images.md, each third-party image is in
# THIRD-PARTY-NOTICES.md, and the Valkey and redis_exporter licence texts
# are in licenses/.
if problems="$(python3 - "$chart" <<'PY' 2>&1
import sys, yaml
chart = sys.argv[1]
images, notices = open(f"{chart}/docs/images.md").read(), open(f"{chart}/THIRD-PARTY-NOTICES.md").read()
def walk(node, path):
    if isinstance(node, dict):
        if node.get("repository") and "tag" in node:
            name = f"{node['registry']}/{node['repository']}" if node.get("registry") else node["repository"]
            if f"`{path}`" not in images or f"`{name}`" not in images and f"`{name}` (" not in images:
                print(f"docs/images.md does not list {path} ({name})")
            if node.get("registry") and f"`{name}`" not in notices:
                print(f"THIRD-PARTY-NOTICES.md does not list {name}")
        for key, value in node.items():
            walk(value, f"{path}.{key}" if path else key)
walk(yaml.safe_load(open(f"{chart}/values.yaml")), "")
if "Copyright (c) 2024-present, Valkey contributors" not in open(f"{chart}/licenses/valkey/COPYING").read():
    print("licenses/valkey/COPYING is not the Valkey licence")
if "Copyright (c) 2016 Oliver" not in open(f"{chart}/licenses/redis_exporter/LICENSE").read():
    print("licenses/redis_exporter/LICENSE is not the redis_exporter licence")
PY
)" && [ -z "$problems" ]; then
  ok "text: images in docs/images.md and THIRD-PARTY-NOTICES.md"
else
  bad "text: images in docs/images.md and THIRD-PARTY-NOTICES.md"
  printf '%s\n' "$problems" | sed 's/^/  /' | head -10
fi

# --- 2. The matrix of the profiles --------------------------------------------
kubeconform_bin="$(command -v kubeconform || true)"
if [ -z "$kubeconform_bin" ]; then
  echo "kubeconform is not installed: skipping the schema check"
fi
kubeconform_cache="$out/kubeconform-cache"
mkdir -p "$kubeconform_cache"
mode_of() { case "$1" in *-external) echo external ;; *) echo bundled ;; esac; }
exposure_of() { case "$1" in exposure-ingress-*) echo ingress ;; exposure-none) echo none ;; exposure-on-premise) echo on-premise ;; *) echo gatewayAPI ;; esac; }
# The network matrix check (tests/check_network_matrix.py) of a render,
# with the model of the ingress controller pods of its exposure profile
# (tests/fixtures/ingress-controller-pods.yaml; no model for kgateway).
# "defaults": the chart defaults, which select the Envoy pods of the
# Gateway platform.
controller_of() { case "$1" in exposure-ingress-nginx*) echo ingress-nginx ;; exposure-on-premise) echo on-premise ;; exposure-kgateway) echo "" ;; *) echo envoy-gateway ;; esac; }
network_matrix() {
  local file="$1" controller
  controller="$(controller_of "$2")"
  if [ -n "$controller" ]; then
    python3 "$here/check_network_matrix.py" "$file" "$chart/policies/network-matrix.yaml" "$here/fixtures/ingress-controller-pods.yaml" "$controller"
  else
    python3 "$here/check_network_matrix.py" "$file" "$chart/policies/network-matrix.yaml"
  fi
}
for database in database-bundled database-external; do
  for openbao in openbao-shamir openbao-external; do
    base=(-f "$keys" "${site[@]}")
    [ "$database" = database-external ] && base+=(-f "$profiles/database-external.yaml")
    [ "$openbao" = openbao-external ] && base+=(-f "$profiles/openbao-external.yaml")
    if helm lint "$chart" --quiet "${base[@]}" > "$out/lint.txt" 2>&1; then
      ok "lint $database $openbao"
    else
      bad "lint $database $openbao"
      sed 's/^/  /' "$out/lint.txt" | head -10
    fi
    for exposure in exposure-ingress-nginx exposure-ingress-nginx-cert-manager exposure-envoy-gateway exposure-kgateway exposure-none exposure-on-premise; do
      for policies in none network-policies; do
        name="$database-$openbao-$exposure-$policies"
        args=("${base[@]}" -f "$profiles/$exposure.yaml")
        [ "$policies" = network-policies ] && args+=(-f "$profiles/network-policies.yaml")
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
        if ! python3 "$here/check_render.py" "$out/$name.yaml" postgresql "$(mode_of "$database")" \
            "${openbao#openbao-}" "$(exposure_of "$exposure")" "$([ "$policies" = network-policies ] && echo on || echo off)"; then
          good=0
        fi
        if ! python3 "$here/check_hook_order.py" install "$out/$name.yaml"; then
          good=0
        fi
        if ! result="$(python3 "$here/check_installation.py" "$out/$name.yaml" no-consent 2>&1)"; then
          printf '%s\n' "$result" | sed 's/^/  /' | head -10
          good=0
        fi
        if [ "$policies" = network-policies ] && ! network_matrix "$out/$name.yaml" "$exposure"; then
          good=0
        fi
        if [ "$good" = 1 ]; then ok "$name"; else bad "$name"; fi
      done
    done
  done
done
# With consent (profiles/consent.yaml): the bundled database, the shamir
# seal, each exposure, with and without network policies.
for exposure in exposure-ingress-nginx exposure-ingress-nginx-cert-manager exposure-envoy-gateway exposure-kgateway exposure-none exposure-on-premise; do
  for policies in none network-policies; do
    name="consent-$exposure-$policies"
    args=(-f "$keys" "${all[@]}" -f "$profiles/$exposure.yaml")
    [ "$policies" = network-policies ] && args+=(-f "$profiles/network-policies.yaml")
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
    if ! python3 "$here/check_render.py" "$out/$name.yaml" postgresql bundled shamir "$(exposure_of "$exposure")" "$([ "$policies" = network-policies ] && echo on || echo off)"; then
      good=0
    fi
    if ! python3 "$here/check_hook_order.py" install "$out/$name.yaml"; then
      good=0
    fi
    if ! result="$(python3 "$here/check_installation.py" "$out/$name.yaml" all 2>&1)"; then
      printf '%s\n' "$result" | sed 's/^/  /' | head -10
      good=0
    fi
    if [ "$policies" = network-policies ] && ! network_matrix "$out/$name.yaml" "$exposure"; then
      good=0
    fi
    if [ "$good" = 1 ]; then ok "$name"; else bad "$name"; fi
  done
done
# The files of manifests/envoy-gateway/ (the Gateway of the default
# exposure, docs/prerequisites.md): kubeconform -strict with the Gateway
# API, Envoy Gateway and cert-manager schemas of the CRDs catalog.
if [ -n "$kubeconform_bin" ]; then
  if result="$("$kubeconform_bin" -strict -summary -cache "$kubeconform_cache" \
      -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json' \
      "$chart"/manifests/envoy-gateway/*.yaml 2>&1)" && grep -q -F 'Valid: 7, Invalid: 0, Errors: 0, Skipped: 0' <<< "$result"; then
    ok "manifests/envoy-gateway: kubeconform -strict (7 objects)"
  else
    bad "manifests/envoy-gateway: kubeconform"
    printf '%s\n' "$result" | sed 's/^/  /' | head -10
  fi
fi

# The bundled server with the DDL and connection logs off
# (database.postgresql.logDdlAndConnections false): no log parameter.
name="database-bundled-openbao-shamir-exposure-none-none-database-logs-off"
if ! helm template t "$chart" --namespace ow -f "$keys" "${site[@]}" \
    -f "$profiles/exposure-none.yaml" --set database.postgresql.logDdlAndConnections=false \
    > "$out/$name.yaml" 2> "$out/$name.err"; then
  bad "$name: helm template"
  sed 's/^/  /' "$out/$name.err" | head -10
elif python3 "$here/check_render.py" "$out/$name.yaml" postgresql bundled shamir none off off; then
  ok "$name"
else
  bad "$name"
fi

# Your own Valkey or Redis (redis.mode external, profiles/redis-external.yaml):
# no chart Valkey, the redis section of the wallet roles, and egress to your
# servers.
if helm lint "$chart" --quiet -f "$keys" "${site[@]}" \
    -f "$profiles/redis-external.yaml" > "$out/lint.txt" 2>&1; then
  ok "lint redis-external"
else
  bad "lint redis-external"
  sed 's/^/  /' "$out/lint.txt" | head -10
fi
for database in database-bundled database-external; do
  for policies in none network-policies; do
    name="redis-external-$database-$policies"
    args=(-f "$keys" "${site[@]}"
      -f "$profiles/exposure-envoy-gateway.yaml" -f "$profiles/redis-external.yaml")
    [ "$database" = database-external ] && args+=(-f "$profiles/database-external.yaml")
    [ "$policies" = network-policies ] && args+=(-f "$profiles/network-policies.yaml")
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
    netpol="$([ "$policies" = network-policies ] && echo on || echo off)"
    if ! python3 "$here/check_render.py" "$out/$name.yaml" postgresql "$(mode_of "$database")" shamir gatewayAPI "$netpol" on external; then
      good=0
    fi
    if ! python3 "$here/check_hook_order.py" install "$out/$name.yaml"; then
      good=0
    fi
    if [ "$policies" = network-policies ] && ! network_matrix "$out/$name.yaml" exposure-envoy-gateway; then
      good=0
    fi
    if [ "$good" = 1 ]; then ok "$name"; else bad "$name"; fi
  done
done
# The minimal profile (profiles/minimal.yaml), with and without network
# policies: one replica per service except the worker groups, and 3 Valkey
# pods.
if helm lint "$chart" --quiet -f "$keys" "${site[@]}" -f "$profiles/minimal.yaml" > "$out/lint.txt" 2>&1; then
  ok "lint minimal"
else
  bad "lint minimal"
  sed 's/^/  /' "$out/lint.txt" | head -10
fi
for policies in none network-policies; do
  name="minimal-$policies"
  args=(-f "$keys" "${site[@]}" -f "$profiles/exposure-envoy-gateway.yaml" -f "$profiles/minimal.yaml")
  [ "$policies" = network-policies ] && args+=(-f "$profiles/network-policies.yaml")
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
  if ! python3 "$here/check_hook_order.py" install "$out/$name.yaml"; then
    good=0
  fi
  if [ "$policies" = network-policies ] && ! network_matrix "$out/$name.yaml" exposure-envoy-gateway; then
    good=0
  fi
  if ! python3 - "$out/$name.yaml" <<'PY'
import sys, yaml
docs = [d for d in yaml.safe_load_all(open(sys.argv[1])) if d]
want = {"t-api": 1, "t-webhook": 1, "t-gateway": 1, "t-dashboard": 1, "t-wallet-service": 1,
        "t-wallet-config": 1, "t-wallet-clock": 1, "t-wallet-worker-main": 2, "t-wallet-worker-maintenance": 1,
        "t-postgres": 1, "t-nats": 1, "t-openbao": 1, "t-redis": 3}
got = {d["metadata"]["name"]: d["spec"].get("replicas") for d in docs if d["kind"] in ("Deployment", "StatefulSet")}
problems = [] if got == want else [f"replicas {got}"]
for problem in problems:
    print(f"  {problem}")
sys.exit(1 if problems else 0)
PY
  then
    good=0
  fi
  if [ "$good" = 1 ]; then ok "$name"; else bad "$name"; fi
done
# The bundled Valkey's certificate: the pod names, the Sentinel Service and
# 127.0.0.1 (clients check the host name).
if ! helm template t "$chart" --namespace ow -f "$keys" "${site[@]}" \
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
  ok "Valkey certificate: pod names, Sentinel Service and 127.0.0.1, for server and client use"
else
  bad "Valkey certificate: a name or a usage is missing"
fi

# The bundled NATS: its certificate (client Service, route pod names and
# 127.0.0.1, for server and client use) and its configuration
# (nats-server -t, if nats-server is installed).
if ! helm template t "$chart" --namespace ow -f "$keys" "${site[@]}" \
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
    ok "NATS certificate: client Service, route pod names and 127.0.0.1, for server and client use"
  else
    bad "NATS certificate: a name or a usage is missing"
  fi
  if command -v nats-server > /dev/null; then
    rm -rf "$out/nats-conf"
    if python3 "$here/write_nats_conf.py" "$out/nats-tls.yaml" "$out/nats-conf" \
        && conf="$(SERVER_NAME=t-nats-0 nats-server -t -c "$out/nats-conf/nats.conf" 2>&1)"; then
      ok "NATS configuration: nats-server -t (client and route TLS)"
    else
      bad "NATS configuration: nats-server -t: $(printf '%s' "${conf:-}" | head -c 300)"
    fi
    rm -rf "$out/nats-conf"
  else
    echo "nats-server is not installed: skipping the NATS configuration check"
  fi
fi

# --- 3. The next steps (NOTES.txt) --------------------------------------------
# helm template does not render NOTES.txt, so a copy of the chart renders it
# as a ConfigMap.
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
  if ! text="$(helm template ows "$notes_chart" --namespace ows -f "$keys" "${all[@]}" "$@" --show-only templates/zz-test-notes.yaml 2>&1)"; then
    bad "notes $name: $(printf '%s' "$text" | head -c 200)"
  elif grep -q -F -- "$expect" <<< "$text"; then
    ok "notes $name"
  else
    bad "notes $name: no \"$expect\""
  fi
}
notes "shamir" "bao operator unseal"
notes "external OpenBao" "Make the platform operator organisation and its first platform admin" -f "$profiles/openbao-external.yaml"
notes "URLs" "https://api.example.org"
# An SSRF guard turned off in an extraConfig gives a warning in the notes
# that names the role; no warning by default.
notes "SSRF guard off: the api core and the webhook handler" "WARNING: the SSRF guard of the api core and the webhook handler is off (api.extraConfig.OutboundHttp.ssrfProtectionDisabled is true). These pods call" \
  --set-json 'api.extraConfig={"OutboundHttp":{"ssrfProtectionDisabled":true}}'
notes "SSRF guard off: consent" "WARNING: the SSRF guard of consent is off (consent.extraConfig.OutboundHttp.ssrfProtectionDisabled is true). These pods call" \
  --set-json 'consent.extraConfig={"OutboundHttp":{"ssrfProtectionDisabled":true}}'
notes "SSRF guard off: the wallet" "WARNING: the SSRF guard of the wallet service, config and worker pods is off (organisationWallet.extraConfig.ssrf_protection.enabled is false). These pods call" \
  --set-json 'organisationWallet.extraConfig={"ssrf_protection":{"enabled":false}}'
if helm template ows "$notes_chart" --namespace ows -f "$keys" "${all[@]}" \
    --set-json 'organisationWallet.extraConfig={"ssrf_protection":{"enabled":true}}' --show-only templates/zz-test-notes.yaml 2>&1 | grep -q "WARNING: the SSRF guard of"; then
  bad "notes: an SSRF warning with the guards on"
else
  ok "notes: no SSRF warning with the guards on"
fi
notes "connection budget of the bundled server" "can open 225 connections to it, and the hooks 5 more (max_connections"
notes "connection budget of an external server" "set max_connections of your server to at least 230" -f "$profiles/database-external.yaml"
notes "without consent" "Consent is not installed: the gateway answers 404 to the consent routes" --set consent.enabled=false
notes "without the wallet" "The organisation wallet is not installed" --set organisationWallet.enabled=false
# Readers of a missing service's views open no connection: without the
# wallet, the api core and the webhook handler have no reader pool and
# consent has one reader (71 = 1 x 16 + 1 x 11 + 2 x 11 + 2 x 11, with the
# health connection of each api and gateway pod); without consent, the
# wallet config role has one reader (225 less 2 x 16 for consent and 10).
notes "connection budget without the wallet" "can open 71 connections to it" --set organisationWallet.enabled=false
notes "connection budget without consent" "can open 183 connections to it" --set consent.enabled=false

# --- 4. The render guards --------------------------------------------------------
# Each case: values that must stop the render, and a text that the message
# must contain.
guard() {
  local name="$1" expect="$2"; shift 2
  local err pointer="$expect"
  # Helm 3.18 and later (also Helm 4) name a schema error by its JSON pointer
  # (at '/database/mode') and write "additional properties 'x' not allowed";
  # earlier Helm writes database.mode and "Additional property x is not
  # allowed". The check accepts both forms.
  case "$expect" in
    "Additional property") pointer="additional properties" ;;
    "Additional property "*) pointer="additional properties '${expect#Additional property }'" ;;
    *[!A-Za-z0-9.]*) ;;
    *.*) pointer="/${expect//./\/}" ;;
  esac
  if err="$(helm template t "$chart" --namespace ow -f "$keys" "${all[@]}" "$@" 2>&1 >/dev/null)"; then
    bad "guard $name: the render did not stop"
  elif grep -q -F -- "$expect" <<< "$err" || grep -q -F -- "$pointer" <<< "$err"; then
    # A here-string, as in renders: with pipefail, "printf | grep -q" fails
    # when grep exits before printf has written everything (SIGPIPE).
    ok "guard $name"
  else
    bad "guard $name: the message lacks \"$expect\""
    printf '%s\n' "$err" | sed 's/^/  /' | head -5
  fi
}
# A guard of an unknown property name (propertyNames in the schema). Helm
# 3.18 and later (also Helm 4) refuse the name, but can name a wrong
# location for the error: a bug of their schema library
# (santhosh-tekuri/jsonschema issue 276, open). So the message must name the
# value, or the refused property ("invalid propertyName '<name>'").
guard_property_name() {
  local name="$1" expect="$2" property="$3"; shift 3
  local err
  if err="$(helm template t "$chart" --namespace ow -f "$keys" "${all[@]}" "$@" 2>&1 >/dev/null)"; then
    bad "guard $name: the render did not stop"
  elif grep -q -F -- "$expect" <<< "$err" || grep -q -F -- "invalid propertyName '$property'" <<< "$err"; then
    ok "guard $name"
  else
    bad "guard $name: the message lacks \"$expect\" and \"invalid propertyName '$property'\""
    printf '%s\n' "$err" | sed 's/^/  /' | head -5
  fi
}
# PostgreSQL is the only engine: the template guard (ow.db.engine) refuses
# any other engine with a message that names the components (the schema has
# no enum for it). mysql also stops the render when only one of the api,
# consent and the organisation wallet is on.
only_postgresql="is not supported: the api, consent and the organisation wallet accept only postgresql"
guard "engine" "database.engine \"oracle\" $only_postgresql" --set database.engine=oracle
guard "engine mysql" "database.engine \"mysql\" $only_postgresql" --set database.engine=mysql
mysql_external=(-f "$profiles/database-external.yaml" --set database.engine=mysql
  --set api.enabled=false --set consent.enabled=false --set organisationWallet.enabled=false)
guard "engine mysql with the api only" "database.engine \"mysql\" $only_postgresql" "${mysql_external[@]}" --set api.enabled=true \
  --set gateway.upstreams.consent.url=http://consent.example.org --set gateway.upstreams.walletConfig.url=http://wallet.example.org
guard "engine mysql with consent only" "database.engine \"mysql\" $only_postgresql" "${mysql_external[@]}" --set consent.enabled=true
guard "engine mysql with the organisation wallet only" "database.engine \"mysql\" $only_postgresql" "${mysql_external[@]}" --set organisationWallet.enabled=true
guard "mode" "database.mode" --set database.mode=cluster
guard "external host" "database.external.host" --set database.mode=external --set database.external.admin.user=root --set database.external.admin.passwordSecret=s --set database.tls.caSecret=c
# The wallet roles hook creates the wallet's database roles as the server
# administrator, so an external server needs an admin user with the wallet.
guard "external database without admin user" "database.external.admin.user is required with database.mode external and the organisation wallet" --set database.mode=external --set database.external.host=db.example.org --set database.tls.caSecret=c
guard "external database without admin user, wallet off" "database.auth.existingSecret" --set database.mode=external --set database.external.host=db.example.org --set database.tls.caSecret=c --set organisationWallet.enabled=false --set gateway.upstreams.walletConfig.url=http://wallet.example.org
# The wallet database name is the prefix of the wallet's database roles:
# <prefix>_business_wallet_app has at most 63 characters.
guard "wallet database name too long for the role prefix" "can have at most 43" --set database.databases.wallet.name=w2345678901234567890123456789012345678901234
guard "seal" "openbao.seal" --set openbao.seal=transit
guard "external OpenBao without address" "openbao.external.address" --set openbao.mode=external --set openbao.wallet.existingSecret=s
guard "external OpenBao without password" "openbao.wallet.existingSecret" --set openbao.mode=external --set openbao.external.address=https://openbao.example.org:8200
guard "exposure type" "exposure.type" --set exposure.type=route
guard "gatewayAPI without parentRefs" "parentRefs" --set exposure.type=gatewayAPI
guard "host" "api.host" --set api.host=
guard "image tag" "global.imageTag is required: the release tag of your version" --set global.imageTag=
guard "client address" "clientAddress" --set 'clientAddress.trustedProxies={192.0.2.0/24}'
guard "unknown value" "Additional property" --set postgres.enabled=true
guard "privacy dashboard network policy without Kubernetes API address" "networkPolicy.egress.profiles.kubeApi" --set networkPolicy.enabled=true --set privacyDashboard.enabled=true --set privacyDashboard.namespace=privacy-dashboards
guard "sslMode verify-full without CA" "needs the CA of the server" -f "$profiles/database-external.yaml" --set database.tls.caSecret= --set database.tls.sslMode=verify-full
guard "OpenBao update strategy" "openbao.updateStrategy" --set openbao.updateStrategy=Sometimes
# The platform operator Job: the required values, an http or https policy
# URL, and no password as a value (the password is a file in a Secret).
bootstrap=(-f "$here/values/operator-jobs-bootstrap.yaml")
guard "platform operator without admin e-mail" "api.jobs.bootstrapPlatform.adminEmail" "${bootstrap[@]}" --set api.jobs.bootstrapPlatform.adminEmail=
guard "platform operator without admin name" "api.jobs.bootstrapPlatform.adminName" "${bootstrap[@]}" --set api.jobs.bootstrapPlatform.adminName=
guard "platform operator without password Secret" "api.jobs.bootstrapPlatform.passwordSecret" "${bootstrap[@]}" --set api.jobs.bootstrapPlatform.passwordSecret=
guard "platform operator without organisation name" "api.jobs.bootstrapPlatform.organisationName" "${bootstrap[@]}" --set api.jobs.bootstrapPlatform.organisationName=
guard "platform operator without organisation type" "api.jobs.bootstrapPlatform.type" "${bootstrap[@]}" --set api.jobs.bootstrapPlatform.type=
guard "platform operator without location" "api.jobs.bootstrapPlatform.location" "${bootstrap[@]}" --set api.jobs.bootstrapPlatform.location=
guard "platform operator without policy URL" "api.jobs.bootstrapPlatform.policyUrl" "${bootstrap[@]}" --set api.jobs.bootstrapPlatform.policyUrl=
guard "platform operator policy URL not http or https" "policyUrl" "${bootstrap[@]}" --set api.jobs.bootstrapPlatform.policyUrl=ftp://example.org/privacy
guard "platform operator password as a value" "Additional property password" "${bootstrap[@]}" --set api.jobs.bootstrapPlatform.password=not-a-value
guard "feature gate not a boolean" "enforce" --set-string gateway.features.enforce=off
# A folder that a process writes to must be on an emptyDir of its pod (the
# root file system is read-only).
guard "wallet state folder outside the emptyDir" "has worker.state_directory \"/var/ows\"" --set organisationWallet.extraConfig.worker.state_directory=/var/ows
# No log file (ow.noLogFile): each process logs to stdout, even with a path
# on an emptyDir (a rotating file of 6 x 100 MB fills a 64Mi /tmp).
no_log_file="the chart writes no log file in Kubernetes"
guard "no wallet log file" "organisationWallet.extraConfig sets log_file.path \"/tmp/ows.log\": $no_log_file" --set organisationWallet.extraConfig.log_file.path=/tmp/ows.log
guard "no wallet log file outside /tmp" "organisationWallet.extraConfig sets log_file.path \"/var/log/ows.log\": $no_log_file" --set organisationWallet.extraConfig.log_file.path=/var/log/ows.log
guard "no api log file" "api.extraConfig sets Log.file.path \"/tmp/api.log\": $no_log_file" --set api.extraConfig.Log.file.path=/tmp/api.log
guard "no gateway log file" "gateway.extraConfig sets Log.file.path \"/tmp/gateway.log\": $no_log_file" --set gateway.extraConfig.Log.file.path=/tmp/gateway.log
guard "no consent log file" "consent.extraConfig sets Log.file.path \"/tmp/consent.log\": $no_log_file" --set consent.extraConfig.Log.file.path=/tmp/consent.log
# The api /tmp (api.tmp, an emptyDir in memory) must hold one upload of the
# largest gateway body above 32 MiB (Go's multipart parser writes such a
# file part whole to /tmp), and the memory request plus /tmp must fit below
# the container's memory limit (ow.api.checkTmp).
guard "api /tmp below the gateway file body limit" "api.tmp.sizeLimit (64Mi, 67108864 bytes) is below the largest body that the gateway sends to the api (104857600 bytes" \
  --set gateway.proxy.maxBodyBytes.file=104857600
guard "api /tmp below the gateway default body limit" "is below the largest body that the gateway sends to the api (67108865 bytes" \
  --set gateway.proxy.maxBodyBytes.default=67108865
guard "api /tmp just below a body above 32 MiB" "api.tmp.sizeLimit (32Mi, 33554432 bytes) is below the largest body that the gateway sends to the api (33554433 bytes" \
  --set gateway.proxy.maxBodyBytes.file=33554433 --set api.tmp.sizeLimit=32Mi
guard "api memory limit below the request and /tmp" "api.resources: the memory request (272Mi) and api.tmp.sizeLimit (64Mi) together are above the memory limit (300Mi)" \
  --set api.resources.limits.memory=300Mi
guard "webhook memory limit below the request and /tmp" "api.webhook.resources: the memory request (32Mi) and api.tmp.sizeLimit (64Mi) together are above the memory limit (90Mi)" \
  --set api.webhook.resources.limits.memory=90Mi
guard "api /tmp sizeLimit not a quantity" "api.tmp.sizeLimit" --set api.tmp.sizeLimit=64MB
# Stopping the HTTP pods (ow.checkStopBudget, the dashboard guard and the
# schema): the grace period covers the preStop sleep and the server stop; a
# preStop of 0 seconds or a strategy other than RollingUpdate stops the
# render.
guard "gateway stop budget with the preStop" "gateway.terminationGracePeriodSeconds (35) must be at least preStopSeconds (10) + drainSeconds (5) + gracefulShutdownSeconds (20) + 5 = 40" \
  --set gateway.terminationGracePeriodSeconds=35
guard "api stop budget with the preStop" "api.server.terminationGracePeriodSeconds (40) must be at least preStopSeconds (15)" --set api.server.preStopSeconds=15
guard "consent stop budget with the preStop" "consent.server.terminationGracePeriodSeconds (39)" --set consent.server.terminationGracePeriodSeconds=39
guard "dashboard stop budget" "enterpriseDashboard.terminationGracePeriodSeconds (15) must be at least preStopSeconds (10) + 10" \
  --set enterpriseDashboard.terminationGracePeriodSeconds=15
guard "wallet stop budget" "organisationWallet.server: preStopSeconds (20) + gracefulShutdownSeconds (20) + backgroundShutdownSeconds (10) = 50 must be below terminationGracePeriodSeconds (45)" \
  --set organisationWallet.server.preStopSeconds=20
guard "preStop of 0 seconds" "preStopSeconds" --set api.server.preStopSeconds=0
guard "rollout strategy Recreate" "strategy" --set gateway.strategy.type=Recreate

# --- 5. Rendered settings ----------------------------------------------------------
# Each case: a text that the render must contain.
renders() {
  local name="$1" expect="$2"; shift 2
  local text
  if ! text="$(helm template t "$chart" --namespace ow -f "$keys" "${all[@]}" "$@" 2>&1)"; then
    bad "renders $name: $(printf '%s' "$text" | head -c 200)"
  elif grep -q -F -- "$expect" <<< "$text"; then
    # A here-string: with pipefail, "printf | grep -q" of a large render
    # fails when grep stops early (SIGPIPE).
    ok "renders $name"
  else
    bad "renders $name: no \"$expect\""
  fi
}
# Each case: a text that the render must not contain.
lacks() {
  local name="$1" unexpected="$2"; shift 2
  local text
  if ! text="$(helm template t "$chart" --namespace ow -f "$keys" "${all[@]}" "$@" 2>&1)"; then
    bad "lacks $name: $(printf '%s' "$text" | head -c 200)"
  elif grep -q -F -- "$unexpected" <<< "$text"; then
    bad "lacks $name: has \"$unexpected\""
  else
    ok "lacks $name"
  fi
}
# With the shamir seal, a restarted pod stays sealed until an operator
# unseals it, so the StatefulSet must not roll the pods by itself.
renders "OpenBao OnDelete with shamir" "type: OnDelete"
renders "OpenBao OnDelete removes rollingUpdate" "rollingUpdate: null"
renders "OpenBao RollingUpdate when set" "type: RollingUpdate" --set openbao.updateStrategy=RollingUpdate
# The wallet reads a key right after it creates it: no reads on a standby.
renders "OpenBao standbys forward reads" "disable_standby_reads = true"
# The api's operator Jobs (tests/check_operator_jobs.py): none by default;
# the platform operator of a new installation (onboard bootstrap-platform).
# The password is a file of its own Secret, never an argument, a variable or
# a ConfigMap value.
operator_jobs() {
  local case="$1"; shift
  local file="$out/operator-jobs-$case.yaml" result
  if ! result="$(helm template t "$chart" --namespace ow -f "$keys" "${all[@]}" "$@" 2>&1 > "$file")"; then
    bad "operator Jobs $case: $(printf '%s' "$result" | head -c 300)"
  elif result="$(python3 "$here/check_operator_jobs.py" "$file" "$case" 2>&1)"; then
    ok "operator Jobs $case"
  else
    bad "operator Jobs $case"
    printf '%s\n' "$result" | sed 's/^/  /' | head -20
  fi
}
operator_jobs none
operator_jobs bootstrap -f "$here/values/operator-jobs-bootstrap.yaml"
# The gateway feature gate (Features.enforce): on by default, off with
# gateway.features.enforce false; gateway.extraConfig still wins.
renders "feature gate on by default" "enforce: true"
renders "feature gate off" "enforce: false" --set gateway.features.enforce=false
lacks "feature gate off has no enforce true" "enforce: true" --set gateway.features.enforce=false
renders "feature gate off with extraConfig" "enforce: false" --set gateway.extraConfig.Features.enforce=false
# Each organisation's effective features select its webhook event types, so
# the api files have no Webhooks.events and the schema refuses the value.
renders "webhook delivery retention in the api files" "DeliveryRetentionDays: 10" --show-only templates/api/configmap.yaml
lacks "no webhook event types in the api files" "consent.allowed" --show-only templates/api/configmap.yaml
guard "no api.webhooks.events" "api.webhooks" --set-json 'api.webhooks.events=["consent.allowed"]'
# The API core publishes an event when an organisation is deleted.
renders "api publishes the organisation deleted event" '"api.v1.evt.organisation.deleted"'
# The wallet's EU trusted list check and key store providers.
renders "EU trusted list check on by default" "eu_lotl_url: https://ec.europa.eu/tools/lotl/eu-lotl.xml"
renders "EU trusted list check off" "eu_lotl_url: null" --set organisationWallet.trustList.euLotlUrl=
# Refresh of the list trust sources (trust_sources.*).
renders "trust sources refresh defaults" "refresh_max_interval_seconds: 86400"
renders "trust sources stale grace" "stale_grace_seconds: 3600" --set organisationWallet.trustSources.staleGraceSeconds=3600
guard "trust sources refresh interval too short" "refreshMinIntervalSeconds" --set organisationWallet.trustSources.refreshMinIntervalSeconds=10
renders "added key store provider" "logo_url: https://example.org/qtsp.png" --set-json 'organisationWallet.keyStores.providers.add=[{"id":"example-qtsp","category":"qtsp","type":"csc","name":"Example QTSP","protection":"provider","qualified":true,"logoUrl":"https://example.org/qtsp.png","region":"SE","order":30}]'
guard "key store provider category" "category" --set-json 'organisationWallet.keyStores.providers.add=[{"id":"x","category":"cloud","type":"csc","name":"X","protection":"provider"}]'
guard "key store provider type must match its category" "add.0.type" --set-json 'organisationWallet.keyStores.providers.add=[{"id":"x","category":"qtsp","type":"vault","name":"X","protection":"provider"}]'
guard "unknown key store type" "organisationWallet.keyStores.types" --set 'organisationWallet.keyStores.types={vault,example}'
renders "cloud KMS types by default" "- azure-key-vault"
# The built-in test CA: kms.test_ca in every wallet role file except the
# clock file, which has no kms section.
test_ca() {
  local name="$1" expect="$2"; shift 2
  local text problems
  # Only stdout is YAML (helm writes its warnings to stderr).
  if ! text="$(helm template t "$chart" --namespace ow -f "$keys" "${all[@]}" "$@" --show-only templates/wallet/configmap.yaml 2> "$out/test-ca.err")"; then
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
test_ca "on by default" '{"enabled": true, "leaf_validity_days": 365}'
test_ca "off, 90 days" '{"enabled": false, "leaf_validity_days": 90}' --set organisationWallet.keyStores.testCa.enabled=false --set organisationWallet.keyStores.testCa.leafValidityDays=90
guard "test CA validity" "organisationWallet.keyStores.testCa.leafValidityDays" --set organisationWallet.keyStores.testCa.leafValidityDays=3651
# The audit log: audit.* in every wallet role file (not the clock's, which
# writes no audit events) and in the migration hook. The bucket is only in
# the worker group files, and its credential Secrets (access key and CA for
# s3, service account for gcs) are only in the worker pods (the actors
# audit.anchor and audit.export).
audit() {
  local name="$1" expect="$2"; shift 2
  local problems
  # Only stdout is YAML (helm writes its warnings to stderr).
  if ! helm template t "$chart" --namespace ow -f "$keys" "${all[@]}" "$@" > "$out/audit.yaml" 2> "$out/audit.err"; then
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
        print(f"the {role} pods mount {secrets!r} as the audit bucket credentials")
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
# The wallet's Play Integrity keys (wallet_unit.play_integrity) and the
# Android app digests: the service and config files name them and only the
# service and config pods mount the keys. The two files have equal app
# settings (app_attest, the digests and play_integrity): the config pods
# make the first wallet app records from them.
play_integrity() {
  local name="$1" expect="$2"; shift 2
  local problems
  # Only stdout is YAML (helm writes its warnings to stderr).
  if ! helm template t "$chart" --namespace ow -f "$keys" "${all[@]}" "$@" > "$out/play.yaml" 2> "$out/play.err"; then
    bad "play integrity $name: $(head -c 200 "$out/play.err")"
  elif problems="$(python3 - "$out/play.yaml" "$expect" <<'PY' 2>&1
import json, sys, yaml
docs = [d for d in yaml.safe_load_all(open(sys.argv[1])) if d]
expected = json.loads(sys.argv[2])
def find(kind, name):
    return next(d for d in docs if d.get("kind") == kind and d["metadata"]["name"] == name)
files = find("ConfigMap", "t-wallet")["data"]
app_roles = ("service", "config")
for role in ("service", "config", "worker-main", "worker-maintenance", "clock"):
    unit = yaml.safe_load(files[f"{role}.yaml"]).get("wallet_unit") or {}
    want = expected["play_integrity"] if role in app_roles else None
    if unit.get("play_integrity") != want:
        print(f"{role}.yaml wallet_unit.play_integrity is {unit.get('play_integrity')!r}")
    want = expected["digests"] if role in app_roles else None
    if unit.get("android_signing_certificate_digests") != want:
        print(f"{role}.yaml wallet_unit.android_signing_certificate_digests is {unit.get('android_signing_certificate_digests')!r}")
    if "play_integrity_credentials_file" in unit:
        print(f"{role}.yaml names the Play Integrity service account")
    pod = find("Deployment", f"t-wallet-{role}")["spec"]["template"]["spec"]
    mounted = {item["path"]: [source["secret"]["name"], item["key"]] for volume in pod["volumes"] if volume["name"] == "secrets"
               for source in volume["projected"]["sources"] for item in source["secret"]["items"]}
    secrets = {path: secret for path, secret in mounted.items() if path.startswith("play-integrity")}
    if secrets != (expected["secrets"] if role in app_roles else {}):
        print(f"the {role} pods mount {secrets!r} as the Play Integrity keys")
units = [yaml.safe_load(files[f"{role}.yaml"]).get("wallet_unit") or {} for role in app_roles]
for key in ("app_attest", "android_signing_certificate_digests", "play_integrity"):
    if units[0].get(key) != units[1].get(key):
        print(f"service.yaml and config.yaml have a different wallet_unit.{key}")
PY
)" && [ -z "$problems" ]; then
    ok "play integrity $name"
  else
    bad "play integrity $name: $(printf '%s' "$problems" | tr '\n' ';' | head -c 300)"
  fi
}
digest=ed5ed923ed30fab5ef5721931f43d1270b13340045bbbef31e0a9927a57e4142
play_integrity "no keys by default" '{"play_integrity": null, "digests": null, "secrets": {}}'
play_integrity "digests without keys" "{\"play_integrity\": null, \"digests\": [\"$digest\"], \"secrets\": {}}" \
  --set "organisationWallet.walletUnit.androidSigningCertificateDigests={$digest}"
play_integrity "keys in the service and config pods" "{\"play_integrity\": {\"decryption_key_file\": \"/run/secrets/eudi-wallet/play-integrity-decryption-key\", \"verification_key_file\": \"/run/secrets/eudi-wallet/play-integrity-verification-key\", \"package_name\": \"io.igrant.mobileagent\", \"min_version_code\": 42}, \"digests\": [\"$digest\"], \"secrets\": {\"play-integrity-decryption-key\": [\"play\", \"decryption-key\"], \"play-integrity-verification-key\": [\"play\", \"verification-key\"]}}" \
  --set organisationWallet.walletUnit.playIntegrity.existingSecret=play --set "organisationWallet.walletUnit.androidSigningCertificateDigests={$digest}" \
  --set organisationWallet.walletUnit.playIntegrity.minVersionCode=42
guard "Play Integrity keys without the certificate digest" "androidSigningCertificateDigests needs the SHA-256" --set organisationWallet.walletUnit.playIntegrity.existingSecret=play
guard "Android signing certificate digest not hex" "androidSigningCertificateDigests" --set "organisationWallet.walletUnit.androidSigningCertificateDigests={not-a-digest}"
# The App IDs of the iOS wallet apps (wallet_unit.app_attest.app_ids): only
# the service file (the protocol 1 checks) and the config file (the first
# wallet app records) name them.
app_attest() {
  local name="$1" expect="$2"; shift 2
  local problems
  # Only stdout is YAML (helm writes its warnings to stderr).
  if ! helm template t "$chart" --namespace ow -f "$keys" "${all[@]}" "$@" > "$out/app-attest.yaml" 2> "$out/app-attest.err"; then
    bad "app attest $name: $(head -c 200 "$out/app-attest.err")"
  elif problems="$(python3 - "$out/app-attest.yaml" "$expect" <<'PY' 2>&1
import json, sys, yaml
docs = [d for d in yaml.safe_load_all(open(sys.argv[1])) if d]
expected = json.loads(sys.argv[2])
files = next(d for d in docs if d.get("kind") == "ConfigMap" and d["metadata"]["name"] == "t-wallet")["data"]
for role in ("service", "config", "worker-main", "worker-maintenance", "clock"):
    unit = yaml.safe_load(files[f"{role}.yaml"]).get("wallet_unit") or {}
    want = {"app_ids": expected} if role in ("service", "config") else None
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
app_attest "the iGrant.io Data Wallet app by default" '["Y9726WB7V8.io.iGrant.DataWallet"]'
app_attest "the App IDs of two iOS apps" '["Y9726WB7V8.io.iGrant.DataWallet", "ABCDE12345.com.example.wallet"]' \
  --set "organisationWallet.walletUnit.appAttest.appIds={$app_ids}"
app_attest "no App ID without the production checks" '[]' --set-json 'organisationWallet.walletUnit.appAttest.appIds=[]'
guard "no App ID with the production checks" "appAttest.appIds needs at least one App ID" \
  --set organisationWallet.walletUnit.productionChecksEnabled=true --set-json 'organisationWallet.walletUnit.appAttest.appIds=[]'
guard "App ID without the Team ID" "appIds" --set "organisationWallet.walletUnit.appAttest.appIds={io.iGrant.DataWallet}"
# Device roots of the wallet units (wallet_unit.trust_anchors_dir): with a
# ConfigMap, the service, config and worker files name the folder and their
# pods mount the ConfigMap's two root files; the clock never does. Without
# one, no file names the folder (the image's roots apply).
trust_anchors() {
  local name="$1" expect="$2"; shift 2
  local problems
  # Only stdout is YAML (helm writes its warnings to stderr).
  if ! helm template t "$chart" --namespace ow -f "$keys" "${all[@]}" "$@" > "$out/anchors.yaml" 2> "$out/anchors.err"; then
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
trust_anchors "image roots by default" '{"configmap": null}'
trust_anchors "roots from a ConfigMap" '{"configmap": "test-roots"}' \
  --set organisationWallet.walletUnit.trustAnchors.existingConfigMap=test-roots
# Installation limits: Limits.maxOrganisations in the api and webhook files
# (api.limits.maxOrganisations) and wallet_unit.organisation_wallet_units_max
# in the service, config and worker files
# (organisationWallet.walletUnit.organisationWalletUnitsMax), as integers,
# only when a value is set: an api or wallet from a release before the input
# limits refuses the keys. No other object has them: not the gateway file
# (the gateway refuses the section), the clock, the hooks or the Jobs.
installation_limits() {
  local name="$1" expect="$2"; shift 2
  local problems
  # Only stdout is YAML (helm writes its warnings to stderr).
  if ! helm template t "$chart" --namespace ow -f "$keys" "${all[@]}" "$@" > "$out/limits.yaml" 2> "$out/limits.err"; then
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
installation_limits "no key by default" '{"organisations": null, "units": null}'
installation_limits "no key with empty values" '{"organisations": null, "units": null}' \
  --set api.limits.maxOrganisations= --set organisationWallet.walletUnit.organisationWalletUnitsMax=
installation_limits "the two limits" '{"organisations": 50, "units": 60}' \
  --set api.limits.maxOrganisations=50 --set organisationWallet.walletUnit.organisationWalletUnitsMax=60
installation_limits "only the organisation limit" '{"organisations": 40, "units": null}' --set api.limits.maxOrganisations=40
installation_limits "only the organisation wallet unit limit" '{"organisations": null, "units": 40}' \
  --set organisationWallet.walletUnit.organisationWalletUnitsMax=40
# A values file gives numbers as floats: the files must have the integer,
# not 1e+06.
installation_limits "the largest limits as JSON numbers" '{"organisations": 100, "units": 100}' \
  --set-json 'api.limits={"maxOrganisations": 100}' --set-json 'organisationWallet.walletUnit.organisationWalletUnitsMax=100'
guard "organisation limit 0" "api.limits.maxOrganisations" --set api.limits.maxOrganisations=0
guard "organisation limit over 100" "api.limits.maxOrganisations" --set api.limits.maxOrganisations=101
guard "organisation limit as a string" "api.limits.maxOrganisations" --set-string api.limits.maxOrganisations=50
guard "organisation wallet unit limit 0" "organisationWallet.walletUnit.organisationWalletUnitsMax" \
  --set organisationWallet.walletUnit.organisationWalletUnitsMax=0
guard "organisation wallet unit limit over 100" "organisationWallet.walletUnit.organisationWalletUnitsMax" \
  --set organisationWallet.walletUnit.organisationWalletUnitsMax=101
guard "organisation wallet unit limit as a string" "organisationWallet.walletUnit.organisationWalletUnitsMax" \
  --set-string organisationWallet.walletUnit.organisationWalletUnitsMax=50
# Development builds of the wallet apps (developmentAppsAllowed): no key by
# default (the wallet default is false); when set, the boolean is in the
# files with a wallet_unit section (service, config, workers), never in the
# clock file. A string, even "true", stops the render.
development_apps() {
  local name="$1" expect="$2"; shift 2
  local problems
  if problems="$(helm template t "$chart" --namespace ow -f "$keys" "${all[@]}" "$@" \
      --show-only templates/wallet/configmap.yaml 2>&1 | python3 -c '
import json, sys, yaml
expect = json.loads(sys.argv[1])
data = yaml.safe_load(sys.stdin)["data"]
roles = 0
for key, text in sorted(data.items()):
    if not key.endswith(".yaml"):
        continue
    config = yaml.safe_load(text) or {}
    unit = config.get("wallet_unit")
    if key == "clock.yaml":
        if unit is not None:
            print("clock.yaml has wallet_unit")
        continue
    roles += 1
    got = (unit or {}).get("development_apps_allowed", "absent")
    if got != expect:
        print(f"{key}: development_apps_allowed {got!r}, expected {expect!r}")
if roles < 3:
    print("files with wallet_unit:", roles)
' "$expect" 2>&1)" && [ -z "$problems" ]; then
    ok "development apps: $name"
  else
    bad "development apps: $name: $(printf '%s' "$problems" | head -c 300)"
  fi
}
development_apps "no key by default" '"absent"'
development_apps "true in the service, config and worker files" 'true' --set organisationWallet.walletUnit.developmentAppsAllowed=true
development_apps "false in the service, config and worker files" 'false' --set organisationWallet.walletUnit.developmentAppsAllowed=false
guard "development apps as a text" "organisationWallet.walletUnit.developmentAppsAllowed" --set-string organisationWallet.walletUnit.developmentAppsAllowed=true
guard "development apps as a text without the schema" 'organisationWallet.walletUnit.developmentAppsAllowed ("true") must be true, false or empty' --skip-schema-validation --set-string organisationWallet.walletUnit.developmentAppsAllowed=true
# Installed services (docs/components.md): Installation.services is in the
# api, webhook and gateway files only when a service is not installed, and
# that service has no upstream, object, read user, trust, NATS user or
# Valkey user (tests/check_installation.py). A release without a service
# needs none of its keys: the cases remove its public keys and NATS users.
# Each case is also an install (tests/check_hook_order.py) and, with network
# policies, a network matrix check (tests/check_network_matrix.py).
no_consent=(--set consent.enabled=false)
no_wallet=(--set organisationWallet.enabled=false --set organisationWallet.host= --set serviceKeys.publicJwks.eudi-wallet=null
  --set nats.auth.users.walletConfig=null --set nats.auth.users.walletService=null --set nats.auth.users.walletWorker=null)
installation() {
  local name="$1" case="$2"; shift 2
  local file="$out/installation-${name// /-}.yaml" result good=1
  if ! result="$(helm template t "$chart" --namespace ow -f "$keys" "${all[@]}" "$@" 2>&1 > "$file")"; then
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
  if grep -q -x 'kind: NetworkPolicy' "$file" && ! network_matrix "$file" defaults; then
    good=0
  fi
  if [ "$good" = 1 ]; then ok "installation $name"; else bad "installation $name"; fi
}
installation "all services" all
installation "all services with network policies" all -f "$profiles/network-policies.yaml"
installation "consent of another release" consent-elsewhere --set consent.enabled=false --set gateway.upstreams.consent.url=http://consent.example.org
installation "the wallet of another release" wallet-elsewhere --set organisationWallet.enabled=false --set gateway.upstreams.walletConfig.url=http://wallet.example.org
installation "without consent" no-consent "${no_consent[@]}"
installation "without consent, network policies" no-consent "${no_consent[@]}" -f "$profiles/network-policies.yaml"
installation "without consent, external database" no-consent "${no_consent[@]}" -f "$profiles/database-external.yaml"
installation "without the wallet" no-wallet "${no_wallet[@]}"
installation "without the wallet, network policies" no-wallet "${no_wallet[@]}" -f "$profiles/network-policies.yaml"
installation "without the wallet, external database" no-wallet "${no_wallet[@]}" -f "$profiles/database-external.yaml"
# api.extraConfig and gateway.extraConfig cannot set a different list: the
# same services are accepted, and the files keep the chart's form.
installation "without consent, the same list in api.extraConfig" no-consent "${no_consent[@]}" \
  --set-json 'api.extraConfig.Installation={"services":["wallet"]}' --set-json 'gateway.extraConfig.Installation={"services":["wallet"]}'
installation "all services, the full list in api.extraConfig" all --set-json 'api.extraConfig.Installation={"services":["consent","wallet"]}'
guard "no service installed" "the installation has no service" --set consent.enabled=false --set organisationWallet.enabled=false
guard "privacy dashboard without consent" "privacyDashboard.enabled needs the consent service" "${no_consent[@]}" \
  --set privacyDashboard.enabled=true --set privacyDashboard.namespace=privacy-dashboards
guard "api.extraConfig.Installation that differs" "api.extraConfig.Installation names other services than this release (wallet, consent)" \
  --set-json 'api.extraConfig.Installation={"services":["wallet"]}'
guard "gateway.extraConfig.Installation that differs" "gateway.extraConfig.Installation names other services than this release (wallet)" "${no_consent[@]}" \
  --set-json 'gateway.extraConfig.Installation={"services":["wallet","consent"]}'
guard "api.extraConfig.Installation without services" "api.extraConfig.Installation names other services" "${no_consent[@]}" \
  --set-json 'api.extraConfig.Installation={}'
guard "without consent, the public keys of the wallet are still required" "serviceKeys.publicJwks.eudi-wallet" "${no_consent[@]}" \
  --set serviceKeys.publicJwks.eudi-wallet=null
guard "without the wallet, the public keys of consent are still required" "serviceKeys.publicJwks.igrant-consent-management" "${no_wallet[@]}" \
  --set serviceKeys.publicJwks.igrant-consent-management=null
audit "no bucket by default" '{"audit": {"retention_years": 7}, "bucket": null, "secrets": {}}'
s3=(--set organisationWallet.audit.bucket.name=example-audit --set organisationWallet.audit.bucket.endpoint=https://s3.example.org
    --set organisationWallet.audit.bucket.region=eu-west-1 --set organisationWallet.audit.bucket.accessKey.existingSecret=audit-bucket)
audit "s3 bucket with its access key" \
  '{"audit": {"retention_years": 7}, "bucket": {"type": "s3", "name": "example-audit", "endpoint": "https://s3.example.org", "region": "eu-west-1", "access_key_id_file": "/run/secrets/eudi-wallet/audit-bucket-access-key-id", "secret_access_key_file": "/run/secrets/eudi-wallet/audit-bucket-secret-access-key"}, "secrets": {"audit-bucket-access-key-id": ["audit-bucket", "access-key-id"], "audit-bucket-secret-access-key": ["audit-bucket", "secret-access-key"]}}' \
  "${s3[@]}"
audit "s3 bucket with a prefix and the store's CA" \
  '{"audit": {"retention_years": 10, "scope_retention_years": {"kms": 12}}, "bucket": {"type": "s3", "name": "example-audit", "prefix": "audit/production/", "endpoint": "https://s3.example.org", "region": "eu-west-1", "access_key_id_file": "/run/secrets/eudi-wallet/audit-bucket-access-key-id", "secret_access_key_file": "/run/secrets/eudi-wallet/audit-bucket-secret-access-key", "ca_file": "/run/secrets/eudi-wallet/audit-bucket-ca.crt"}, "secrets": {"audit-bucket-access-key-id": ["audit-bucket", "id"], "audit-bucket-secret-access-key": ["audit-bucket", "secret"], "audit-bucket-ca.crt": ["store-ca", "ca.pem"]}}' \
  "${s3[@]}" --set organisationWallet.audit.retentionYears=10 --set organisationWallet.audit.scopeRetentionYears.kms=12 \
  --set organisationWallet.audit.bucket.prefix=audit/production/ --set organisationWallet.audit.bucket.accessKey.idKey=id \
  --set organisationWallet.audit.bucket.accessKey.secretKey=secret --set organisationWallet.audit.bucket.ca.existingSecret=store-ca \
  --set organisationWallet.audit.bucket.ca.key=ca.pem
audit "gcs bucket with its service account" \
  '{"audit": {"retention_years": 7}, "bucket": {"type": "gcs", "name": "example_audit", "project": "example-project", "prefix": "audit/production/", "credentials_file": "/run/secrets/eudi-wallet/audit-bucket-service-account.json"}, "secrets": {"audit-bucket-service-account.json": ["audit-bucket", "sa.json"]}}' \
  --set organisationWallet.audit.bucket.type=gcs \
  --set organisationWallet.audit.bucket.name=example_audit --set organisationWallet.audit.bucket.project=example-project \
  --set organisationWallet.audit.bucket.prefix=audit/production/ --set organisationWallet.audit.bucket.credentials.existingSecret=audit-bucket \
  --set organisationWallet.audit.bucket.credentials.key=sa.json
audit "gcs bucket with the Google default credentials" '{"audit": {"retention_years": 7}, "bucket": {"type": "gcs", "name": "example-audit"}, "secrets": {}}' \
  --set organisationWallet.audit.bucket.type=gcs --set organisationWallet.audit.bucket.name=example-audit
for value in credentials accessKey ca; do
  guard "audit bucket $value without bucket name" "organisationWallet.audit.bucket.$value.existingSecret needs organisationWallet.audit.bucket.name" \
    --set "organisationWallet.audit.bucket.$value.existingSecret=audit-bucket"
done
guard "audit bucket of type s3 without endpoint" "set organisationWallet.audit.bucket.type: gcs" \
  --set organisationWallet.audit.bucket.name=example-audit
guard "audit bucket of type s3 without region" "organisationWallet.audit.bucket.region is required" \
  "${s3[@]}" --set organisationWallet.audit.bucket.region=
guard "audit bucket of type s3 without access key" "organisationWallet.audit.bucket.accessKey.existingSecret is required" \
  "${s3[@]}" --set organisationWallet.audit.bucket.accessKey.existingSecret=
guard "audit bucket of type s3 with an invalid S3 bucket name" "is not an S3 bucket name" \
  "${s3[@]}" --set organisationWallet.audit.bucket.name=example_audit
guard "audit bucket of type s3 with gcs values" "are values of type gcs" \
  "${s3[@]}" --set organisationWallet.audit.bucket.project=example-project
guard "audit bucket of type gcs with s3 values" "are values of type s3" \
  "${s3[@]}" --set organisationWallet.audit.bucket.type=gcs --set organisationWallet.audit.bucket.accessKey.existingSecret=
guard "audit bucket type" "organisationWallet.audit.bucket.type" --set organisationWallet.audit.bucket.type=minio
guard "audit bucket endpoint" "organisationWallet.audit.bucket.endpoint" "${s3[@]}" --set organisationWallet.audit.bucket.endpoint=https://s3.example.org/audit
guard "audit bucket name" "organisationWallet.audit.bucket.name" --set organisationWallet.audit.bucket.name=Audit_Bucket
guard "audit bucket prefix" "organisationWallet.audit.bucket.prefix" "${s3[@]}" --set organisationWallet.audit.bucket.prefix=/audit
guard "audit retention of at least one year" "organisationWallet.audit.retentionYears" --set organisationWallet.audit.retentionYears=0
guard_property_name "audit retention of a scope without an audit log" "organisationWallet.audit.scopeRetentionYears" events --set organisationWallet.audit.scopeRetentionYears.events=3
# The wallet provider split replaced the scope wallet_provider with
# individual_wallet_provider and business_wallet_provider.
guard_property_name "audit retention of the old wallet provider scope" "organisationWallet.audit.scopeRetentionYears" wallet_provider --set organisationWallet.audit.scopeRetentionYears.wallet_provider=10
renders "audit retention of the individual wallet provider scope" "individual_wallet_provider: 10" --set organisationWallet.audit.scopeRetentionYears.individual_wallet_provider=10
renders "audit retention of the business wallet provider scope" "business_wallet_provider: 12" --set organisationWallet.audit.scopeRetentionYears.business_wallet_provider=12
guard "retention purge batch size" "organisationWallet.retention.batchSize" --set organisationWallet.retention.batchSize=20000
renders "retention purge of a deactivated sandbox" "deactivated_sandbox_days: 14" --set organisationWallet.retention.deactivatedSandboxDays=14
renders "issued credential token retention" "issued_credential_token_days: 90" --set organisationWallet.retention.issuedCredentialTokenDays=90 --show-only templates/wallet/configmap.yaml
guard "issued credential token retention" "organisationWallet.retention.issuedCredentialTokenDays" --set organisationWallet.retention.issuedCredentialTokenDays=0

renders "local backend openbao by default" "local_backend: openbao"
# The longest wallet database name: 43 characters.
renders "wallet database name of 43 characters" "user: w234567890123456789012345678901234567890123_launcher_app" --set database.databases.wallet.name=w234567890123456789012345678901234567890123
# The WIA pool refill is a worker actor, not a NATS event.
lacks "no WIA pool refill event" "ows.wia_pool.refill_requested"
# A value in database.postgresql.parameters wins over a log parameter from
# database.postgresql.logDdlAndConnections: one -c per name.
renders "server parameter wins over a database log parameter" '"log_statement=all"' --set database.postgresql.parameters.log_statement=all
lacks "database log parameter overridden by a server parameter" '"log_statement=ddl"' --set database.postgresql.parameters.log_statement=all

# Workers and clock (organisationWallet.workers, .clock, .serviceMonitor;
# docs/workers.md). Each case gives the full list of groups (a list value
# replaces the default list).
main_group='{"name":"main","queues":["realtime","attestation","status","kms"],"replicas":2,"processes":1,"threads":8,"shutdownTimeoutSeconds":600,"terminationGracePeriodSeconds":630}'
maintenance_group='{"name":"maintenance","queues":["maintenance"],"replicas":1,"processes":1,"threads":2,"shutdownTimeoutSeconds":14400,"terminationGracePeriodSeconds":14430}'
workers() { printf 'organisationWallet.workers.groups=[%s]' "$(IFS=,; printf '%s' "$*")"; }
guard "worker group name" "organisationWallet.workers.groups.0.name" --set-json "$(workers "${main_group/\"main\"/\"Main\"}" "$maintenance_group")"
guard "worker group name without the schema" 'organisationWallet.workers.groups[0].name "Main" is not a name' --skip-schema-validation --set-json "$(workers "${main_group/\"main\"/\"Main\"}" "$maintenance_group")"
guard "worker group name used twice" 'organisationWallet.workers.groups[1].name "main" is the name of another group' --set-json "$(workers "$main_group" "${maintenance_group/\"name\":\"maintenance\"/\"name\":\"main\"}")"
guard "worker Deployment name too long" "gives the Deployment name" --set fullnameOverride=ows-installation-of-the-production-site
guard "worker queue" "organisationWallet.workers.groups.1.queues.0" --set-json "$(workers "$main_group" "${maintenance_group/\[\"maintenance\"\]/[\"default\"]}")"
guard "worker queue without the schema" '"default" is not a queue of the wallet' --skip-schema-validation --set-json "$(workers "$main_group" "${maintenance_group/\[\"maintenance\"\]/[\"default\"]}")"
guard "worker queues empty without the schema" "organisationWallet.workers.groups[1].queues is empty" --skip-schema-validation --set-json "$(workers "$main_group" "${maintenance_group/\[\"maintenance\"\]/[]}")"
guard "worker queue listed twice without the schema" "organisationWallet.workers.groups[1].queues names a queue two times" --skip-schema-validation --set-json "$(workers "$main_group" "${maintenance_group/\[\"maintenance\"\]/[\"maintenance\",\"maintenance\"]}")"
guard "worker queue that no group runs" "no group runs the queue maintenance" --set-json "$(workers "$main_group")"
guard "worker grace period below the shutdown timeout" "terminationGracePeriodSeconds (14400) must be at least shutdownTimeoutSeconds (14400) + 30" --set-json "$(workers "$main_group" "${maintenance_group/14430/14400}")"
guard "worker replicas" "organisationWallet.workers.groups.0.replicas" --set-json "$(workers "${main_group/\"replicas\":2/\"replicas\":0}" "$maintenance_group")"
guard "worker replicas without the schema" "organisationWallet.workers.groups[0].replicas (0) must be 1 or more" --skip-schema-validation --set-json "$(workers "${main_group/\"replicas\":2/\"replicas\":0}" "$maintenance_group")"
guard "worker group without threads" "threads" --set-json "$(workers "${main_group/\"threads\":8,/}" "$maintenance_group")"
guard "clock replicas" "organisationWallet.clock.replicas" --set organisationWallet.clock.replicas=0
one_group='organisationWallet.workers.groups=[{"name":"all","queues":["realtime","attestation","status","kms","maintenance"],"replicas":1,"processes":2,"threads":4,"shutdownTimeoutSeconds":14400,"terminationGracePeriodSeconds":14430}]'
renders "one worker group for every queue" "name: t-wallet-worker-all" --set-json "$one_group"
renders "one worker group: its configuration key" "worker-all.yaml: |" --set-json "$one_group"
lacks "one worker group: no default group Deployments" "name: t-wallet-worker-main" --set-json "$one_group"
renders "clock replicas" "replicas: 3" --set organisationWallet.clock.replicas=3 --show-only templates/wallet/clock.yaml
renders "ServiceMonitor of the workers and the clock" "name: t-wallet-metrics" --set organisationWallet.serviceMonitor.enabled=true
# The wallet's SSRF allow list (organisationWallet.ssrf.allowedPrivate): no
# key by default (an image without the setting gets no unknown key); the
# entries in each wallet file; the render stops for a loopback or metadata
# network and for an entry that is not a host name, address or CIDR.
lacks "no SSRF allow list by default" "ssrf_protection" --show-only templates/wallet/configmap.yaml
renders "the SSRF allow list in the wallet files" "allowed_private:" --set-json 'organisationWallet.ssrf.allowedPrivate=["wallet.example.internal","10.20.0.0/16"]' --show-only templates/wallet/configmap.yaml
guard "no loopback in the SSRF allow list" "covers a loopback, link-local, metadata or unspecified address" --set-json 'organisationWallet.ssrf.allowedPrivate=["127.0.0.0/8"]'
guard "no metadata address in the SSRF allow list" "covers a loopback, link-local, metadata or unspecified address" --set-json 'organisationWallet.ssrf.allowedPrivate=["169.254.169.254"]'
guard "an SSRF allow entry is a host, an address or a CIDR" "organisationWallet.ssrf.allowedPrivate.0" --set-json 'organisationWallet.ssrf.allowedPrivate=["not a host"]'
# Alert rules (organisationWallet.prometheusRule; tests/alert-rules.sh runs
# them with promtool): none by default, and only with the ServiceMonitor.
lacks "no PrometheusRule by default" "kind: PrometheusRule" --set organisationWallet.serviceMonitor.enabled=true
renders "wallet PrometheusRule: a missing partition of the month is critical" "alert: PartitionOfTheMonthMissing" --set organisationWallet.serviceMonitor.enabled=true --set organisationWallet.prometheusRule.enabled=true --show-only templates/wallet/prometheusrule.yaml
renders "wallet PrometheusRule: labels for the rule selector" "release: kube-prometheus" --set organisationWallet.serviceMonitor.enabled=true --set organisationWallet.prometheusRule.enabled=true --set-json 'organisationWallet.prometheusRule.labels={"release":"kube-prometheus"}' --show-only templates/wallet/prometheusrule.yaml
guard "PrometheusRule without the ServiceMonitor" "organisationWallet.prometheusRule needs organisationWallet.serviceMonitor.enabled" --set organisationWallet.prometheusRule.enabled=true
# Servers (service and config): a headless Service for the metrics port
# (9190) with the job wallet-server; the ServiceMonitor takes the job name
# from the label metrics.igrant.io/job.
renders "metrics Service of the service role" "name: t-wallet-service-metrics" --set organisationWallet.serviceMonitor.enabled=true --show-only templates/wallet/servicemonitor.yaml
renders "metrics Service of the config role" "name: t-wallet-config-metrics" --set organisationWallet.serviceMonitor.enabled=true --show-only templates/wallet/servicemonitor.yaml
renders "job label value of the server targets" "metrics.igrant.io/job: wallet-server" --set organisationWallet.serviceMonitor.enabled=true --show-only templates/wallet/servicemonitor.yaml
renders "job label of the ServiceMonitor" "jobLabel: metrics.igrant.io/job" --set organisationWallet.serviceMonitor.enabled=true --show-only templates/wallet/servicemonitor.yaml
renders "scrape interval of the servers" "interval: 15s" --set organisationWallet.serviceMonitor.enabled=true --show-only templates/wallet/servicemonitor.yaml
lacks "no metrics port in the route Services" "9190" --show-only templates/wallet/svc.yaml
renders "worker group metrics Service includes pods that are not ready" "publishNotReadyAddresses: true" --set organisationWallet.serviceMonitor.enabled=true --show-only templates/wallet/servicemonitor.yaml
# Scrape ports, open only to the monitoring namespace
# (networkPolicy.monitoring): the health port of the workers and the clock
# (/metrics), and the metrics port of the servers.
if problems="$(helm template t "$chart" --namespace ow -f "$keys" "${all[@]}" -f "$profiles/network-policies.yaml" \
    --set networkPolicy.monitoring.enabled=true --set-json 'networkPolicy.monitoring.namespaceSelector={"matchLabels":{"kubernetes.io/metadata.name":"monitoring"}}' \
    --show-only templates/networkpolicy/policies.yaml 2>&1 | python3 -c '
import sys, yaml
docs = {d["metadata"]["name"]: d for d in yaml.safe_load_all(sys.stdin) if d}
for role in ("wallet-service", "wallet-config"):
    rules = docs[f"t-netpol-ingress-{role}"]["spec"]["ingress"]
    scrape = [r for r in rules if [p["port"] for p in r.get("ports", [])] == ["metrics"]]
    peers = [p for r in scrape for p in r.get("from", [])]
    if not peers or any(p.get("namespaceSelector") != {"matchLabels": {"kubernetes.io/metadata.name": "monitoring"}} for p in peers):
        print(f"{role}: the metrics port is not open only to the monitoring namespace: {scrape}")
' 2>&1)" && [ -z "$problems" ]; then
  ok "scrape of the servers with network policies"
else
  bad "scrape of the servers with network policies: $(printf '%s' "$problems" | head -c 300)"
fi
renders "scrape of the workers and the clock with network policies" "port: health" -f "$profiles/network-policies.yaml" \
  --set networkPolicy.monitoring.enabled=true --set-json 'networkPolicy.monitoring.namespaceSelector={"matchLabels":{"kubernetes.io/metadata.name":"monitoring"}}' \
  --show-only templates/networkpolicy/policies.yaml
lacks "no scrape of the workers and the clock without the monitoring namespace" "port: health" -f "$profiles/network-policies.yaml" \
  --show-only templates/networkpolicy/policies.yaml
# DNS servers outside the pod network (networkPolicy.dns.cidrs): an ipBlock
# next to the DNS pods in the DNS policy; none by default.
dns_policy() {
  local name="$1" expect="$2"; shift 2
  local problems
  if problems="$(helm template t "$chart" --namespace ow -f "$keys" "${all[@]}" -f "$profiles/network-policies.yaml" \
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
# Egress to the public internet (to work with other vendors): 0.0.0.0/0 and
# ::/0, each with the exceptions of its family (also those of
# networkPolicy.clusterCidrs); the api, the webhook handler, consent and the
# wallet roles reach any port by default. IPv6: no multicast, and in the
# NAT64 prefix 64:ff9b::/96 only the images of IPv4 ranges that are never
# public are closed: a public IPv4 vendor through NAT64 (an IPv6-only
# cluster with DNS64) stays open, the NAT64 images of private, loopback or
# metadata addresses are closed. No IPv4-mapped address (the API server
# refuses it).
if problems="$(helm template t "$chart" --namespace ow -f "$keys" "${all[@]}" -f "$profiles/network-policies.yaml" \
    --set-json 'networkPolicy.clusterCidrs=["10.0.0.0/8","fd00:10::/56"]' 2>&1 | python3 -c '
import sys, yaml
import ipaddress
want = {"0.0.0.0/0": ["10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "100.64.0.0/10", "169.254.0.0/16"],
        "::/0": ["fc00::/7", "fe80::/10", "ff00::/8", "64:ff9b::a00:0/104", "64:ff9b::ac10:0/108", "64:ff9b::c0a8:0/112",
                 "64:ff9b::6440:0/106", "64:ff9b::a9fe:0/112", "64:ff9b::7f00:0/104", "64:ff9b::/104", "fd00:10::/56"]}
# address: open (True) or closed (False) in each internet profile
probes = {"93.184.215.14": True, "2001:db8:ffff::1": True, "64:ff9b::5db8:d70e": True, "64:ff9b::808:808": True,
          "64:ff9b::a00:1": False, "64:ff9b::ac1f:ffff": False, "64:ff9b::c0a8:101": False, "64:ff9b::6440:1": False,
          "64:ff9b::a9fe:a9fe": False, "64:ff9b::7f00:1": False, "64:ff9b::1": False, "ff02::1": False,
          "fd00:10::5": False, "fe80::1": False, "10.1.2.3": False, "169.254.169.254": False}
def is_open(blocks, address):
    address = ipaddress.ip_address(address)
    return any(address in ipaddress.ip_network(cidr) and not any(address in ipaddress.ip_network(e) for e in (excepts or []))
               for cidr, excepts in blocks.items() if ipaddress.ip_network(cidr).version == address.version)
seen, roles = {}, set()
for doc in yaml.safe_load_all(sys.stdin):
    if not doc:
        continue
    if doc.get("kind") == "NetworkPolicy" and doc["metadata"]["name"] in ("t-netpol-egress-profile-internet", "t-netpol-egress-profile-internet-any-port"):
        blocks = {peer["ipBlock"]["cidr"]: peer["ipBlock"].get("except") for peer in doc["spec"]["egress"][0]["to"]}
        if blocks != want:
            print(doc["metadata"]["name"], blocks)
        for address, expect in probes.items():
            if is_open(blocks, address) != expect:
                print(doc["metadata"]["name"], address, "open" if expect else "closed", "expected")
        mapped = [e for c in blocks.values() for e in (c or []) if ipaddress.ip_network(e).version == 6 and ipaddress.ip_network(e).network_address.ipv4_mapped]
        if mapped:
            print(doc["metadata"]["name"], "IPv4-mapped exceptions", mapped)
        seen[doc["metadata"]["name"]] = doc["spec"]["egress"][0].get("ports")
    labels = (((doc.get("spec") or {}).get("template") or {}).get("metadata") or {}).get("labels") or {}
    if labels.get("netpol.igrant.io/egress-internet-any-port") == "true":
        roles.add(labels["netpol.igrant.io/role"])
if seen.get("t-netpol-egress-profile-internet-any-port") is not None:
    print("internet-any-port has ports", seen.get("t-netpol-egress-profile-internet-any-port"))
if sorted(roles) != ["api", "consent", "wallet-config", "wallet-service", "wallet-worker", "webhook"]:
    print("roles with any port", sorted(roles))
' 2>&1)" && [ -z "$problems" ]; then
  ok "internet profiles: IPv4 and IPv6 with the exceptions of each family (NAT64: only the never-public images closed); any port for the api, webhook handler, consent and wallet roles"
else
  bad "internet profiles: $(printf '%s' "$problems" | head -c 400)"
fi
# The egress profile "platform" (this platform's public hosts): the pods of
# networkPolicy.ingressController are always a target; the wallet roles have
# the profile by default, the other roles do not.
platform_profile() {
  local name="$1" expect="$2"; shift 2
  local problems
  if problems="$(helm template t "$chart" --namespace ow -f "$keys" "${all[@]}" -f "$profiles/network-policies.yaml" \
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
envoy='{"namespaceSelector": {"matchLabels": {"kubernetes.io/metadata.name": "envoy-gateway-system"}}, "podSelector": {"matchLabels": {"app.kubernetes.io/component": "proxy", "app.kubernetes.io/name": "envoy", "gateway.envoyproxy.io/owning-gateway-name": "platform", "gateway.envoyproxy.io/owning-gateway-namespace": "envoy-gateway-system"}}}'
ingress_nginx='{"namespaceSelector": {"matchLabels": {"kubernetes.io/metadata.name": "ingress-nginx"}}, "podSelector": {}}'
platform_profile "the Envoy pods of the Gateway platform on 10080 and 10443, the load balancer ports 80 and 443, the wallet roles" \
  "{\"to\": [$envoy], \"ports\": [80, 443, 10080, 10443], \"roles\": [\"wallet-config\", \"wallet-service\", \"wallet-worker\"]}"
platform_profile "ingress-nginx (its profile) on 80 and 443" \
  "{\"to\": [$ingress_nginx], \"ports\": [80, 443], \"roles\": [\"wallet-config\", \"wallet-service\", \"wallet-worker\"]}" \
  -f "$profiles/exposure-ingress-nginx.yaml"
platform_profile "a load balancer address, other ports, also the webhook handler" \
  "{\"to\": [{\"ipBlock\": {\"cidr\": \"192.0.2.80/32\"}}, $envoy], \"ports\": [8000, 8443], \"roles\": [\"wallet-config\", \"wallet-service\", \"wallet-worker\", \"webhook\"]}" \
  --set-json 'networkPolicy.egress.profiles.platform={"cidrs":["192.0.2.80/32"],"ports":[8000,8443]}' \
  --set-json 'networkPolicy.egress.roles.webhook=["internet-any-port","platform"]'
guard "no platform profile for the clock" 'the egress profile "platform" is not allowed for the network role "wallet-clock"' --set-json 'networkPolicy.egress.roles.wallet-clock=["platform"]'
# The network matrix check with the Envoy pods refuses: the platform ports
# without 10080 and 10443, a selector of the whole namespace (the Envoy
# Gateway controller and the Envoy pods of other Gateways), and the profile
# platform for the api.
matrix_refuses() {
  local name="$1" expect="$2"; shift 2
  local result
  if ! helm template t "$chart" --namespace ow -f "$keys" "${all[@]}" -f "$profiles/network-policies.yaml" "$@" > "$out/matrix-mutant.yaml" 2>&1; then
    bad "network matrix refuses $name: helm template: $(head -c 200 "$out/matrix-mutant.yaml")"
  elif result="$(network_matrix "$out/matrix-mutant.yaml" defaults)"; then
    bad "network matrix refuses $name: the check passed"
  elif grep -q -F -- "$expect" <<< "$result"; then
    ok "network matrix refuses $name"
  else
    bad "network matrix refuses $name: no \"$expect\""
  fi
}
matrix_refuses "the platform ports without 10080 and 10443" \
  "the matrix connection wallet-service -> the Envoy pods of the Gateway platform:https (10443) is denied" \
  --set-json 'networkPolicy.egress.profiles.platform.ports=[80,443]'
matrix_refuses "a selector of the namespace only" \
  "the connection the Envoy Gateway controller -> gateway:http is allowed but not in the matrix" \
  --set-json 'networkPolicy.ingressController.podSelector.matchLabels=null'
matrix_refuses "the profile platform for the api" \
  "the connection api -> the Envoy pods of the Gateway platform:https (10443) is allowed but not in the matrix" \
  --set-json 'networkPolicy.egress.roles.api=["internet-any-port","smtp","platform"]'

# NATS 2.14, pinned by digest. The render stops for 2.15 and later (they
# send format v2 acks, the permissions use format v1). The routes of a NATS
# cluster use mutual TLS (verify).
renders "NATS 2.14.10 by digest" "image: docker.io/library/nats@sha256:311da47e2f31c26e99c623cd78d486a1e8ab039c49b32652770bb91a4f70512e"
guard "NATS 2.15 (format v2 acks)" "NATS 2.15 and later send the JetStream acks on subjects of the format v2" --set nats.image.tag=2.15.3-alpine
guard "NATS 3" "NATS 2.15 and later send the JetStream acks" --set nats.image.tag=3.0.0
renders "NATS with a custom tag without a version" "nats.conf" --set nats.image.tag=mirror --set nats.image.digest=
renders "NATS routes with mutual TLS" "verify: true" --set nats.replicas=3 --show-only templates/nats/configmap.yaml
# NATS TLS (nats.tls, nats.tlsCa), bundled and external.
guard "external NATS CA with the bundled NATS" "nats.tlsCa is the CA of an external NATS" --set nats.tlsCa.existingSecret=my-nats-ca
renders "NATS with your own certificate" "secretName: my-nats-tls" --set nats.tls.existingSecret=my-nats-tls --show-only templates/nats/statefulset.yaml
lacks "chart NATS TLS Secret with your own certificate" "name: t-nats-tls" --set nats.tls.existingSecret=my-nats-tls
external_nats=(--set nats.enabled=false --set nats.external.url=tls://nats.example.org:4222)
renders "external NATS with its CA" "name: my-nats-ca" "${external_nats[@]}" --set nats.tlsCa.existingSecret=my-nats-ca
lacks "external NATS: no chart TLS Secret" "t-nats-tls" "${external_nats[@]}" --set nats.tlsCa.existingSecret=my-nats-ca
lacks "external NATS without a CA: no CA file" "nats-ca.crt" "${external_nats[@]}"

# Lifetime of a stored command reply
# (organisationWallet.nats.commandReplySeconds): only in the config role file.
renders "command reply life of the config role" "command_reply_seconds: 900" --set organisationWallet.nats.commandReplySeconds=900
guard "command reply life" "organisationWallet.nats.commandReplySeconds" --set organisationWallet.nats.commandReplySeconds=119
# Write interval of the issuer status lists
# (organisationWallet.statusList.writeIntervalSeconds): only in the worker
# files (each render checks every file).
renders "status list write interval of the workers" "write_interval_seconds: 10" --set organisationWallet.statusList.writeIntervalSeconds=10 --show-only templates/wallet/configmap.yaml
renders "status list write interval 0" "write_interval_seconds: 0" --set organisationWallet.statusList.writeIntervalSeconds=0 --show-only templates/wallet/configmap.yaml
guard "status list write interval" "organisationWallet.statusList.writeIntervalSeconds" --set organisationWallet.statusList.writeIntervalSeconds=51
# Rate limit of the anonymous nonce routes (server.nonce_requests_per_minute).
renders "nonce limit of the server roles" "nonce_requests_per_minute: 300" --show-only templates/wallet/configmap.yaml
renders "nonce limit value" "nonce_requests_per_minute: 1200" --set organisationWallet.server.nonceRequestsPerMinute=1200 --show-only templates/wallet/configmap.yaml
guard "nonce limit" "organisationWallet.server.nonceRequestsPerMinute" --set organisationWallet.server.nonceRequestsPerMinute=0

# Wallet pools and api reader pools (database.pools).
guard "wallet pool size" "database.pools.walletService.poolSize" --set database.pools.walletService.poolSize=0
guard "worker pool overflow" "database.pools.walletWorker.maxOverflow" --set database.pools.walletWorker.maxOverflow=-1
guard "worker threads above the largest wallet pool" "organisationWallet.workers.groups.0.threads" --set-json "$(workers "${main_group/\"threads\":8/\"threads\":101}" "$maintenance_group")"
# Connection budget (docs/database.md, "Connection budget"): the release's
# pools, at the most pods of each Deployment, plus the hooks must fit in the
# bundled server's max_connections less its reserved connections.
renders "connection budget at the limit of the bundled server" "max_connections=233" --set database.postgresql.parameters.max_connections=233
guard "connection budget one over the limit" "can open 225 connections to the bundled database server" --set database.postgresql.parameters.max_connections=232
guard "connection budget counts the reserved connections" "less the 13 reserved connections" \
  --set database.postgresql.parameters.max_connections=233 --set-string database.postgresql.parameters.reserved_connections=10
guard "connection budget counts the replicas" "wallet config 3 x 36" --set organisationWallet.config.replicas=3 \
  --set database.postgresql.parameters.max_connections=233
renders "no connection budget check with an external server" "kind: StatefulSet" -f "$profiles/database-external.yaml" --set api.replicas=20
# Connection pooler (database.pooler): the wallet files of processes with
# sessions name it, and the budget counts its server connections instead of
# the wallet session pools.
pooler=(--set database.pooler.host=pgbouncer.ow.svc --set database.pooler.serverConnections=40)
renders "pooler in the wallet files" "host: pgbouncer.ow.svc" "${pooler[@]}" --show-only templates/wallet/configmap.yaml
lacks "no pooler without its host" "pooler" --show-only templates/wallet/configmap.yaml
if problems="$(helm template t "$chart" --namespace ow -f "$keys" "${all[@]}" "${pooler[@]}" \
    --show-only templates/wallet/configmap.yaml 2>&1 | python3 -c '
import sys, yaml
data = yaml.safe_load(sys.stdin)["data"]
for key, text in sorted(data.items()):
    pooler = yaml.safe_load(text)["database"].get("pooler")
    want = None if key == "clock.yaml" else {"host": "pgbouncer.ow.svc", "port": 6432}
    if pooler != want:
        print(f"{key}: database.pooler is {pooler!r}, not {want!r}")
' 2>&1)" && [ -z "$problems" ]; then
  ok "pooler: in every wallet file with sessions, not in the clock file"
else
  bad "pooler: $(printf '%s' "$problems" | tr '\n' ';' | head -c 300)"
fi
guard "pooler without its server connections" "database.pooler.serverConnections is required" --set database.pooler.host=pgbouncer.ow.svc
guard "pooler port" "database.pooler.port" "${pooler[@]}" --set database.pooler.port=0
guard "connection budget with a pooler counts its server connections" "connection pooler 1 x 40" "${pooler[@]}" --set database.postgresql.parameters.max_connections=100
renders "the session pool of a worker process follows its threads" "pool_size: 16" --set database.postgresql.parameters.max_connections=600 --set-json "$(workers "${main_group/\"threads\":8/\"threads\":16}" "$maintenance_group")" \
  --show-only templates/wallet/configmap.yaml
renders "api reader pool" "maxConns: 9" --set database.pools.apiReadAccess.maxConns=9 --show-only templates/api/configmap.yaml

# Valkey (redis.*): the schema and the template guards.
redis_sts() {
  local name="$1" expect="$2"; shift 2
  local text
  if ! text="$(helm template t "$chart" --namespace ow -f "$keys" "${all[@]}" "$@" --show-only templates/redis/statefulset.yaml 2>&1)"; then
    bad "Valkey pods $name: $(printf '%s' "$text" | head -c 200)"
  elif grep -q -F -- "$expect" <<< "$text"; then
    ok "Valkey pods $name"
  else
    bad "Valkey pods $name: no \"$expect\""
  fi
}
guard "redis mode" "redis.mode" --set redis.mode=cluster
guard "redis mode without the schema" 'redis.mode "cluster" is not supported' --skip-schema-validation --set redis.mode=cluster
guard "redis even replicas" "redis.replicas" --set redis.replicas=4
guard "redis even replicas without the schema" "redis.replicas (4) must be an odd number of 3 or more" --skip-schema-validation --set redis.replicas=4
guard "redis one replica" "redis.replicas" --set redis.replicas=1
guard "redis quorum above the replicas" "redis.sentinel.quorum (4) must be 1 to redis.replicas (3)" --set redis.sentinel.quorum=4
guard "redis maxmemory" "redis.maxmemory" --set redis.maxmemory=lots
guard "redis maxmemory without the schema" 'redis.maxmemory "lots" is not a size' --skip-schema-validation --set redis.maxmemory=lots
guard "redis master name" "redis.masterName" --set 'redis.masterName=my primary'
guard "redis user name" "redis.users.gateway.username" --set redis.users.gateway.username=-gw
guard "redis user shared by two processes" 'redis.users.walletConfig.username "wallet-service" is the user of another process' --set redis.users.walletConfig.username=wallet-service
guard "redis user name reserved by the bundled Valkey" 'redis.users.gateway.username "sentinel" is a user of the bundled Valkey' --set redis.users.gateway.username=sentinel
guard "redis unknown value" "Additional property" --set redis.cluster=true
guard "redis client timeout" "redis.client.timeoutSeconds" --set redis.client.timeoutSeconds=0
guard "redis replica wait" "redis.client.replicaWaitMilliseconds" --set redis.client.replicaWaitMilliseconds=20000
# The replica wait is at most half the timeout, in whole milliseconds (the
# wallet's exact rule: timeout_ms = round(timeoutSeconds x 1000), refused
# when 2 x wait > timeout_ms). The wallet's test vectors, also timeouts
# whose float product is not exact (2.01 x 1000 / 2 = 1004.9999999999999):
# each renders, and 1 ms more stops the render. A timeout with more than 3
# decimals stops the render (the schema, and the template without it).
# Without the wallet there is no check (only the wallet reads the wait).
replica_wait() {
  local seconds="$1" wait="$2" limit="$3"
  renders "redis replica wait $wait ms with $seconds s" "replica_wait_milliseconds: $wait" --set-json "redis.client.timeoutSeconds=$seconds" --set "redis.client.replicaWaitMilliseconds=$wait" --show-only templates/wallet/configmap.yaml
  guard "redis replica wait $((wait + 1)) ms with $seconds s" "redis.client.replicaWaitMilliseconds ($((wait + 1))) must be at most half of redis.client.timeoutSeconds ($seconds s = $limit ms), that is at most $wait ms" --set-json "redis.client.timeoutSeconds=$seconds" --set "redis.client.replicaWaitMilliseconds=$((wait + 1))"
}
replica_wait 2 1000 2000
replica_wait 2.01 1005 2010
replica_wait 2.03 1015 2030
replica_wait 4.02 2010 4020
replica_wait 8.03 4015 8030
replica_wait 0.5 250 500
renders "redis replica wait 10000 ms (the largest) with 20 s" "replica_wait_milliseconds: 10000" --set redis.client.timeoutSeconds=20 --set redis.client.replicaWaitMilliseconds=10000 --show-only templates/wallet/configmap.yaml
replica_wait 0.003 1 3
guard "redis replica wait of 10000 ms with 19 s" "redis.client.replicaWaitMilliseconds (10000) must be at most half of redis.client.timeoutSeconds (19 s = 19000 ms), that is at most 9500 ms" --set redis.client.timeoutSeconds=19 --set redis.client.replicaWaitMilliseconds=10000
guard "redis timeout with 4 decimals" "redis.client.timeoutSeconds" --set-json redis.client.timeoutSeconds=2.0005
guard "redis timeout with 4 decimals without the schema" "redis.client.timeoutSeconds (2.0005) has more than 3 decimals" --skip-schema-validation --set-json redis.client.timeoutSeconds=2.0005
renders "redis replica wait without the wallet" "kind: Deployment" --set organisationWallet.enabled=false --set redis.client.timeoutSeconds=2 --set redis.client.replicaWaitMilliseconds=1001
external_redis=(-f "$profiles/redis-external.yaml")
guard "external redis without sentinels or address" "redis.external" "${external_redis[@]}" --set-json 'redis.external.sentinels=[]'
guard "external redis without sentinels or address without the schema" "redis.external.sentinels or redis.external.address is required" "${external_redis[@]}" --skip-schema-validation --set-json 'redis.external.sentinels=[]'
guard "external redis with sentinels and address" "redis.external" "${external_redis[@]}" --set redis.external.address=redis.example.org:6379
guard "external redis with sentinels and address without the schema" "set redis.external.sentinels or redis.external.address, not both" "${external_redis[@]}" --skip-schema-validation --set redis.external.address=redis.example.org:6379
guard "external redis user without password Secret" "redis.users.gateway" "${external_redis[@]}" --set redis.users.gateway.passwordSecret=
guard "external redis user without password Secret without the schema" "redis.users.gateway.passwordSecret is required with redis.mode external" "${external_redis[@]}" --skip-schema-validation --set redis.users.gateway.passwordSecret=
guard "external redis Sentinel without port" "redis.external.sentinels" "${external_redis[@]}" --set-json 'redis.external.sentinels=["redis-1.example.org"]'
guard "external redis Sentinel without port without the schema" '"redis-1.example.org" is not host:port' "${external_redis[@]}" --skip-schema-validation --set-json 'redis.external.sentinels=["redis-1.example.org"]'
guard "external redis with network policies without addresses" "networkPolicy.externalRedis needs the addresses" "${external_redis[@]}" -f "$profiles/network-policies.yaml" --set-json 'networkPolicy.externalRedis=[]'
redis_sts "with redis.affinity" "requiredDuringSchedulingIgnoredDuringExecution" \
  --set-json 'redis.affinity={"podAntiAffinity":{"requiredDuringSchedulingIgnoredDuringExecution":[{"topologyKey":"kubernetes.io/hostname","labelSelector":{"matchLabels":{"app.kubernetes.io/component":"redis"}}}]}}'
redis_sts "with a user's password Secret" "name: my-redis-wallet-service" --set redis.users.walletService.passwordSecret=my-redis-wallet-service
redis_sts "with your own certificate" "secretName: my-redis-tls" --set redis.tls.existingSecret=my-redis-tls
redis_sts "with 5 pods" "t-redis-4.t-redis-headless.ow.svc" --set redis.replicas=5 --set redis.sentinel.quorum=3
lacks "chart Valkey TLS Secret with your own certificate" "name: t-redis-tls" --set redis.tls.existingSecret=my-redis-tls
renders "redis maxmemory" "maxmemory 1gb" --set redis.maxmemory=1gb
renders "redis 5 Sentinels in the wallet file" "- t-redis-4.t-redis-headless.ow.svc:26379" --set redis.replicas=5 --set redis.sentinel.quorum=3
renders "external redis address" "address: redis.example.org:6379" "${external_redis[@]}" --set-json 'redis.external.sentinels=[]' --set redis.external.address=redis.example.org:6379
lacks "external redis address without the Sentinel login" "sentinel_username" "${external_redis[@]}" --set-json 'redis.external.sentinels=[]' --set redis.external.address=redis.example.org:6379
lacks "external redis Sentinels without a login" "sentinel_username" "${external_redis[@]}" --set redis.external.sentinelAuth=false
lacks "external redis without CA (uses the system CAs)" "redis-ca.crt" "${external_redis[@]}" --set redis.external.caSecret=
lacks "no Valkey without the wallet and the api" "t-redis" --set organisationWallet.enabled=false --set api.enabled=false

# Bundled Valkey metrics (redis.metrics): the exporter in each pod with the
# ACL user metrics, its password, the ServiceMonitor, and the scrape port
# open only to the monitoring namespace.
metrics=(--set redis.metrics.enabled=true)
redis_sts "with the exporter" "--redis.user=metrics" "${metrics[@]}"
redis_sts "the exporter reads no CONFIG" "--config-command=-" "${metrics[@]}"
redis_sts "the exporter gets only the CA" "mountPath: /etc/valkey-metrics" "${metrics[@]}"
renders "the ACL user metrics" "user metrics on {hash:metrics} -@all +info +client|setname +slowlog|len +latency|latest +latency|histogram" "${metrics[@]}"
renders "the password of the user metrics" "  metrics: " "${metrics[@]}" --show-only templates/secrets.yaml
lacks "no exporter by default" "redis_exporter"
lacks "no ACL user metrics by default" "user metrics on"
lacks "no password of the user metrics by default" "  metrics: " --show-only templates/secrets.yaml
renders "Valkey ServiceMonitor" "name: t-redis-metrics" "${metrics[@]}" --set redis.metrics.serviceMonitor.enabled=true
lacks "no Valkey ServiceMonitor without its value" "t-redis-metrics" "${metrics[@]}"
renders "Valkey scrape with network policies" "port: metrics" -f "$profiles/network-policies.yaml" \
  --set networkPolicy.monitoring.enabled=true --set-json 'networkPolicy.monitoring.namespaceSelector={"matchLabels":{"kubernetes.io/metadata.name":"monitoring"}}' \
  --show-only templates/networkpolicy/policies.yaml
guard "redis ServiceMonitor without the exporter" "redis.metrics.serviceMonitor.enabled needs redis.metrics.enabled" --set redis.metrics.serviceMonitor.enabled=true
guard "redis metrics with an external Valkey" "redis.metrics is for the bundled Valkey" "${external_redis[@]}" "${metrics[@]}"
guard "redis user name metrics" 'redis.users.gateway.username "metrics" is a user of the bundled Valkey' --set redis.users.gateway.username=metrics

# The wallet's separate groups (redis.state, redis.cache): the guards; one
# endpoint per group in each wallet file; a group's CA in the wallet pods
# (not in the gateway); and egress to networkPolicy.externalRedis only for
# the wallet roles (also with the bundled Valkey).
guard "redis state without sentinels or address" "redis.state.sentinels or redis.state.address is required with redis.state.enabled" --set redis.state.enabled=true
guard "redis cache with sentinels and address" "set redis.cache.sentinels or redis.cache.address, not both" --set redis.cache.enabled=true \
  --set-json 'redis.cache.sentinels=["cache.example.org:26379"]' --set redis.cache.masterName=cache --set redis.cache.address=cache.example.org:6379
guard "redis state Sentinels without a master name" 'redis.state.masterName "" is not a name' --set redis.state.enabled=true \
  --set-json 'redis.state.sentinels=["state.example.org:26379"]'
guard "redis state address without port" "redis.state.address" --set redis.state.enabled=true --set redis.state.address=state.example.org
guard "redis state address without port without the schema" '"state.example.org" is not host:port' --skip-schema-validation \
  --set redis.state.enabled=true --set redis.state.address=state.example.org
guard "redis state with network policies without addresses" "networkPolicy.externalRedis needs the addresses of the group redis.state" \
  -f "$profiles/network-policies.yaml" --set redis.state.enabled=true --set redis.state.address=state.example.org:6379
groups=(--set redis.state.enabled=true --set-json 'redis.state.sentinels=["state-1.example.org:26379","state-2.example.org:26379"]'
  --set redis.state.masterName=state --set redis.state.caSecret=state-ca
  --set redis.cache.enabled=true --set redis.cache.address=cache.example.org:6380 --set redis.cache.sentinelAuth=false)
if ! helm template t "$chart" --namespace ow -f "$keys" "${all[@]}" -f "$profiles/network-policies.yaml" \
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
        print(f"{doc['metadata']['name']} does not mount the state group CA")
if any(path == "redis-state-ca.crt" for _, _, path in items(find("Deployment", "t-gateway"))):
    print("the gateway mounts the state group CA")
def egress_cidrs(role):
    doc = find("NetworkPolicy", f"t-netpol-egress-{role}")
    return {peer["ipBlock"]["cidr"] for rule in (doc or {}).get("spec", {}).get("egress", []) for peer in rule.get("to", []) if "ipBlock" in peer}
for role in ("wallet-service", "wallet-config", "wallet-worker", "wallet-clock"):
    if "198.51.100.0/24" not in egress_cidrs(role):
        print(f"the role {role} does not reach the separate groups")
for role in ("gateway", "redis"):
    if "198.51.100.0/24" in egress_cidrs(role):
        print(f"the role {role} reaches the wallet's separate groups")
PY
)" && [ -z "$problems" ]; then
  ok "Valkey groups: state and cache endpoints, their CA, wallet role egress"
else
  bad "Valkey groups"
  printf '%s\n' "$problems" | sed 's/^/  /' | head -10
fi
lacks "no state or cache endpoint by default" "redis-state-ca.crt"
# The api /tmp: an upload of 100 MiB with a 100Mi /tmp (and the memory
# limits for it); a 32 MiB body stays in memory, so a small /tmp is enough.
renders "api /tmp for uploads of 100 MiB" "sizeLimit: 100Mi" --set gateway.proxy.maxBodyBytes.file=104857600 \
  --set api.tmp.sizeLimit=100Mi --show-only templates/api/deploy.yaml
renders "api /tmp: a body of 32 MiB stays in memory" "sizeLimit: 1Mi" --set gateway.proxy.maxBodyBytes.file=33554432 \
  --set api.tmp.sizeLimit=1Mi --show-only templates/api/deploy.yaml
# api uploads (api.extraConfig Uploads and ImageUpload): the gateway file
# class must take the largest CSV import + 64 KiB, and the memory request +
# Uploads.maxInProgress x the largest file must fit below the api memory
# limit.
guard "gateway file class below the api CSV import limit" "must be at least the api Uploads.individualImportMaxFileBytes (20971520) + 65536" --set-json 'api.extraConfig={"Uploads":{"individualImportMaxFileBytes":20971520}}'
renders "CSV import of 20 MiB with the file class for it" "kind: Deployment" --set-json 'api.extraConfig={"Uploads":{"individualImportMaxFileBytes":20971520}}' --set gateway.proxy.maxBodyBytes.file=21037056
guard "gateway file class below the api image upload limit" "must be at least the api ImageUpload.maxBytes (104857600) + 65536" --set-json 'api.extraConfig={"ImageUpload":{"maxBytes":104857600}}' --set gateway.proxy.maxBodyBytes.file=104857600 --set api.tmp.sizeLimit=100Mi
guard "8 uploads of 100 MiB above the api memory limit" "Uploads.maxInProgress (8) x the largest upload file (104791040 bytes" --set-json 'api.extraConfig={"ImageUpload":{"maxBytes":104791040}}' --set gateway.proxy.maxBodyBytes.file=104857600 --set api.tmp.sizeLimit=100Mi
guard "too many uploads in progress for the api memory limit" "Uploads.maxInProgress (60) x the largest upload file (5242880 bytes" --set-json 'api.extraConfig={"Uploads":{"maxInProgress":60}}'
# CSV import limits in the dashboard config.json: the values of
# api.extraConfig.Uploads, as whole numbers, only when set; the render stops
# for a value that the api refuses at start; a change restarts the dashboard
# pods (config.json checksum).
lacks "no import limits in the dashboard config.json by default" "individualImport" --show-only templates/dashboard/configmap.yaml
renders "api import file limit in the dashboard config.json" '"individualImportMaxFileBytes": 10485760' --set-json 'api.extraConfig={"Uploads":{"individualImportMaxFileBytes":10485760,"individualImportMaxRows":9000}}' --set gateway.proxy.maxBodyBytes.file=11000000 --show-only templates/dashboard/configmap.yaml
renders "api import row limit in the dashboard config.json" '"individualImportMaxRows": 9000' --set-json 'api.extraConfig={"Uploads":{"individualImportMaxRows":9000}}' --show-only templates/dashboard/configmap.yaml
lacks "api default 0 not in the dashboard config.json" "individualImport" --set-json 'api.extraConfig={"Uploads":{"individualImportMaxRows":0}}' --show-only templates/dashboard/configmap.yaml
guard "import rows above 9000" "api.extraConfig.Uploads.individualImportMaxRows (9001) is not between 1 and 9000" --set-json 'api.extraConfig={"Uploads":{"individualImportMaxRows":9001}}'
guard "import file below 64 KiB" "api.extraConfig.Uploads.individualImportMaxFileBytes (1000) is not between 65536 and 20971520" --set-json 'api.extraConfig={"Uploads":{"individualImportMaxFileBytes":1000}}'
guard "import rows not a whole number" "api.extraConfig.Uploads.individualImportMaxRows (50.5) must be a whole number" --set-json 'api.extraConfig={"Uploads":{"individualImportMaxRows":50.5}}'
guard "import rows not a number" 'api.extraConfig.Uploads.individualImportMaxRows ("5k") is a text: give a number, not a text' --set-json 'api.extraConfig={"Uploads":{"individualImportMaxRows":"5k"}}'
guard "import rows as a text of digits" 'api.extraConfig.Uploads.individualImportMaxRows ("5000") is a text: give a number, not a text' --set-json 'api.extraConfig={"Uploads":{"individualImportMaxRows":"5000"}}'
guard "import file bytes as a text of digits" 'api.extraConfig.Uploads.individualImportMaxFileBytes ("5242880") is a text: give a number, not a text' --set-json 'api.extraConfig={"Uploads":{"individualImportMaxFileBytes":"5242880"}}'
guard "import rows as a text in a values file" 'api.extraConfig.Uploads.individualImportMaxRows ("5000") is a text' -f "$here/fixtures/import-rows-text.yaml"
if [ "$(helm template t "$chart" --namespace ow -f "$keys" "${all[@]}" --show-only templates/dashboard/deploy.yaml | grep 'checksum/config')" != \
     "$(helm template t "$chart" --namespace ow -f "$keys" "${all[@]}" --set-json 'api.extraConfig={"Uploads":{"individualImportMaxRows":7000}}' --show-only templates/dashboard/deploy.yaml | grep 'checksum/config')" ]; then
  ok "a new import limit restarts the dashboard pods (config.json checksum)"
else
  bad "a new import limit restarts the dashboard pods (config.json checksum)"
fi
renders "2 uploads of 100 MiB with a memory limit of 1Gi" "kind: Deployment" --set-json 'api.extraConfig={"ImageUpload":{"maxBytes":104791040},"Uploads":{"maxInProgress":2}}' --set gateway.proxy.maxBodyBytes.file=104857600 --set api.tmp.sizeLimit=100Mi --set api.resources.limits.memory=1Gi
# Writable paths of the pods that run as non-root with a read-only root
# file system: /tmp of each api, webhook, dashboard and wallet pod (64Mi, in
# memory except for the dashboard), /tmp and the socket folder of the
# bundled server, and the pid folder of NATS.
if ! helm template t "$chart" --namespace ow -f "$keys" "${all[@]}" > "$out/writable.yaml" 2> "$out/writable.err"; then
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
        for path, empty_dir in paths.items():
            if name == "t-nats" and container["name"] == "reloader" and path != "/var/run/nats":
                continue
            volume = volumes.get(mounts.get(path), {})
            if volume.get("emptyDir") != empty_dir:
                print(f"{name}:{container['name']}: {path} is {volume or 'not mounted'}, not the emptyDir {empty_dir}")
PY
)" && [ -z "$problems" ]; then
  ok "writable paths: emptyDir volumes of the pods with a read-only root file system"
else
  bad "writable paths"
  printf '%s\n' "$problems" | sed 's/^/  /' | head -10
fi

# The bundled NATS JetStream store: user and group 65532, fsGroup and
# OnRootMismatch, and no init container.
if ! helm template t "$chart" --namespace ow -f "$keys" "${all[@]}" \
    --show-only templates/nats/statefulset.yaml > "$out/nats-store.yaml" 2> "$out/nats-store.err"; then
  bad "NATS store: $(head -c 200 "$out/nats-store.err")"
elif problems="$(python3 - "$out/nats-store.yaml" <<'PY'
import sys, yaml
docs = {d["kind"]: d for d in yaml.safe_load_all(open(sys.argv[1])) if d}
spec = docs["StatefulSet"]["spec"]["template"]["spec"]
context = spec["securityContext"]
for key, value in (("runAsUser", 65532), ("runAsGroup", 65532), ("fsGroup", 65532), ("fsGroupChangePolicy", "OnRootMismatch")):
    if context.get(key) != value:
        print(f"the pod {key} is {context.get(key)!r}, not {value!r}")
if spec.get("initContainers"):
    print(f"init containers {[c['name'] for c in spec['initContainers']]}")
PY
)" && [ -z "$problems" ]; then
  ok "NATS store: user and group 65532, fsGroup, OnRootMismatch"
else
  bad "NATS store: $(printf '%s' "$problems" | tr '\n' ';' | head -c 300)"
fi

# global.podSecurityContext and global.containerSecurityContext: each pod
# and container gets the keys that its component does not set (here a
# cluster's SELinux options and supplemental groups); the component's own
# keys stay (runAsUser). The notes name each component whose own value sets
# a global key (in values.yaml, jobs without their own value use the
# component's value).
global_security=(--set-json 'global.podSecurityContext={"seLinuxOptions":{"level":"s0:c123,c456"},"supplementalGroups":[4321],"runAsUser":4242}'
  --set-json 'global.containerSecurityContext={"seLinuxOptions":{"type":"container_t"}}')
if ! helm template t "$chart" --namespace ow -f "$keys" "${all[@]}" -f "$here/values/operator-jobs-bootstrap.yaml" \
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
        print(f"{name}: the pod lacks the global keys: {context}")
    if context.get("runAsUser") in (None, 4242):
        print(f"{name}: runAsUser {context.get('runAsUser')} (the component's value must stay)")
    for container in spec.get("initContainers", []) + spec["containers"]:
        container_context = container.get("securityContext") or {}
        if container_context.get("seLinuxOptions") != {"type": "container_t"}:
            print(f"{name}:{container['name']}: the container lacks global.containerSecurityContext")
        if container_context.get("readOnlyRootFilesystem") is not True:
            print(f"{name}:{container['name']}: the container lost readOnlyRootFilesystem")
if pods < 25:
    print(f"only {pods} pod templates")
PY
)" && [ -z "$problems" ]; then
  ok "global security contexts: in each pod and container, below the component values"
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
    # A part of the component with its own pods (the jobs, where an empty
    # value means the component's value).
    for name, part in component.items():
        if isinstance(part, dict) and "podSecurityContext" in part:
            context = part["podSecurityContext"] or (component["podSecurityContext"] if name == "jobs" else {})
            if "runAsUser" in (context or {}):
                paths.append(f"{key}.{name}")
print(f"global.podSecurityContext.runAsUser does not apply to {', '.join(sorted(paths))}: the podSecurityContext of each sets runAsUser")
PY
)"
if ! text="$(helm template t "$notes_chart" --namespace ow -f "$keys" "${all[@]}" "${global_security[@]}" \
    --show-only templates/zz-test-notes.yaml 2>&1)"; then
  bad "global security contexts: notes: $(printf '%s' "$text" | head -c 200)"
elif grep -q -F -- "$expected" <<< "$text" && ! grep -q -F "global.podSecurityContext.supplementalGroups" <<< "$text" \
    && ! grep -q -F "global.podSecurityContext.seLinuxOptions" <<< "$text"; then
  ok "global security contexts: the notes name each component that sets a global key"
else
  bad "global security contexts: the notes lack \"$expected\" (or name a key that applies)"
fi

# Image pull Secrets (global.imagePullSecrets) in every pod spec: the
# Deployments, StatefulSets, Jobs and hooks, also the optional ones (the api
# operator Job, the Valkey metrics exporter).
if ! helm template t "$chart" --namespace ow -f "$keys" "${all[@]}" -f "$profiles/exposure-envoy-gateway.yaml" -f "$here/values/operator-jobs-bootstrap.yaml" \
    --set redis.metrics.enabled=true --set-json 'global.imagePullSecrets=["igrant-registry-creds","mirror-creds"]' \
    > "$out/pull-secrets.yaml" 2> "$out/pull-secrets.err"; then
  bad "image pull Secrets: helm template: $(head -c 200 "$out/pull-secrets.err")"
else
  result="$(python3 - "$out/pull-secrets.yaml" <<'PY'
import sys, yaml
want = {"igrant-registry-creds", "mirror-creds"}
pods = managers = 0
for d in yaml.safe_load_all(open(sys.argv[1])):
    if not d:
        continue
    kind = d["kind"]
    if kind in ("Deployment", "StatefulSet", "DaemonSet", "Job"):
        spec = d["spec"]["template"]["spec"]
    elif kind == "CronJob":
        spec = d["spec"]["jobTemplate"]["spec"]["template"]["spec"]
    elif kind == "Pod":
        spec = d["spec"]
    else:
        continue
    pods += 1
    names = {s["name"] for s in spec.get("imagePullSecrets") or []}
    if not want <= names:
        print(f"{kind} {d['metadata']['name']} has the image pull Secrets {sorted(names)}")
if pods < 20:
    print(f"only {pods} pod specs")
print(f"pods={pods}")
PY
)"
  if [ "$(printf '%s\n' "$result" | grep -c -v '^pods=')" = 0 ]; then
    ok "image pull Secrets in every pod spec ($(printf '%s' "$result" | sed -n 's/^pods=//p') pod specs)"
  else
    bad "image pull Secrets in every pod spec"
    printf '%s\n' "$result" | grep -v '^pods=' | sed 's/^/  /' | head -10
  fi
fi

# --- 6. Install and upgrade --------------------------------------------------------
# Hook order (tests/check_hook_order.py, no cluster): each hook Job finds
# its Secrets, ConfigMaps, databases and users when it starts, and each Job
# and pod finds its Secrets at the end.
# An install with one component off: no read access Job for a reader that is
# off (the read access Secret has no password for it).
install_order() {
  local name="$1" database="$2"; shift 2
  local case="$out/install-$database-${name// /-}"
  local args=(-f "$keys" "${all[@]}" -f "$profiles/exposure-envoy-gateway.yaml")
  [ "$database" = database-external ] && args+=(-f "$profiles/database-external.yaml")
  if ! helm template t "$chart" --namespace ow "${args[@]}" "$@" > "$case.yaml" 2> "$case.err"; then
    bad "install $name ($database): helm template"
    sed 's/^/  /' "$case.err" | head -5
  elif python3 "$here/check_hook_order.py" install "$case.yaml"; then
    ok "install $name ($database)"
  else
    bad "install $name ($database)"
  fi
}
# An upgrade from a release with the values of each case to a release with
# all components on.
upgrade_order() {
  local name="$1" database="$2"; shift 2
  local args=(-f "$keys" "${all[@]}"
    -f "$profiles/exposure-envoy-gateway.yaml")
  [ "$database" = database-external ] && args+=(-f "$profiles/database-external.yaml")
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
# An upgrade that turns a service off: from a release with all components
# on to a release with the values of each case.
upgrade_removes() {
  local name="$1" database="$2"; shift 2
  local args=(-f "$keys" "${all[@]}"
    -f "$profiles/exposure-envoy-gateway.yaml")
  [ "$database" = database-external ] && args+=(-f "$profiles/database-external.yaml")
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
for database in database-bundled database-external; do
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
done

# Hook Secrets (the database Secret, the read access Secret and the wallet
# role Secret) keep the values of the earlier release's Secrets. "helm
# template" has no cluster, so a copy of the chart reads the earlier Secrets
# from earlier-secrets.json instead of lookup (ow.lookupSecretKey). The
# earlier database Secret has no consent password (as in an upgrade that
# turns consent on): the render must create a new one.
lookup_chart="$out/lookup-chart"
rm -rf "$lookup_chart"
mkdir -p "$lookup_chart"
cp -R "$chart/Chart.yaml" "$chart/values.yaml" "$chart/values.schema.json" "$chart/templates" "$chart/files" "$chart/policies" "$lookup_chart/"
lookup_line='{{- $secret := lookup "v1" "Secret" $root.Release.Namespace (index . 1) -}}'
stub_line='{{- $secret := index ($root.Files.Get "earlier-secrets.json" | fromJson) (index . 1) -}}'
lookup_args=(-f "$keys" "${all[@]}")
if [ "$(grep -c -F -- "$lookup_line" "$lookup_chart/templates/_helpers.tpl")" != 1 ]; then
  bad "upgrade keeps the Secret values: ow.lookupSecretKey lacks the lookup line that the test replaces"
elif ! helm template t "$chart" --namespace ow "${lookup_args[@]}" --show-only templates/secrets.yaml > "$out/secrets-new.yaml" 2> "$out/secrets.err"; then
  bad "upgrade keeps the Secret values: $(head -c 200 "$out/secrets.err")"
else
  LOOKUP_LINE="$lookup_line" STUB_LINE="$stub_line" perl -pi -e 's/\Q$ENV{LOOKUP_LINE}\E/$ENV{STUB_LINE}/' "$lookup_chart/templates/_helpers.tpl"
  # The earlier Secrets: the keys of a new render with known test values
  # (not secrets), without the consent password.
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
    bad "upgrade keeps the Secret values: $(head -c 200 "$out/secrets.err")"
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
            print(f"the Secret {name} does not have the earlier value of {key}")
    for key in sorted(set(doc["data"]) - set(secret["data"])):
        if not doc["data"][key] or doc["data"][key] in secret["data"].values():
            print(f"the Secret {name} has no new value for {key}")
if "igrant_consent" not in rendered.get("t-postgres", {}).get("data", {}):
    print("the Secret t-postgres has no consent password")
' "$lookup_chart/earlier-secrets.json" "$out/secrets-kept.yaml" 2>&1)" && [ -z "$problems" ]; then
    ok "upgrade keeps the Secret values"
  else
    bad "upgrade keeps the Secret values: $(printf '%s' "$problems" | tr '\n' ';' | head -c 300)"
  fi
fi
# The bundled Valkey Secrets and the bundled NATS TLS Secret are normal
# resources (not hooks) and keep the earlier release's user passwords and
# certificates (the chart copy reads them from earlier-secrets.json). The
# earlier users Secret has no gateway password: the render must create a
# new one.
if [ "$(grep -c -F -- "$stub_line" "$lookup_chart/templates/_helpers.tpl")" != 1 ]; then
  bad "upgrade keeps the Valkey Secrets: the chart copy lacks the lookup stub"
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
            print(f"the Secret {name} does not have the earlier value of {key}")
gateway = rendered.get("t-redis-users", {}).get("data", {}).get("gateway")
if not gateway or gateway in earlier["t-redis-users"]["data"].values():
    print("the Secret t-redis-users has no new gateway password")
' "$lookup_chart/earlier-secrets.json" "$out/redis-kept.yaml" 2>&1)" && [ -z "$problems" ]; then
    ok "upgrade keeps the Valkey Secrets and the NATS TLS Secret"
  else
    bad "upgrade keeps the Valkey Secrets and the NATS TLS Secret: $(printf '%s' "$problems" | tr '\n' ';' | head -c 300)"
  fi
fi

# --- 7. The security settings of the containers -------------------------------
# Every container of every render in this run (the matrix, the other cases
# above, and one render with the optional containers: the Valkey metrics
# exporter and the api operator Jobs):
# - tests/check_security.py: a non-root user with a UID and GID other than
#   0, no privilege escalation, a read-only root file system, all
#   capabilities dropped and none added, not privileged, seccomp
#   RuntimeDefault, no host namespace, and the Pod Security Standard rules
#   for SELinux, AppArmor, procMount and hostProcess;
# - tests/psscheck: the Pod Security Standard "restricted" (latest, and
#   v1.30, the lowest Kubernetes version that the chart supports) with the
#   upstream library k8s.io/pod-security-admission, the admission plugin's
#   own code. It must count the same containers as check_security.py. It
#   needs Go (the version in tests/psscheck/go.mod) and the go.sum modules.
# Both checks must refuse a values mutant (tests/values/pss-mutant.yaml:
# AppArmor Unconfined, SELinux spc_t, procMount Unmasked, hostProcess) and
# each bad pod of tests/fixtures/pss-pods.yaml (also an ephemeral container
# and an AppArmor annotation, which the chart does not render).
if ! helm template t "$chart" --namespace ow -f "$keys" "${all[@]}" \
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
  bad "Pod Security Standard (upstream): Go is not installed; tests/psscheck needs the Go version in tests/psscheck/go.mod"
elif ! build="$(cd "$here/psscheck" && GOFLAGS=-mod=readonly go build -o "$psscheck" . 2>&1)"; then
  bad "Pod Security Standard (upstream): go build of tests/psscheck: $(printf '%s' "$build" | head -c 300)"
else
  if [ -z "$containers_of_test" ]; then
    bad "Pod Security Standard (upstream): no container count from check_security.py"
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
  # The values mutant: both checks refuse it, each for all four fields.
  if ! helm template t "$chart" --namespace ow -f "$keys" "${all[@]}" -f "$here/values/pss-mutant.yaml" \
      > "$out/mutants/pss-mutant.yaml" 2> "$out/mutants/pss-mutant.err"; then
    bad "both security checks refuse the mutant: helm template: $(head -c 200 "$out/mutants/pss-mutant.err")"
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
      ok "both security checks refuse the mutant (AppArmor, SELinux, procMount, hostProcess)"
    else
      bad "both security checks refuse the mutant: exit $python_status and $upstream_status;$missing"
    fi
  fi
  # The fixture pods: both checks name each bad pod, and neither names the
  # good pod.
  python_result="$(python3 "$here/check_security.py" "$here/fixtures/pss-pods.yaml" 2>&1)" || true
  upstream_result="$("$psscheck" -level restricted -version latest "$here/fixtures/pss-pods.yaml" 2>&1)" || true
  problems=""
  for pod in bad-apparmor-field bad-apparmor-annotation bad-selinux bad-procmount bad-hostprocess bad-ephemeral; do
    grep -q -F -- "Pod/$pod" <<< "$python_result" || problems="$problems check_security.py misses $pod;"
    grep -q -F -- "Pod/$pod" <<< "$upstream_result" || problems="$problems psscheck misses $pod;"
  done
  grep -q -F -- "Pod/good" <<< "$python_result$upstream_result" && problems="$problems a check refuses the good pod;"
  if [ -z "$problems" ]; then
    ok "security checks refuse each bad pod of tests/fixtures/pss-pods.yaml (also an ephemeral container and an AppArmor annotation), not the good pod"
  else
    bad "security checks of tests/fixtures/pss-pods.yaml:$problems"
  fi
fi

# Probes, hooks, rollout and stop of each render (tests/check_lifecycle.py):
# no exec probe or hook in an image without a shell, no exec of /bin/sleep,
# no initialDelaySeconds with a startup probe; each HTTP Deployment rolls
# with maxUnavailable 0, minReadySeconds and a preStop sleep, and its grace
# period covers the sleep and its server's stop. The check must refuse each
# bad pod of tests/fixtures/lifecycle-pods.yaml.
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
