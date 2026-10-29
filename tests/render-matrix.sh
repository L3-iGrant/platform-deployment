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
#      database   postgresql-bundled, postgresql-external
#      OpenBao    openbao-shamir, openbao-external
#      exposure   exposure-ingress-nginx, exposure-ingress-nginx-cert-manager,
#                 exposure-envoy-gateway, exposure-kgateway, exposure-none
#      policies   none, networkpolicy
#    For each: helm template, kubeconform -strict (when it is installed; the
#    HTTPRoute schema of the Gateway API from the CRDs catalog) and
#    tests/check_render.py. helm lint runs once per database and OpenBao
#    pair. One more render of the bundled server has the DDL and connection
#    logs off.
# 3. The next steps (NOTES.txt).
# 4. The render guards: wrong values stop the render with a clear message
#    (values.schema.json and the template guards).
# 5. Rendered settings.
# 6. Install and upgrade: tests/check_hook_order.py replays the steps of
#    Helm on the renders (each render of the matrix is an install; an upgrade
#    with the same values, and upgrades that turn the organisation wallet,
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
# The audit log: audit.* of every wallet role file and of the migration
# hook; the bucket only in the scheduler file, and the Secret of its service
# account only in the scheduler pods.
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
for role in ("service", "config", "scheduler"):
    audit = yaml.safe_load(files[f"{role}.yaml"]).get("audit")
    want = dict(expected["audit"], **({"bucket": expected["bucket"]} if role == "scheduler" and expected["bucket"] else {}))
    if audit != want:
        print(f"{role}.yaml audit is {audit!r}")
    pod = find("Deployment", f"t-wallet-{role}")["spec"]["template"]["spec"]
    mounted = {item["path"]: [source["secret"]["name"], item["key"]] for volume in pod["volumes"] if volume["name"] == "secrets"
               for source in volume["projected"]["sources"] for item in source["secret"]["items"]}
    secret = mounted.get("audit-bucket-service-account.json")
    if secret != (expected["secret"] if role == "scheduler" else None):
        print(f"the {role} pods mount {secret!r} as the service account of the audit bucket")
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
audit "no bucket by default" '{"audit": {"retention_years": 7}, "bucket": null, "secret": null}' "${shamir[@]}"
audit "bucket with its service account" \
  '{"audit": {"retention_years": 10, "scope_retention_years": {"kms": 12}}, "bucket": {"name": "example-audit", "project": "example-project", "prefix": "audit/production/", "credentials_file": "/run/secrets/eudi-wallet/audit-bucket-service-account.json"}, "secret": ["audit-bucket", "sa.json"]}' \
  "${shamir[@]}" --set organisationWallet.audit.retentionYears=10 --set organisationWallet.audit.scopeRetentionYears.kms=12 \
  --set organisationWallet.audit.bucket.name=example-audit --set organisationWallet.audit.bucket.project=example-project \
  --set organisationWallet.audit.bucket.prefix=audit/production/ --set organisationWallet.audit.bucket.credentials.existingSecret=audit-bucket \
  --set organisationWallet.audit.bucket.credentials.key=sa.json
audit "bucket with the Google default credentials" '{"audit": {"retention_years": 7}, "bucket": {"name": "example-audit"}, "secret": null}' \
  "${shamir[@]}" --set organisationWallet.audit.bucket.name=example-audit
guard "audit bucket service account without bucket" "organisationWallet.audit.bucket.credentials.existingSecret needs organisationWallet.audit.bucket.name" \
  "${shamir[@]}" --set organisationWallet.audit.bucket.credentials.existingSecret=audit-bucket
guard "audit bucket name" "organisationWallet.audit.bucket.name" "${shamir[@]}" --set organisationWallet.audit.bucket.name=Audit_Bucket
guard "audit bucket prefix" "organisationWallet.audit.bucket.prefix" "${shamir[@]}" --set organisationWallet.audit.bucket.name=example-audit --set organisationWallet.audit.bucket.prefix=/audit
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

# --- 6. Install and upgrade --------------------------------------------------------
# The order of the hooks of an upgrade (tests/check_hook_order.py, no
# cluster): the Jobs of the hooks find their Secrets, ConfigMaps, databases
# and users when they start. The new release has all components on; the
# earlier release has the values of each case.
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
  upgrade_order "with the same values" "$database"
  upgrade_order "that turns the organisation wallet on" "$database" --set organisationWallet.enabled=false \
    --set gateway.upstreams.walletConfig.url=http://wallet.example.org
  upgrade_order "that turns consent on" "$database" --set consent.enabled=false --set gateway.upstreams.consent.url=http://consent.example.org
  upgrade_order "that turns the api on" "$database" --set api.enabled=false
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
    if (doc["kind"], doc["metadata"]["name"]) in (("Secret", "t-postgres"), ("Secret", "t-read-access"), ("ConfigMap", "t-db-init"), ("Job", "t-db-init")):
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
    if doc and doc["metadata"]["name"] in ("t-postgres", "t-read-access", "t-wallet-database-roles"):
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

echo "result: ${pass} passed, ${fail} failed"
[ "$fail" -eq 0 ]
