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
#    (tests/check_links.py).
# 2. The matrix of the examples (examples/): every combination of one file of
#    each group, with examples/site.yaml and tests/values/keys.yaml:
#      database   postgresql-bundled, mysql-bundled, postgresql-external, mysql-external
#      OpenBao    openbao-shamir, openbao-external
#      exposure   exposure-ingress-nginx, exposure-ingress-nginx-cert-manager,
#                 exposure-envoy-gateway, exposure-kgateway, exposure-none
#      policies   none, networkpolicy
#    For each: helm template, kubeconform -strict (when it is installed; the
#    HTTPRoute schema of the Gateway API from the CRDs catalog) and
#    tests/check_render.py. helm lint runs once per database and OpenBao
#    pair.
# 3. The next steps (NOTES.txt).
# 4. The render guards: wrong values stop the render with a clear message
#    (values.schema.json and the template guards).
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
  "$chart/policies/network-matrix.yaml" "$chart/scripts/make-keys.sh")
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

# --- 2. The matrix of the examples --------------------------------------------
kubeconform_bin="$(command -v kubeconform || true)"
if [ -z "$kubeconform_bin" ]; then
  echo "kubeconform is not installed: the schema check is skipped"
fi
kubeconform_cache="$out/kubeconform-cache"
mkdir -p "$kubeconform_cache"
engine_of() { case "$1" in mysql-*) echo mysql ;; *) echo postgresql ;; esac; }
mode_of() { case "$1" in *-external) echo external ;; *) echo bundled ;; esac; }
exposure_of() { case "$1" in exposure-ingress-*) echo ingress ;; exposure-none) echo none ;; *) echo gatewayAPI ;; esac; }
for database in postgresql-bundled mysql-bundled postgresql-external mysql-external; do
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
        if [ "$good" = 1 ]; then ok "$name"; else bad "$name"; fi
      done
    done
  done
done

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
guard "engine" "database.engine" "${shamir[@]}" --set database.engine=oracle
guard "mode" "database.mode" "${shamir[@]}" --set database.mode=cluster
guard "external host" "database.external.host" "${shamir[@]}" --set database.mode=external --set database.external.admin.user=root --set database.external.admin.passwordSecret=s --set database.tls.caSecret=c
guard "external without admin" "database.auth.existingSecret" "${shamir[@]}" --set database.mode=external --set database.external.host=db.example.org --set database.tls.caSecret=c
guard "mysql TLS without CA" "database.tls.caSecret" "${shamir[@]}" -f "$examples/mysql-external.yaml" --set database.tls.caSecret=
guard "mysql sslMode" "sslMode" "${shamir[@]}" -f "$examples/mysql-bundled.yaml" --set database.tls.sslMode=require
guard "seal" "openbao.seal" --set openbao.seal=transit
guard "external OpenBao without address" "openbao.external.address" --set openbao.mode=external --set openbao.wallet.existingSecret=s
guard "external OpenBao without password" "openbao.wallet.existingSecret" --set openbao.mode=external --set openbao.external.address=https://openbao.example.org:8200
guard "exposure type" "exposure.type" "${shamir[@]}" --set exposure.type=route
guard "gatewayAPI without parentRefs" "parentRefs" "${shamir[@]}" --set exposure.type=gatewayAPI
guard "host" "api.host" "${shamir[@]}" --set api.host=
guard "storage bucket" "gcsBucket" "${shamir[@]}" --set organisationWallet.storage.gcsBucket=
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
# The built-in test CA: kms.test_ca of every wallet role file.
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
for role in ("service", "config", "scheduler"):
    test_ca = yaml.safe_load(data[f"{role}.yaml"])["kms"].get("test_ca")
    if test_ca != expected:
        print(f"{role}.yaml kms.test_ca is {test_ca!r}")
' "$expect" <<< "$text" 2>&1)" && [ -z "$problems" ]; then
    ok "test CA $name"
  else
    bad "test CA $name: $(printf '%s' "$problems" | tr '\n' ';' | head -c 200)"
  fi
}
test_ca "on by default" '{"enabled": true, "leaf_validity_days": 365}' "${shamir[@]}"
test_ca "off, 90 days" '{"enabled": false, "leaf_validity_days": 90}' "${shamir[@]}" --set organisationWallet.keyStores.testCa.enabled=false --set organisationWallet.keyStores.testCa.leafValidityDays=90
guard "test CA validity" "organisationWallet.keyStores.testCa.leafValidityDays" "${shamir[@]}" --set organisationWallet.keyStores.testCa.leafValidityDays=3651

renders "local backend openbao by default" "local_backend: openbao" "${shamir[@]}"
# The WIA pool refill event (core NATS): the scheduler subscribes to it.
renders "WIA pool refill event of the scheduler" 'subscribe: { allow: ["ows.wia_pool.refill_requested", "_INBOX_wallet.>"] }' "${shamir[@]}"

echo "result: ${pass} passed, ${fail} failed"
[ "$fail" -eq 0 ]
