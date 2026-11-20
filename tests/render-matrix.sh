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
#    tests/values/keys.yaml. A default choice has no file:
#      database   database-bundled (default), database-external
#      OpenBao    openbao-shamir, openbao-external
#      exposure   exposure-ingress-nginx, exposure-ingress-nginx-cert-manager,
#                 exposure-envoy-gateway, exposure-kgateway, exposure-none,
#                 exposure-on-premise
#      policies   none, network-policies
#    Each render goes through helm template, kubeconform -strict (if
#    installed; the Gateway API HTTPRoute schema comes from the CRDs
#    catalog), tests/check_render.py, tests/check_hook_order.py and
#    tests/check_installation.py; with network policies also
#    tests/check_network_matrix.py (the policies against
#    policies/network-matrix.yaml, with a model of the ingress controller
#    pods of the exposure: tests/fixtures/ingress-controller-pods.yaml).
#    helm lint runs once per database and OpenBao pair. More renders: the
#    bundled server with the DDL and connection logs off; your own Valkey or
#    Redis (redis-external) with both database choices, with and without
#    network policies; the minimal profile, with and without network
#    policies. Then the bundled Valkey and NATS certificates and the NATS
#    configuration. The tests after the matrix use
#    profiles/exposure-envoy-gateway.yaml where they pick an exposure. The
#    files of manifests/envoy-gateway/ go through kubeconform -strict.
# 3. The next steps (NOTES.txt).
# 4. Render guards: wrong values stop the render with a clear message
#    (values.schema.json and the template guards).
# 5. Rendered settings, also the services of the installation
#    (tests/check_installation.py); the user and
#    group of the NATS JetStream store; global.podSecurityContext and
#    global.containerSecurityContext below the component values.
# 6. Install and upgrade: tests/check_hook_order.py replays the Helm steps on
#    the renders (each matrix render is an install; an upgrade with the same
#    values and an upgrade that turns the database TLS on). Hook Secrets
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
# profiles/site.yaml with the release tag that the tests use, for the
# matrix (each render adds its OpenBao profile).
matrix_site=(-f "$profiles/site.yaml" -f "$here/values/release.yaml")
# The tests after the matrix: also the bundled OpenBao with the seal shamir
# (openbao.seal has no default).
site=("${matrix_site[@]}" -f "$profiles/openbao-shamir.yaml")
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
  # "serialization" module of the Python package cryptography, and the API
  # field "organization" in a request body of install.md. For the
  # vault check, these do not name the earlier key store product: the key
  # store type ids `vault`, external-vault and azure-key-vault, a list of
  # the types ([vault, ...]), the product name Azure Key Vault and its host
  # names (<vault>.vault.azure.net), and the local key store name that the
  # wallet and the dashboard show, in quotes ("Local vault").
  # The title and the rows of badges and links of README.md are HTML:
  # align="center" is a word of HTML, not of the text.
  hits="$(grep -n -i -E "$pattern" "$@" 2>/dev/null | grep -v -F 'tests/render-matrix.sh:' | grep -v -F 'tests/check_render.py:' \
    | grep -v -F 'tests/compose-files.sh:' \
    | grep -v -E '^[^:]*docs/install\.md:[0-9]+:.*"organization": "' \
    | grep -v -E '\.initialized|Initialized +true|"Initialized' \
    | grep -v -E '^[^:]*README\.md:[0-9]+:<(h1|p) align="center">$' \
    | grep -v -E '^[^:]*\.py:[0-9]+:.*(\bserialization\.|import .*\bserialization\b)' \
    | grep -v -E '^[^:]*:[0-9]+: +types: \[vault(, [a-z-]+)*\]$|^[^:]*values\.schema\.json:[0-9]+: +"(external-|azure-key-)?vault",?$' \
    | CHECK_WHAT="$what" perl -ne '($t = $_) =~ s/azure[- ]key[- ]vault|external-vault|`vault`|\[vault,|<vault>\.vault\.azure\.net|"local vault(?: \((?:hsm|openbao)\))?"//gi; print if $ENV{CHECK_WHAT} !~ /^no vault/ || $t =~ /vault/i' || true)"
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
# "defaults": the chart defaults, which select every pod of the namespace
# envoy-gateway-system.
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
    base=(-f "$keys" "${matrix_site[@]}" -f "$profiles/$openbao.yaml")
    [ "$database" = database-external ] && base+=(-f "$profiles/database-external.yaml")
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
        if ! python3 "$here/check_render.py" "$out/$name.yaml" "$(mode_of "$database")" \
            "${openbao#openbao-}" "$(exposure_of "$exposure")" "$([ "$policies" = network-policies ] && echo on || echo off)"; then
          good=0
        fi
        if ! python3 "$here/check_hook_order.py" install "$out/$name.yaml"; then
          good=0
        fi
        if ! result="$(python3 "$here/check_installation.py" "$out/$name.yaml" 2>&1)"; then
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
elif python3 "$here/check_render.py" "$out/$name.yaml" bundled shamir none off off; then
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
    if ! python3 "$here/check_render.py" "$out/$name.yaml" "$(mode_of "$database")" shamir gatewayAPI "$netpol" on external; then
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
# The size profiles (profiles/size-*.yaml, docs/sizing.md): each renders
# with the profiles of its size, passes helm lint and the install order, and
# fits its nodes:
# the requests (spread over the nodes) are
# at most 80 % of the allocatable of a node, a Deployment with a required
# anti-affinity has fewer replicas than nodes (a rolling update needs one
# more node), and a StatefulSet with a required anti-affinity has at most
# one pod on each node.
size_profile() {
  local name="$1" nodes="$2" cpu="$3" memory="$4"; shift 4
  local file="$out/size-$name.yaml" problems
  local args=(-f "$keys" "${matrix_site[@]}" -f "$profiles/exposure-envoy-gateway.yaml" "$@" -f "$profiles/size-$name.yaml")
  if ! helm lint "$chart" --quiet "${args[@]}" > "$out/lint.txt" 2>&1; then
    bad "size $name: helm lint"
    sed 's/^/  /' "$out/lint.txt" | head -10
    return
  fi
  if ! helm template t "$chart" --namespace ow "${args[@]}" > "$file" 2> "$out/size-$name.err"; then
    bad "size $name: helm template"
    sed 's/^/  /' "$out/size-$name.err" | head -10
    return
  fi
  if ! python3 "$here/check_hook_order.py" install "$file"; then
    bad "size $name: install order"
    return
  fi
  if problems="$(python3 - "$file" "$nodes" "$cpu" "$memory" <<'PY' 2>&1
import sys, yaml
def cpu(v):
    v = str(v or 0)
    return float(v[:-1]) / 1000 if v.endswith("m") else float(v)
def mem(v):
    v = str(v or 0)
    for suffix, factor in (("Ki", 1 / 1024 ** 2), ("Mi", 1 / 1024), ("Gi", 1)):
        if v.endswith(suffix):
            return float(v[:-2]) * factor
    return float(v) / 1024 ** 3
docs = [d for d in yaml.safe_load_all(open(sys.argv[1])) if d]
nodes, alloc_cpu, alloc_mem = int(sys.argv[2]), float(sys.argv[3]), float(sys.argv[4])
hpa = {d["spec"]["scaleTargetRef"]["name"]: d["spec"]["maxReplicas"] for d in docs if d["kind"] == "HorizontalPodAutoscaler"}
total_cpu = total_mem = 0.0
for d in docs:
    if d["kind"] not in ("Deployment", "StatefulSet"):
        continue
    spec = d["spec"]["template"]["spec"]
    def req(c, key):
        return ((c.get("resources") or {}).get("requests") or {}).get(key)
    pod_cpu = max(sum(cpu(req(c, "cpu")) for c in spec["containers"]), max([cpu(req(c, "cpu")) for c in spec.get("initContainers", [])] or [0]))
    pod_mem = max(sum(mem(req(c, "memory")) for c in spec["containers"]), max([mem(req(c, "memory")) for c in spec.get("initContainers", [])] or [0]))
    replicas = hpa.get(d["metadata"]["name"]) or d["spec"].get("replicas", 1)
    total_cpu += pod_cpu * replicas
    total_mem += pod_mem * replicas
    required = ((spec.get("affinity") or {}).get("podAntiAffinity") or {}).get("requiredDuringSchedulingIgnoredDuringExecution")
    if required and d["kind"] == "Deployment" and replicas >= nodes:
        print(f"{d['metadata']['name']}: {replicas} replicas with a required anti-affinity on {nodes} nodes")
    if required and d["kind"] == "StatefulSet" and replicas > nodes:
        print(f"{d['metadata']['name']}: {replicas} pods with a required anti-affinity on {nodes} nodes")
if total_cpu / nodes > 0.8 * alloc_cpu:
    print(f"the requests on a node are {total_cpu / nodes:.1f} vCPU, above 80 % of {alloc_cpu} vCPU")
if total_mem / nodes > 0.8 * alloc_mem:
    print(f"the requests on a node are {total_mem / nodes:.1f} GiB, above 80 % of {alloc_mem} GiB")
print(f"{total_cpu / nodes:.1f} vCPU and {total_mem / nodes:.1f} GiB of requests on a node")
PY
)" && [ "$(printf '%s\n' "$problems" | wc -l | tr -d ' ')" = 1 ]; then
    ok "size $name: $problems"
  else
    bad "size $name"
    printf '%s\n' "$problems" | sed 's/^/  /' | head -10
  fi
}
hsm_seal=(-f "$profiles/openbao-pkcs11.yaml" -f "$profiles/hsm-signer-local.yaml")
size_profile development 1 7.9 28.3 -f "$profiles/openbao-shamir.yaml"
size_profile extra-small 3 0.94 4.4 -f "$profiles/openbao-external.yaml"
size_profile small 3 15.9 58.4 -f "$profiles/openbao-external.yaml"
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
  if ! text="$(helm template ows "$notes_chart" --namespace ows -f "$keys" "${site[@]}" "$@" --show-only templates/zz-test-notes.yaml 2>&1)"; then
    bad "notes $name: $(printf '%s' "$text" | head -c 200)"
  elif grep -q -F -- "$expect" <<< "$text"; then
    ok "notes $name"
  else
    bad "notes $name: no \"$expect\""
  fi
}
notes "shamir" "bao operator unseal"
notes "shamir warning" "WARNING: the OpenBao seal is shamir. It is for development and tests only"
if helm template ows "$notes_chart" --namespace ows -f "$keys" "${matrix_site[@]}" -f "$profiles/openbao-external.yaml" \
    --show-only templates/zz-test-notes.yaml 2>&1 | grep -q "WARNING: the OpenBao seal"; then
  bad "notes: a seal warning with an external OpenBao"
else
  ok "notes: no seal warning with an external OpenBao"
fi
notes "external OpenBao" "Make the platform operator organisation and its first platform admin" -f "$profiles/openbao-external.yaml"
notes "URLs" "https://api.example.org"
# The SSRF guards turned off (outboundHttp.ssrfProtection.enabled false)
# give a warning in the notes; no warning by default.
notes "SSRF guards off" "WARNING: the SSRF guards of the api core, the webhook handler, the gateway and the wallet are off (outboundHttp.ssrfProtection.enabled is false). These pods call" \
  --set outboundHttp.ssrfProtection.enabled=false
if helm template ows "$notes_chart" --namespace ows -f "$keys" "${site[@]}" \
    --show-only templates/zz-test-notes.yaml 2>&1 | grep -q "WARNING: the SSRF guard"; then
  bad "notes: an SSRF warning with the guards on"
else
  ok "notes: no SSRF warning with the guards on"
fi
notes "connection budget of the bundled server" "can open 183 connections to it, and the hooks 5 more (max_connections"
notes "connection budget of an external server" "set max_connections of your server to at least 188" -f "$profiles/database-external.yaml"

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
  if err="$(helm template t "$chart" --namespace ow -f "$keys" "${site[@]}" "$@" 2>&1 >/dev/null)"; then
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
  if err="$(helm template t "$chart" --namespace ow -f "$keys" "${site[@]}" "$@" 2>&1 >/dev/null)"; then
    bad "guard $name: the render did not stop"
  elif grep -q -F -- "$expect" <<< "$err" || grep -q -F -- "invalid propertyName '$property'" <<< "$err"; then
    ok "guard $name"
  else
    bad "guard $name: the message lacks \"$expect\" and \"invalid propertyName '$property'\""
    printf '%s\n' "$err" | sed 's/^/  /' | head -5
  fi
}
# The database is always PostgreSQL: database.engine is not a value, and
# the stop for changed values names it (files/renamed-values.yaml), also
# with the value postgresql.
guard "engine" "- database.engine: remove it" --set database.engine=postgresql
guard "mode" "database.mode" --set database.mode=cluster
guard "external host" "database.external.host" --set database.mode=external --set database.admin.username=root --set database.admin.password.existingSecret=s --set database.external.ca.existingSecret=c
# The wallet roles hook creates the wallet's database roles as the server
# administrator, so an external server needs an admin user with the wallet.
guard "external database without admin user" "database.admin.username is required with database.mode external:" --set database.mode=external --set database.external.host=db.example.org --set database.external.ca.existingSecret=c
# The wallet database name is the prefix of the wallet's database roles:
# <prefix>_business_wallet_app has at most 63 characters.
guard "wallet database name too long for the role prefix" "can have at most 43" --set database.databases.wallet.name=w2345678901234567890123456789012345678901234
guard "seal" "openbao.seal" --set openbao.seal=transit
guard "seal required" "openbao.seal is required with the bundled OpenBao. For an installation that holds real keys, use your own OpenBao with an HSM seal (profiles/openbao-external.yaml)" --set openbao.seal=
guard "external OpenBao without address" "openbao.external.address" --set openbao.mode=external --set openbao.wallet.password.existingSecret=s
guard "external OpenBao without password" "openbao.wallet.password.existingSecret" --set openbao.mode=external --set openbao.external.address=https://openbao.example.org:8200
guard "exposure type" "exposure.type" --set exposure.type=route
guard "gatewayAPI without parentRefs" "parentRefs" --set exposure.type=gatewayAPI
guard "host" "api.host" --set api.host=
guard "image tag" "global.imageTag is required: the release tag of your version" --set global.imageTag=
guard "client address of the api host" "api.exposure.clientAddress.trustedProxies and api.exposure.clientAddress.trustedProxyHeader go together" --set 'api.exposure.clientAddress.trustedProxies={192.0.2.0/24}'
guard "client address of the wallet host" "organisationWallet.exposure.clientAddress.trustedProxyHeader and organisationWallet.exposure.clientAddress.trustedProxies go together" --set organisationWallet.exposure.clientAddress.trustedProxyHeader=CF-Connecting-IP
guard "unknown value" "Additional property" --set postgres.enabled=true
guard "sslMode verify-full without CA" "needs the CA of the server" -f "$profiles/database-external.yaml" --set database.external.ca.existingSecret= --set database.tls.sslMode=verify-full
guard "OpenBao update strategy" "openbao.updateStrategy" --set openbao.updateStrategy=Sometimes
# The platform operator Job: the required values, an http or https policy
# URL, and no password as a value (the password is a file in a Secret).
bootstrap=(-f "$here/values/operator-jobs-bootstrap.yaml")
guard "platform operator without admin e-mail" "api.jobs.provisionPlatformOperator.firstAdmin.email" "${bootstrap[@]}" --set api.jobs.provisionPlatformOperator.firstAdmin.email=
guard "platform operator without admin name" "api.jobs.provisionPlatformOperator.firstAdmin.name" "${bootstrap[@]}" --set api.jobs.provisionPlatformOperator.firstAdmin.name=
guard "platform operator without password Secret" "api.jobs.provisionPlatformOperator.firstAdmin.password.existingSecret" "${bootstrap[@]}" --set api.jobs.provisionPlatformOperator.firstAdmin.password.existingSecret=
guard "platform operator without organisation name" "api.jobs.provisionPlatformOperator.organisation.name" "${bootstrap[@]}" --set api.jobs.provisionPlatformOperator.organisation.name=
guard "platform operator without organisation type" "api.jobs.provisionPlatformOperator.organisation.type" "${bootstrap[@]}" --set api.jobs.provisionPlatformOperator.organisation.type=
guard "platform operator without location" "api.jobs.provisionPlatformOperator.organisation.location" "${bootstrap[@]}" --set api.jobs.provisionPlatformOperator.organisation.location=
guard "platform operator without policy URL" "api.jobs.provisionPlatformOperator.organisation.policyUrl" "${bootstrap[@]}" --set api.jobs.provisionPlatformOperator.organisation.policyUrl=
guard "platform operator policy URL not http or https" "policyUrl" "${bootstrap[@]}" --set api.jobs.provisionPlatformOperator.organisation.policyUrl=ftp://example.org/privacy
guard "platform operator password as a value" "api.jobs.provisionPlatformOperator.firstAdmin.password" "${bootstrap[@]}" --set api.jobs.provisionPlatformOperator.firstAdmin.password=not-a-value
guard "feature gate not a boolean" "enforce" --set-string gateway.features.enforce=off
# A folder that a process writes to must be on an emptyDir of its pod (the
# root file system is read-only).
guard "wallet state folder outside the emptyDir" "has worker.state_directory \"/var/ows\"" --set organisationWallet.advanced.extraConfig.worker.state_directory=/var/ows
# No log file (ow.noLogFile): each process logs to stdout, even with a path
# on an emptyDir (a rotating file of 6 x 100 MB fills a 64Mi /tmp).
no_log_file="the chart writes no log file in Kubernetes"
guard "no wallet log file" "organisationWallet.advanced.extraConfig sets log_file.path \"/tmp/ows.log\": $no_log_file" --set organisationWallet.advanced.extraConfig.log_file.path=/tmp/ows.log
guard "no wallet log file outside /tmp" "organisationWallet.advanced.extraConfig sets log_file.path \"/var/log/ows.log\": $no_log_file" --set organisationWallet.advanced.extraConfig.log_file.path=/var/log/ows.log
guard "no api log file" "api.advanced.extraConfig sets Log.file.path \"/tmp/api.log\": $no_log_file" --set api.advanced.extraConfig.Log.file.path=/tmp/api.log
guard "no gateway log file" "gateway.advanced.extraConfig sets Log.file.path \"/tmp/gateway.log\": $no_log_file" --set gateway.advanced.extraConfig.Log.file.path=/tmp/gateway.log
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
# Stopping the HTTP pods (the schema and ow.preStopSleep): a preStop of 0
# seconds or a strategy other than RollingUpdate stops the render. The chart
# calculates the grace period (see the renders of section 5).
guard "preStop of 0 seconds" "preStopSeconds" --set api.server.preStopSeconds=0
guard "rollout strategy Recreate" "strategy" --set gateway.strategy.type=Recreate
# A plain secret in a values file stops the render (a Secret reference
# {existingSecret, key} instead), also with the guard of the old values.
guard "plain SMTP password" "api.smtp.password: make a Secret with the SMTP password and set api.smtp.password.existingSecret" --set api.smtp.password=not-a-value
guard "plain Twilio auth token" "api.twilio.authToken: make a Secret with the auth token" --set api.twilio.authToken=not-a-value
guard "Twilio account SID without auth token" "api.twilio.accountSid.existingSecret and api.twilio.authToken.existingSecret go together" --set api.twilio.accountSid.existingSecret=twilio
# The database passwords: a plain password stops the render; each password
# can come from its own Secret, and the bundled server takes its admin
# password from database.admin.password.
guard "plain database password" "database.databases.api.password: remove it (a plain password in a values file is not permitted" --set database.databases.api.password=not-a-value
guard "plain admin password" "database.auth.adminPassword: remove it (a plain password in a values file is not permitted" --set database.auth.adminPassword=not-a-value
guard "admin user of the bundled server" "the admin user of the bundled server is postgres" --set database.admin.username=root
guard "CA of an external server with the bundled server" "database.external.ca is the CA of an external server" --set database.external.ca.existingSecret=c
guard "global log level" "global.logLevel" --set global.logLevel=verbose
guard "old log level word of the wallet" "organisationWallet.logLevel: WARNING is now warn" --set organisationWallet.logLevel=WARNING
# The values that changed (files/renamed-values.yaml): one message names
# every old value with its new value, the schema keeps each old path, and
# scripts/upgrade-values.py writes a file that renders as the new values
# (tests/check_renamed.py).
while IFS= read -r line; do
  case "$line" in
    "ok   "*) ok "${line#ok   }" ;;
    "FAIL "*) bad "${line#FAIL }" ;;
    *) echo "$line" ;;
  esac
done < <(python3 "$here/check_renamed.py" -f "$keys" "${site[@]}" 2>&1 || true)

# --- 5. Rendered settings ----------------------------------------------------------
# Each case: a text that the render must contain.
renders() {
  local name="$1" expect="$2"; shift 2
  local text
  if ! text="$(helm template t "$chart" --namespace ow -f "$keys" "${site[@]}" "$@" 2>&1)"; then
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
  if ! text="$(helm template t "$chart" --namespace ow -f "$keys" "${site[@]}" "$@" 2>&1)"; then
    bad "lacks $name: $(printf '%s' "$text" | head -c 200)"
  elif grep -q -F -- "$unexpected" <<< "$text"; then
    bad "lacks $name: has \"$unexpected\""
  else
    ok "lacks $name"
  fi
}
# openbao.seal has no default; an external OpenBao needs no seal.
renders "no seal with an external OpenBao" "kind: Deployment" -f "$profiles/openbao-external.yaml" --set openbao.seal=
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
# The password of one database from its own Secret: the init hook, the api
# pods and the database Secret of the chart (without that key).
renders "database password from its Secret" "name: my-api-db" --set database.databases.api.password.existingSecret=my-api-db --show-only templates/database/init.yaml
lacks "database password from its Secret not in the chart Secret" "igrant_api:" --set database.databases.api.password.existingSecret=my-api-db --show-only templates/secrets.yaml
renders "admin password of the bundled server from its Secret" "name: my-postgres-admin" --set database.admin.password.existingSecret=my-postgres-admin --show-only templates/database/postgresql.yaml
# The grace period of the HTTP pods: the chart calculates it from the stop
# times (preStop + drain + graceful + 5; the wallet preStop + graceful +
# background + 5; the dashboard preStop + 20).
renders "gateway grace period from the stop times" "terminationGracePeriodSeconds: 45" --set gateway.preStopSeconds=15 --show-only templates/gateway/deploy.yaml
renders "api grace period from the stop times" "terminationGracePeriodSeconds: 50" --set api.server.gracefulShutdownSeconds=30 --show-only templates/api/deploy.yaml
renders "dashboard grace period from the preStop" "terminationGracePeriodSeconds: 35" --set enterpriseDashboard.preStopSeconds=15 --show-only templates/dashboard/deploy.yaml
renders "wallet grace period from the stop times" "terminationGracePeriodSeconds: 55" --set organisationWallet.server.preStopSeconds=20 --show-only templates/wallet/deploy.yaml
# One log level for all components (global.logLevel), in the words of each
# program, and the value of one component over it.
renders "global log level in the wallet" "log_level: WARNING" --set global.logLevel=warn --show-only templates/wallet/configmap.yaml
renders "global log level in the gateway" "level: warn" --set global.logLevel=warn --show-only templates/gateway/configmap.yaml
renders "global log level in OpenBao" 'log_level = "warn"' --set global.logLevel=warn --show-only templates/openbao/configmap.yaml
renders "log level of the api over the global value" "level: error" --set global.logLevel=debug --set api.logLevel=error --show-only templates/api/configmap.yaml
# One client address rule per host (docs/exposure.md): the rule of the api
# host in the gateway, api and webhook files (ClientAddress), the rule of
# the wallet host only in the file of the wallet service role
# (client_address, snake_case keys), and no forwarded_allow_ips.
client_address=(--set api.exposure.clientAddress.header=X-Real-IP --set 'api.exposure.clientAddress.trustedProxies={173.245.48.0/20}' --set api.exposure.clientAddress.trustedProxyHeader=CF-Connecting-IP
  --set organisationWallet.exposure.clientAddress.header=X-Real-IP)
if helm template t "$chart" --namespace ow -f "$keys" "${site[@]}" "${client_address[@]}" > "$out/client-address.yaml" 2> "$out/client-address.err" \
  && problems="$(python3 - "$out/client-address.yaml" <<'PY' 2>&1
import sys, yaml
docs = [d for d in yaml.safe_load_all(open(sys.argv[1])) if d]
api_rule = {"header": "X-Real-IP", "trustedProxies": ["173.245.48.0/20"], "trustedProxyHeader": "CF-Connecting-IP"}
for doc in docs:
    if doc.get("kind") != "ConfigMap":
        continue
    name = doc["metadata"]["name"]
    for key, text in (doc.get("data") or {}).items():
        if not key.endswith(".yaml"):
            continue
        try:
            config = yaml.safe_load(text) or {}
        except yaml.YAMLError:
            continue
        if not isinstance(config, dict):
            continue
        if name in ("t-api", "t-gateway") and key in ("api.yaml", "webhook.yaml", "config.yaml"):
            if config.get("ClientAddress") != api_rule:
                print(f"{name} {key} ClientAddress is {config.get('ClientAddress')!r}")
        elif name == "t-wallet" and key == "service.yaml":
            if config.get("client_address") != {"header": "X-Real-IP"}:
                print(f"{name} {key} client_address is {config.get('client_address')!r}")
        elif "client_address" in config or "ClientAddress" in config:
            print(f"{name} {key} has a client address rule")
        if "forwarded_allow_ips" in str(config):
            print(f"{name} {key} has forwarded_allow_ips")
PY
)" && [ -z "$problems" ]; then
  ok "client address: one rule per host, the wallet rule only in the service file"
else
  bad "client address: $(head -c 300 "$out/client-address.err") $(printf '%s' "${problems:-}" | tr '\n' ';' | head -c 400)"
fi
lacks "client address: no rule of the wallet host by default" "client_address" --show-only templates/wallet/configmap.yaml
# The api files: the SMTP password from its Secret, and the sender address.
renders "SMTP password from its Secret" "passwordFile: /run/secrets/igrant-api/smtp-password" \
  --set api.smtp.host=smtp.example.org --set api.smtp.password.existingSecret=mail --set api.smtp.from=noreply@example.org --show-only templates/api/configmap.yaml
renders "SMTP sender address" "fromEmail: noreply@example.org" \
  --set api.smtp.host=smtp.example.org --set api.smtp.from=noreply@example.org --show-only templates/api/configmap.yaml
operator_jobs() {
  local case="$1"; shift
  local file="$out/operator-jobs-$case.yaml" result
  if ! result="$(helm template t "$chart" --namespace ow -f "$keys" "${site[@]}" "$@" 2>&1 > "$file")"; then
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
# gateway.features.enforce false; gateway.advanced.extraConfig still wins.
renders "feature gate on by default" "enforce: true"
renders "feature gate off" "enforce: false" --set gateway.features.enforce=false
lacks "feature gate off has no enforce true" "enforce: true" --set gateway.features.enforce=false
renders "feature gate off with extraConfig" "enforce: false" --set gateway.advanced.extraConfig.Features.enforce=false
# Each organisation's effective features select its webhook event types, so
# the api files have no Webhooks.events and the schema refuses the value.
renders "webhook delivery retention in the api files" "DeliveryRetentionDays: 10" --show-only templates/api/configmap.yaml
lacks "no webhook event types in the api files" "ows.issuer.issuance_history.credential_issued" --show-only templates/api/configmap.yaml
guard "no api.webhooks.events" "api.webhooks" --set-json 'api.webhooks.events=["ows.issuer.issuance_history.credential_issued"]'
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
  if ! text="$(helm template t "$chart" --namespace ow -f "$keys" "${site[@]}" "$@" --show-only templates/wallet/configmap.yaml 2> "$out/test-ca.err")"; then
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
  if ! helm template t "$chart" --namespace ow -f "$keys" "${site[@]}" "$@" > "$out/audit.yaml" 2> "$out/audit.err"; then
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
  if ! helm template t "$chart" --namespace ow -f "$keys" "${site[@]}" "$@" > "$out/play.yaml" 2> "$out/play.err"; then
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
  if ! helm template t "$chart" --namespace ow -f "$keys" "${site[@]}" "$@" > "$out/app-attest.yaml" 2> "$out/app-attest.err"; then
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
  if ! helm template t "$chart" --namespace ow -f "$keys" "${site[@]}" "$@" > "$out/anchors.yaml" 2> "$out/anchors.err"; then
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
# Installation limits (installation.limits): Limits.maxOrganisations in the
# api and webhook files and wallet_unit.organisation_wallet_units_max in the
# service, config and worker files, as integers, with the default 100. No
# other object has them: not the gateway file (the gateway refuses the
# section), the clock, the hooks or the Jobs.
installation_limits() {
  local name="$1" expect="$2"; shift 2
  local problems
  # Only stdout is YAML (helm writes its warnings to stderr).
  if ! helm template t "$chart" --namespace ow -f "$keys" "${site[@]}" "$@" > "$out/limits.yaml" 2> "$out/limits.err"; then
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
installation_limits "the defaults" '{"organisations": 100, "units": 100}'
installation_limits "the two limits" '{"organisations": 50, "units": 60}' \
  --set installation.limits.maxOrganisations=50 --set installation.limits.maxOrganisationWalletUnits=60
installation_limits "only the organisation limit" '{"organisations": 40, "units": 100}' --set installation.limits.maxOrganisations=40
installation_limits "only the organisation wallet unit limit" '{"organisations": 100, "units": 40}' \
  --set installation.limits.maxOrganisationWalletUnits=40
# A values file gives numbers as floats: the files must have the integer,
# not 1e+06.
installation_limits "the smallest limits as JSON numbers" '{"organisations": 1, "units": 1}' \
  --set-json 'installation.limits={"maxOrganisations": 1, "maxOrganisationWalletUnits": 1}'
guard "organisation limit 0" "installation.limits.maxOrganisations" --set installation.limits.maxOrganisations=0
guard "organisation limit over 100" "installation.limits.maxOrganisations" --set installation.limits.maxOrganisations=101
guard "organisation limit as a string" "installation.limits.maxOrganisations" --set-string installation.limits.maxOrganisations=50
guard "organisation limit empty" "installation.limits.maxOrganisations" --set installation.limits.maxOrganisations=
guard "organisation wallet unit limit 0" "installation.limits.maxOrganisationWalletUnits" \
  --set installation.limits.maxOrganisationWalletUnits=0
guard "organisation wallet unit limit over 100" "installation.limits.maxOrganisationWalletUnits" \
  --set installation.limits.maxOrganisationWalletUnits=101
guard "organisation wallet unit limit as a string" "installation.limits.maxOrganisationWalletUnits" \
  --set-string installation.limits.maxOrganisationWalletUnits=50
# Development builds of the wallet apps (developmentAppsAllowed): no key by
# default (the wallet default is false); when set, the boolean is in the
# files with a wallet_unit section (service, config, workers), never in the
# clock file. A string, even "true", stops the render.
development_apps() {
  local name="$1" expect="$2"; shift 2
  local problems
  if problems="$(helm template t "$chart" --namespace ow -f "$keys" "${site[@]}" "$@" \
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
# The services of the installation (docs/components.md): Installation in the
# api, webhook and gateway files (and in no other object) has the services
# [wallet], a constant of the chart, and the optional features
# (tests/check_installation.py). Each case is also an install
# (tests/check_hook_order.py) and, with network policies, a network matrix
# check (tests/check_network_matrix.py).
installation() {
  local name="$1"; shift
  local file="$out/installation-${name// /-}.yaml" result good=1
  if ! result="$(helm template t "$chart" --namespace ow -f "$keys" "${site[@]}" "$@" 2>&1 > "$file")"; then
    bad "installation $name: $(printf '%s' "$result" | head -c 300)"
    return
  fi
  if ! result="$(python3 "$here/check_installation.py" "$file" ${optional:+$optional} 2>&1)"; then
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
installation "the default values"
installation "network policies" -f "$profiles/network-policies.yaml"
installation "external database" -f "$profiles/database-external.yaml"
# The optional features (installation.optionalFeatures): the same list in the
# api, webhook, gateway and wallet files.
optional=protocol1 installation "protocol1" --set 'installation.optionalFeatures={protocol1}'
guard "organisationWallet.advanced.extraConfig.installation" "organisationWallet.advanced.extraConfig.installation: set installation.optionalFeatures instead" --set-json 'organisationWallet.advanced.extraConfig.installation={"optional_features":["protocol1"]}'
# api.advanced.extraConfig and gateway.advanced.extraConfig cannot set a different list: the
# same services are accepted, and the files keep the chart's form.
installation "the same list in api.advanced.extraConfig and gateway.advanced.extraConfig" \
  --set-json 'api.advanced.extraConfig.Installation={"services":["wallet"]}' --set-json 'gateway.advanced.extraConfig.Installation={"services":["wallet"]}'
guard "api.advanced.extraConfig.Installation that differs" "api.advanced.extraConfig.Installation names other services than this release (wallet)" \
  --set-json 'api.advanced.extraConfig.Installation={"services":[]}'
guard "gateway.advanced.extraConfig.Installation that differs" "gateway.advanced.extraConfig.Installation names other services than this release (wallet)" \
  --set-json 'gateway.advanced.extraConfig.Installation={"services":["wallet","api"]}'
guard "api.advanced.extraConfig.Installation without services" "api.advanced.extraConfig.Installation names other services" \
  --set-json 'api.advanced.extraConfig.Installation={}'
guard "the public keys of the wallet" "keys.serviceEnvelope.organisationWallet.publicJwks" --set keys.serviceEnvelope.organisationWallet.publicJwks=
audit "no bucket by default" '{"audit": {"retention_years": 7}, "bucket": null, "secrets": {}}'
s3=(--set organisationWallet.audit.bucket.name=example-audit --set organisationWallet.audit.bucket.endpoint=https://s3.example.org
    --set organisationWallet.audit.bucket.region=eu-west-1 --set organisationWallet.audit.bucket.accessKeyId.existingSecret=audit-bucket --set organisationWallet.audit.bucket.secretAccessKey.existingSecret=audit-bucket)
audit "s3 bucket with its access key" \
  '{"audit": {"retention_years": 7}, "bucket": {"type": "s3", "name": "example-audit", "endpoint": "https://s3.example.org", "region": "eu-west-1", "access_key_id_file": "/run/secrets/eudi-wallet/audit-bucket-access-key-id", "secret_access_key_file": "/run/secrets/eudi-wallet/audit-bucket-secret-access-key"}, "secrets": {"audit-bucket-access-key-id": ["audit-bucket", "access-key-id"], "audit-bucket-secret-access-key": ["audit-bucket", "secret-access-key"]}}' \
  "${s3[@]}"
audit "s3 bucket with a prefix and the store's CA" \
  '{"audit": {"retention_years": 10, "scope_retention_years": {"kms": 12}}, "bucket": {"type": "s3", "name": "example-audit", "prefix": "audit/production/", "endpoint": "https://s3.example.org", "region": "eu-west-1", "access_key_id_file": "/run/secrets/eudi-wallet/audit-bucket-access-key-id", "secret_access_key_file": "/run/secrets/eudi-wallet/audit-bucket-secret-access-key", "ca_file": "/run/secrets/eudi-wallet/audit-bucket-ca.crt"}, "secrets": {"audit-bucket-access-key-id": ["audit-bucket", "id"], "audit-bucket-secret-access-key": ["audit-bucket", "secret"], "audit-bucket-ca.crt": ["store-ca", "ca.pem"]}}' \
  "${s3[@]}" --set organisationWallet.audit.retentionYears=10 --set organisationWallet.audit.scopeRetentionYears.kms=12 \
  --set organisationWallet.audit.bucket.prefix=audit/production/ --set organisationWallet.audit.bucket.accessKeyId.key=id \
  --set organisationWallet.audit.bucket.secretAccessKey.key=secret --set organisationWallet.audit.bucket.ca.existingSecret=store-ca \
  --set organisationWallet.audit.bucket.ca.key=ca.pem
audit "gcs bucket with its service account" \
  '{"audit": {"retention_years": 7}, "bucket": {"type": "gcs", "name": "example_audit", "project": "example-project", "prefix": "audit/production/", "credentials_file": "/run/secrets/eudi-wallet/audit-bucket-service-account.json"}, "secrets": {"audit-bucket-service-account.json": ["audit-bucket", "sa.json"]}}' \
  --set organisationWallet.audit.bucket.type=gcs \
  --set organisationWallet.audit.bucket.name=example_audit --set organisationWallet.audit.bucket.project=example-project \
  --set organisationWallet.audit.bucket.prefix=audit/production/ --set organisationWallet.audit.bucket.credentials.existingSecret=audit-bucket \
  --set organisationWallet.audit.bucket.credentials.key=sa.json
audit "gcs bucket with the Google default credentials" '{"audit": {"retention_years": 7}, "bucket": {"type": "gcs", "name": "example-audit"}, "secrets": {}}' \
  --set organisationWallet.audit.bucket.type=gcs --set organisationWallet.audit.bucket.name=example-audit
for value in credentials accessKeyId secretAccessKey ca; do
  guard "audit bucket $value without bucket name" "organisationWallet.audit.bucket.$value.existingSecret needs organisationWallet.audit.bucket.name" \
    --set "organisationWallet.audit.bucket.$value.existingSecret=audit-bucket"
done
guard "audit bucket of type s3 without endpoint" "set organisationWallet.audit.bucket.type: gcs" \
  --set organisationWallet.audit.bucket.name=example-audit
guard "audit bucket of type s3 without region" "organisationWallet.audit.bucket.region is required" \
  "${s3[@]}" --set organisationWallet.audit.bucket.region=
guard "audit bucket of type s3 without access key" "organisationWallet.audit.bucket.accessKeyId.existingSecret and organisationWallet.audit.bucket.secretAccessKey.existingSecret are required" \
  "${s3[@]}" --set organisationWallet.audit.bucket.accessKeyId.existingSecret=
guard "audit bucket of type s3 without secret access key" "organisationWallet.audit.bucket.secretAccessKey.existingSecret are required" \
  "${s3[@]}" --set organisationWallet.audit.bucket.secretAccessKey.existingSecret=
guard "audit bucket of type s3 with an invalid S3 bucket name" "is not an S3 bucket name" \
  "${s3[@]}" --set organisationWallet.audit.bucket.name=example_audit
guard "audit bucket of type s3 with gcs values" "are values of type gcs" \
  "${s3[@]}" --set organisationWallet.audit.bucket.project=example-project
guard "audit bucket of type gcs with s3 values" "are values of type s3" \
  "${s3[@]}" --set organisationWallet.audit.bucket.type=gcs --set organisationWallet.audit.bucket.accessKeyId.existingSecret= --set organisationWallet.audit.bucket.secretAccessKey.existingSecret=
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

# Workers and clock (organisationWallet.workers, .clock, monitoring;
# docs/workers.md). The groups are a map with the group name as key: a case
# gives the groups that it changes, and null removes a default group.
main_group='{"queues":["realtime","attestation","status","kms"],"replicas":2,"processes":1,"threads":8,"shutdownTimeoutSeconds":600}'
maintenance_group='{"queues":["maintenance"],"replicas":1,"processes":1,"threads":2,"shutdownTimeoutSeconds":14400}'
workers() {
  local out="" sep="" pair
  for pair in "$@"; do out="$out$sep\"${pair%%=*}\":${pair#*=}"; sep=","; done
  printf 'organisationWallet.workers.groups={%s}' "$out"
}
guard_property_name "worker group name" "organisationWallet.workers.groups" "Main" --set-json "$(workers "Main=$main_group")"
guard "worker group name without the schema" 'organisationWallet.workers.groups: "Main" is not a group name' --skip-schema-validation --set-json "$(workers "Main=$main_group")"
guard "worker Deployment name too long" "gives the Deployment name" --set fullnameOverride=ows-installation-of-the-production-site
guard "worker queue" "organisationWallet.workers.groups.maintenance.queues.0" --set-json "$(workers "maintenance=${maintenance_group/\[\"maintenance\"\]/[\"default\"]}")"
guard "worker queue without the schema" '"default" is not a queue of the wallet' --skip-schema-validation --set-json "$(workers "maintenance=${maintenance_group/\[\"maintenance\"\]/[\"default\"]}")"
guard "worker queues empty without the schema" "organisationWallet.workers.groups.maintenance.queues is empty" --skip-schema-validation --set-json "$(workers "maintenance=${maintenance_group/\[\"maintenance\"\]/[]}")"
guard "worker queue listed twice without the schema" "organisationWallet.workers.groups.maintenance.queues names a queue two times" --skip-schema-validation --set-json "$(workers "maintenance=${maintenance_group/\[\"maintenance\"\]/[\"maintenance\",\"maintenance\"]}")"
guard "worker queue that no group runs" "no group runs the queue maintenance" --set-json "$(workers "maintenance=null")"
guard "worker replicas" "organisationWallet.workers.groups.main.replicas" --set-json "$(workers "main=${main_group/\"replicas\":2/\"replicas\":0}")"
guard "worker replicas without the schema" "organisationWallet.workers.groups.main.replicas (0) must be 1 or more" --skip-schema-validation --set-json "$(workers "main=${main_group/\"replicas\":2/\"replicas\":0}")"
guard "worker group without threads" "threads" --set-json "$(workers "extra=${main_group/\"threads\":8,/}")"
guard "worker grace period is not a value" "terminationGracePeriodSeconds" --set organisationWallet.workers.groups.main.terminationGracePeriodSeconds=630
guard "clock replicas" "organisationWallet.clock.replicas" --set organisationWallet.clock.replicas=0
one_group="$(workers 'all={"queues":["realtime","attestation","status","kms","maintenance"],"replicas":1,"processes":2,"threads":4,"shutdownTimeoutSeconds":14400}' main=null maintenance=null)"
renders "one worker group for every queue" "name: t-wallet-worker-all" --set-json "$one_group"
renders "one worker group: the grace period from its shutdown timeout" "terminationGracePeriodSeconds: 14430" --set-json "$one_group" --show-only templates/wallet/worker.yaml
renders "a change of one worker group keeps the other group" "name: t-wallet-worker-maintenance" --set organisationWallet.workers.groups.main.replicas=3 --show-only templates/wallet/worker.yaml
renders "one worker group: its configuration key" "worker-all.yaml: |" --set-json "$one_group"
lacks "one worker group: no default group Deployments" "name: t-wallet-worker-main" --set-json "$one_group"
renders "clock replicas" "replicas: 3" --set organisationWallet.clock.replicas=3 --show-only templates/wallet/clock.yaml
renders "ServiceMonitor of the workers and the clock" "name: t-wallet-metrics" --set monitoring.serviceMonitor.enabled=true
# The SSRF guards (outboundHttp): the allow list of the wallet; no
# key by default (an image without the setting gets no unknown key); the
# entries in each wallet file; the render stops for a loopback or metadata
# network and for an entry that is not a host name, address or CIDR.
lacks "no SSRF allow list by default" "ssrf_protection" --show-only templates/wallet/configmap.yaml
renders "the SSRF allow list in the wallet files" "allowed_private:" --set-json 'outboundHttp.allowedPrivate=["wallet.example.internal","10.20.0.0/16"]' --show-only templates/wallet/configmap.yaml
guard "no loopback in the SSRF allow list" "covers a loopback, link-local, metadata or unspecified address" --set-json 'outboundHttp.allowedPrivate=["127.0.0.0/8"]'
guard "no metadata address in the SSRF allow list" "covers a loopback, link-local, metadata or unspecified address" --set-json 'outboundHttp.allowedPrivate=["169.254.169.254"]'
guard "an SSRF allow entry is a host, an address or a CIDR" "outboundHttp.allowedPrivate.0" --set-json 'outboundHttp.allowedPrivate=["not a host"]'
renders "SSRF guards off: the api file" "ssrfProtectionDisabled: true" --set outboundHttp.ssrfProtection.enabled=false --show-only templates/api/configmap.yaml
renders "SSRF guards off: the gateway file" "ssrfProtectionDisabled: true" --set outboundHttp.ssrfProtection.enabled=false --show-only templates/gateway/configmap.yaml
renders "SSRF guards off: the wallet files" "enabled: false" --set outboundHttp.ssrfProtection.enabled=false --show-only templates/wallet/configmap.yaml
guard "SSRF switch of the api in the extra configuration" "set outboundHttp.ssrfProtection.enabled instead" --set-json 'api.advanced.extraConfig={"OutboundHttp":{"ssrfProtectionDisabled":true}}'
guard "SSRF switch of the wallet in the extra configuration" "set outboundHttp.ssrfProtection.enabled and outboundHttp.allowedPrivate instead" --set-json 'organisationWallet.advanced.extraConfig={"ssrf_protection":{"enabled":false}}'
# Alert rules (monitoring.prometheusRule; tests/alert-rules.sh runs
# them with promtool): none by default, and only with the ServiceMonitor.
lacks "no PrometheusRule by default" "kind: PrometheusRule" --set monitoring.serviceMonitor.enabled=true
renders "wallet PrometheusRule: a missing partition of the month is critical" "alert: PartitionOfTheMonthMissing" --set monitoring.serviceMonitor.enabled=true --set monitoring.prometheusRule.enabled=true --show-only templates/wallet/prometheusrule.yaml
renders "wallet PrometheusRule: labels for the rule selector" "release: kube-prometheus" --set monitoring.serviceMonitor.enabled=true --set monitoring.prometheusRule.enabled=true --set-json 'monitoring.labels={"release":"kube-prometheus"}' --show-only templates/wallet/prometheusrule.yaml
guard "PrometheusRule without the ServiceMonitor" "monitoring.prometheusRule.enabled needs monitoring.serviceMonitor.enabled" --set monitoring.prometheusRule.enabled=true
# Servers (service and config): a headless Service for the metrics port
# (9190) with the job wallet-server; the ServiceMonitor takes the job name
# from the label metrics.igrant.io/job.
renders "metrics Service of the service role" "name: t-wallet-service-metrics" --set monitoring.serviceMonitor.enabled=true --show-only templates/wallet/servicemonitor.yaml
renders "metrics Service of the config role" "name: t-wallet-config-metrics" --set monitoring.serviceMonitor.enabled=true --show-only templates/wallet/servicemonitor.yaml
renders "job label value of the server targets" "metrics.igrant.io/job: wallet-server" --set monitoring.serviceMonitor.enabled=true --show-only templates/wallet/servicemonitor.yaml
renders "job label of the ServiceMonitor" "jobLabel: metrics.igrant.io/job" --set monitoring.serviceMonitor.enabled=true --show-only templates/wallet/servicemonitor.yaml
renders "scrape interval of the servers" "interval: 30s" --set monitoring.serviceMonitor.enabled=true --show-only templates/wallet/servicemonitor.yaml
lacks "no metrics port in the route Services" "9190" --show-only templates/wallet/svc.yaml
renders "worker group metrics Service includes pods that are not ready" "publishNotReadyAddresses: true" --set monitoring.serviceMonitor.enabled=true --show-only templates/wallet/servicemonitor.yaml
# Scrape ports, open only to the monitoring namespace
# (monitoring.networkPolicy): the health port of the workers and the clock
# (/metrics), and the metrics port of the servers.
if problems="$(helm template t "$chart" --namespace ow -f "$keys" "${site[@]}" -f "$profiles/network-policies.yaml" \
    --set monitoring.networkPolicy.enabled=true --set-json 'monitoring.networkPolicy.namespaceSelector={"matchLabels":{"kubernetes.io/metadata.name":"monitoring"}}' \
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
  --set monitoring.networkPolicy.enabled=true --set-json 'monitoring.networkPolicy.namespaceSelector={"matchLabels":{"kubernetes.io/metadata.name":"monitoring"}}' \
  --show-only templates/networkpolicy/policies.yaml
lacks "no scrape of the workers and the clock without the monitoring namespace" "port: health" -f "$profiles/network-policies.yaml" \
  --show-only templates/networkpolicy/policies.yaml
# DNS servers outside the pod network (networkPolicy.dns.cidrs): an ipBlock
# next to the DNS pods in the DNS policy; none by default.
dns_policy() {
  local name="$1" expect="$2"; shift 2
  local problems
  if problems="$(helm template t "$chart" --namespace ow -f "$keys" "${site[@]}" -f "$profiles/network-policies.yaml" \
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
# networkPolicy.clusterCidrs); the api, the webhook handler and the wallet
# roles reach any port by default. IPv6: no multicast, and in the
# NAT64 prefix 64:ff9b::/96 only the images of IPv4 ranges that are never
# public are closed: a public IPv4 vendor through NAT64 (an IPv6-only
# cluster with DNS64) stays open, the NAT64 images of private, loopback or
# metadata addresses are closed. No IPv4-mapped address (the API server
# refuses it).
if problems="$(helm template t "$chart" --namespace ow -f "$keys" "${site[@]}" -f "$profiles/network-policies.yaml" \
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
if sorted(roles) != ["api", "wallet-config", "wallet-service", "wallet-worker", "webhook"]:
    print("roles with any port", sorted(roles))
' 2>&1)" && [ -z "$problems" ]; then
  ok "internet profiles: IPv4 and IPv6 with the exceptions of each family (NAT64: only the never-public images closed); any port for the api, webhook handler and wallet roles"
else
  bad "internet profiles: $(printf '%s' "$problems" | head -c 400)"
fi
# The egress profile "platform" (this platform's public hosts): the pods of
# networkPolicy.ingressController are always a target; the wallet roles have
# the profile by default, the other roles do not.
platform_profile() {
  local name="$1" expect="$2"; shift 2
  local problems
  if problems="$(helm template t "$chart" --namespace ow -f "$keys" "${site[@]}" -f "$profiles/network-policies.yaml" \
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
envoy='{"namespaceSelector": {"matchLabels": {"kubernetes.io/metadata.name": "envoy-gateway-system"}}, "podSelector": {}}'
ingress_nginx='{"namespaceSelector": {"matchLabels": {"kubernetes.io/metadata.name": "ingress-nginx"}}, "podSelector": {}}'
platform_profile "the pods of envoy-gateway-system on 10080 and 10443, the load balancer ports 80 and 443, the wallet roles" \
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
# without 10080 and 10443, a selector of another namespace, and the profile
# platform for the api.
matrix_refuses() {
  local name="$1" expect="$2"; shift 2
  local result
  if ! helm template t "$chart" --namespace ow -f "$keys" "${site[@]}" -f "$profiles/network-policies.yaml" "$@" > "$out/matrix-mutant.yaml" 2>&1; then
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
matrix_refuses "a selector of another namespace" \
  "the matrix connection the Envoy pods of the Gateway platform (ingressController) -> gateway:http is denied" \
  --set-json 'networkPolicy.ingressController.namespaceSelector.matchLabels={"kubernetes.io/metadata.name":"ingress-nginx"}'
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
# NATS TLS (nats.tls, nats.external.ca), bundled and external.
guard "external NATS CA with the bundled NATS" "nats.external.ca is the CA of an external NATS" --set nats.external.ca.existingSecret=my-nats-ca
guard "NATS mode" "nats.mode" --set nats.mode=cluster
renders "NATS with your own certificate" "secretName: my-nats-tls" --set nats.tls.existingSecret=my-nats-tls --show-only templates/nats/statefulset.yaml
lacks "chart NATS TLS Secret with your own certificate" "name: t-nats-tls" --set nats.tls.existingSecret=my-nats-tls
external_nats=(--set nats.mode=external --set nats.external.url=tls://nats.example.org:4222)
renders "external NATS with its CA" "name: my-nats-ca" "${external_nats[@]}" --set nats.external.ca.existingSecret=my-nats-ca
lacks "external NATS: no chart TLS Secret" "t-nats-tls" "${external_nats[@]}" --set nats.external.ca.existingSecret=my-nats-ca
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
guard "worker threads above the largest wallet pool" "organisationWallet.workers.groups.main.threads" --set-json "$(workers "main=${main_group/\"threads\":8/\"threads\":101}")"
# Connection budget (docs/database.md, "Connection budget"): the release's
# pools, at the most pods of each Deployment, plus the hooks must fit in the
# bundled server's max_connections less its reserved connections.
renders "connection budget at the limit of the bundled server" "max_connections=191" --set database.postgresql.parameters.max_connections=191
guard "connection budget one over the limit" "can open 183 connections to the bundled database server" --set database.postgresql.parameters.max_connections=190
guard "connection budget counts the reserved connections" "less the 13 reserved connections" \
  --set database.postgresql.parameters.max_connections=191 --set-string database.postgresql.parameters.reserved_connections=10
guard "connection budget counts the replicas" "wallet config 3 x 26" --set organisationWallet.config.replicas=3 \
  --set database.postgresql.parameters.max_connections=191
renders "no connection budget check with an external server" "kind: StatefulSet" -f "$profiles/database-external.yaml" --set api.replicas=20
# Connection pooler (database.pooler): the wallet files of processes with
# sessions name it, and the budget counts its server connections instead of
# the wallet session pools.
pooler=(--set database.pooler.host=pgbouncer.ow.svc --set database.pooler.serverConnections=40)
renders "pooler in the wallet files" "host: pgbouncer.ow.svc" "${pooler[@]}" --show-only templates/wallet/configmap.yaml
lacks "no pooler without its host" "pooler" --show-only templates/wallet/configmap.yaml
if problems="$(helm template t "$chart" --namespace ow -f "$keys" "${site[@]}" "${pooler[@]}" \
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
renders "the session pool of a worker process follows its threads" "pool_size: 16" --set database.postgresql.parameters.max_connections=600 --set-json "$(workers "main=${main_group/\"threads\":8/\"threads\":16}")" \
  --show-only templates/wallet/configmap.yaml
renders "api reader pool" "maxConns: 9" --set database.pools.apiReadAccess.maxConns=9 --show-only templates/api/configmap.yaml

# Valkey (redis.*): the schema and the template guards.
redis_sts() {
  local name="$1" expect="$2"; shift 2
  local text
  if ! text="$(helm template t "$chart" --namespace ow -f "$keys" "${site[@]}" "$@" --show-only templates/redis/statefulset.yaml 2>&1)"; then
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
external_redis=(-f "$profiles/redis-external.yaml")
guard "external redis without sentinels or address" "redis.external" "${external_redis[@]}" --set-json 'redis.external.sentinels=[]'
guard "external redis without sentinels or address without the schema" "redis.external.sentinels or redis.external.address is required" "${external_redis[@]}" --skip-schema-validation --set-json 'redis.external.sentinels=[]'
guard "external redis with sentinels and address" "redis.external" "${external_redis[@]}" --set redis.external.address=redis.example.org:6379
guard "external redis with sentinels and address without the schema" "set redis.external.sentinels or redis.external.address, not both" "${external_redis[@]}" --skip-schema-validation --set redis.external.address=redis.example.org:6379
guard "external redis user without password Secret" "redis.users.gateway" "${external_redis[@]}" --set redis.users.gateway.password.existingSecret=
guard "external redis user without password Secret without the schema" "redis.users.gateway.password.existingSecret is required with redis.mode external" "${external_redis[@]}" --skip-schema-validation --set redis.users.gateway.password.existingSecret=
guard "external redis Sentinel without port" "redis.external.sentinels" "${external_redis[@]}" --set-json 'redis.external.sentinels=["redis-1.example.org"]'
guard "external redis Sentinel without port without the schema" '"redis-1.example.org" is not host:port' "${external_redis[@]}" --skip-schema-validation --set-json 'redis.external.sentinels=["redis-1.example.org"]'
guard "external redis with network policies without addresses" "networkPolicy.externalRedis needs the addresses" "${external_redis[@]}" -f "$profiles/network-policies.yaml" --set-json 'networkPolicy.externalRedis=[]'
redis_sts "with redis.affinity" "requiredDuringSchedulingIgnoredDuringExecution" \
  --set-json 'redis.affinity={"podAntiAffinity":{"requiredDuringSchedulingIgnoredDuringExecution":[{"topologyKey":"kubernetes.io/hostname","labelSelector":{"matchLabels":{"app.kubernetes.io/component":"redis"}}}]}}'
redis_sts "with a user's password Secret" "name: my-redis-wallet-service" --set redis.users.walletService.password.existingSecret=my-redis-wallet-service
redis_sts "with your own certificate" "secretName: my-redis-tls" --set redis.tls.existingSecret=my-redis-tls
redis_sts "with 5 pods" "t-redis-4.t-redis-headless.ow.svc" --set redis.replicas=5 --set redis.sentinel.quorum=3
lacks "chart Valkey TLS Secret with your own certificate" "name: t-redis-tls" --set redis.tls.existingSecret=my-redis-tls
renders "redis maxmemory" "maxmemory 1gb" --set redis.maxmemory=1gb
renders "redis 5 Sentinels in the wallet file" "- t-redis-4.t-redis-headless.ow.svc:26379" --set redis.replicas=5 --set redis.sentinel.quorum=3
renders "external redis address" "address: redis.example.org:6379" "${external_redis[@]}" --set-json 'redis.external.sentinels=[]' --set redis.external.address=redis.example.org:6379
lacks "external redis address without the Sentinel login" "sentinel_username" "${external_redis[@]}" --set-json 'redis.external.sentinels=[]' --set redis.external.address=redis.example.org:6379
lacks "external redis Sentinels without a login" "sentinel_username" "${external_redis[@]}" --set redis.external.sentinelAuth=false
lacks "external redis without CA (uses the system CAs)" "redis-ca.crt" "${external_redis[@]}" --set redis.external.ca.existingSecret=

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
renders "Valkey ServiceMonitor" "name: t-redis-metrics" "${metrics[@]}" --set monitoring.serviceMonitor.enabled=true
lacks "no Valkey ServiceMonitor without its value" "t-redis-metrics" "${metrics[@]}"
lacks "no Valkey ServiceMonitor without the exporter" "t-redis-metrics" --set monitoring.serviceMonitor.enabled=true
renders "one interval and the labels of all ServiceMonitors" "release: kube-prometheus" "${metrics[@]}" --set monitoring.serviceMonitor.enabled=true --set monitoring.serviceMonitor.interval=60s \
  --set-json 'monitoring.labels={"release":"kube-prometheus"}' --show-only templates/redis/servicemonitor.yaml
renders "monitoring of an external Valkey: no Valkey ServiceMonitor, no stop" "kind: ServiceMonitor" "${external_redis[@]}" --set monitoring.serviceMonitor.enabled=true
renders "Valkey scrape with network policies" "port: metrics" -f "$profiles/network-policies.yaml" \
  --set monitoring.networkPolicy.enabled=true --set-json 'monitoring.networkPolicy.namespaceSelector={"matchLabels":{"kubernetes.io/metadata.name":"monitoring"}}' \
  --show-only templates/networkpolicy/policies.yaml
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
if ! helm template t "$chart" --namespace ow -f "$keys" "${site[@]}" -f "$profiles/network-policies.yaml" \
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
# api uploads (api.advanced.extraConfig Uploads and ImageUpload): the gateway file
# class must take the largest image + 64 KiB, and the memory request +
# Uploads.maxInProgress x the largest image must fit below the api memory
# limit.
guard "gateway file class below the api image upload limit" "must be at least the api ImageUpload.maxBytes (104857600) + 65536" --set-json 'api.advanced.extraConfig={"ImageUpload":{"maxBytes":104857600}}' --set gateway.proxy.maxBodyBytes.file=104857600 --set api.tmp.sizeLimit=100Mi
guard "8 uploads of 100 MiB above the api memory limit" "Uploads.maxInProgress (8) x the largest image (104791040 bytes" --set-json 'api.advanced.extraConfig={"ImageUpload":{"maxBytes":104791040}}' --set gateway.proxy.maxBodyBytes.file=104857600 --set api.tmp.sizeLimit=100Mi
guard "too many uploads in progress for the api memory limit" "Uploads.maxInProgress (60) x the largest image (5242880 bytes" --set-json 'api.advanced.extraConfig={"Uploads":{"maxInProgress":60}}'
# The dashboard config.json: a change restarts the dashboard pods (the
# config.json checksum).
if [ "$(helm template t "$chart" --namespace ow -f "$keys" "${site[@]}" --show-only templates/dashboard/deploy.yaml | grep 'checksum/config')" != \
     "$(helm template t "$chart" --namespace ow -f "$keys" "${site[@]}" --set enterpriseDashboard.image.tag=test-version --show-only templates/dashboard/deploy.yaml | grep 'checksum/config')" ]; then
  ok "a new config.json restarts the dashboard pods (config.json checksum)"
else
  bad "a new config.json restarts the dashboard pods (config.json checksum)"
fi
renders "2 uploads of 100 MiB with a memory limit of 1Gi" "kind: Deployment" --set-json 'api.advanced.extraConfig={"ImageUpload":{"maxBytes":104791040},"Uploads":{"maxInProgress":2}}' --set gateway.proxy.maxBodyBytes.file=104857600 --set api.tmp.sizeLimit=100Mi --set api.resources.limits.memory=1Gi
# Writable paths of the pods that run as non-root with a read-only root
# file system: /tmp of each api, webhook, dashboard and wallet pod (64Mi, in
# memory except for the dashboard), /tmp and the socket folder of the
# bundled server, and the pid folder of NATS.
if ! helm template t "$chart" --namespace ow -f "$keys" "${site[@]}" > "$out/writable.yaml" 2> "$out/writable.err"; then
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
if ! helm template t "$chart" --namespace ow -f "$keys" "${site[@]}" \
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
if ! helm template t "$chart" --namespace ow -f "$keys" "${site[@]}" -f "$here/values/operator-jobs-bootstrap.yaml" \
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
if pods < 20:
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
if ! text="$(helm template t "$notes_chart" --namespace ow -f "$keys" "${site[@]}" "${global_security[@]}" \
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
if ! helm template t "$chart" --namespace ow -f "$keys" "${site[@]}" -f "$profiles/exposure-envoy-gateway.yaml" -f "$here/values/operator-jobs-bootstrap.yaml" \
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
# An upgrade from a release with the values of each case to a release with
# the default values.
upgrade_order() {
  local name="$1" database="$2"; shift 2
  local args=(-f "$keys" "${site[@]}"
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
for database in database-bundled database-external; do
  upgrade_order "with the same values" "$database"
  upgrade_order "that turns the database TLS on" "$database" --set database.tls.enabled=false
done

# Hook Secrets (the database Secret, the read access Secret and the wallet
# role Secret) keep the values of the earlier release's Secrets. "helm
# template" has no cluster, so a copy of the chart reads the earlier Secrets
# from earlier-secrets.json instead of lookup (ow.lookupSecretKey). The
# earlier database Secret has no wallet password (as for a new database of
# a later chart version): the render must create a new one.
lookup_chart="$out/lookup-chart"
rm -rf "$lookup_chart"
mkdir -p "$lookup_chart"
cp -R "$chart/Chart.yaml" "$chart/values.yaml" "$chart/values.schema.json" "$chart/templates" "$chart/files" "$chart/policies" "$lookup_chart/"
lookup_line='{{- $secret := lookup "v1" "Secret" $root.Release.Namespace (index . 1) -}}'
stub_line='{{- $secret := index ($root.Files.Get "earlier-secrets.json" | fromJson) (index . 1) -}}'
lookup_args=(-f "$keys" "${site[@]}")
if [ "$(grep -c -F -- "$lookup_line" "$lookup_chart/templates/_helpers.tpl")" != 1 ]; then
  bad "upgrade keeps the Secret values: ow.lookupSecretKey lacks the lookup line that the test replaces"
elif ! helm template t "$chart" --namespace ow "${lookup_args[@]}" --show-only templates/secrets.yaml > "$out/secrets-new.yaml" 2> "$out/secrets.err"; then
  bad "upgrade keeps the Secret values: $(head -c 200 "$out/secrets.err")"
else
  LOOKUP_LINE="$lookup_line" STUB_LINE="$stub_line" perl -pi -e 's/\Q$ENV{LOOKUP_LINE}\E/$ENV{STUB_LINE}/' "$lookup_chart/templates/_helpers.tpl"
  # The earlier Secrets: the keys of a new render with known test values
  # (not secrets), without the wallet password.
  python3 -c '
import base64, json, sys, yaml
earlier = {}
for doc in yaml.safe_load_all(open(sys.argv[1])):
    if doc and doc["metadata"]["name"] in ("t-postgres", "t-postgres-tls", "t-read-access", "t-wallet-database-roles"):
        name = doc["metadata"]["name"]
        earlier[name] = {"data": {key: base64.b64encode(f"earlier-{name}-{key}".encode()).decode()
                                  for key in doc["data"] if (name, key) != ("t-postgres", "igrant_wallet")}}
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
if "igrant_wallet" not in rendered.get("t-postgres", {}).get("data", {}):
    print("the Secret t-postgres has no wallet password")
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
if ! helm template t "$chart" --namespace ow -f "$keys" "${site[@]}" \
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
  if ! helm template t "$chart" --namespace ow -f "$keys" "${site[@]}" -f "$here/values/pss-mutant.yaml" \
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
