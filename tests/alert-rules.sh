#!/usr/bin/env bash
# Tests the wallet's alert rules (templates/wallet/prometheusrule.yaml) with
# promtool from a local Prometheus image. With
# organisationWallet.prometheusRule on, the render has a PrometheusRule whose
# groups pass "promtool check rules" and the unit tests in
# tests/fixtures/alert-rules-test.yaml ("promtool test rules"): a stopped
# audit export (critical after 10 minutes), a missing partition for the
# current month, too few future partitions and a late revocation; another
# namespace and a scope with 0 give no alert. Without the value, the render
# has no PrometheusRule.
#
# Usage: tests/alert-rules.sh <prometheus image>
#   The image must be local (the script never pulls), for example
#   prom/prometheus:v3.5.0.
set -euo pipefail
image="${1:?usage: tests/alert-rules.sh <prometheus image>}"
here="$(cd "$(dirname "$0")" && pwd)"
chart="$(dirname "$here")"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
pass=0
fail=0
ok() { pass=$((pass + 1)); echo "ok   $1"; }
bad() { fail=$((fail + 1)); echo "FAIL $1"; }
if ! docker image inspect "$image" > /dev/null 2>&1; then
  echo "the image $image is not local (the test never pulls)" >&2
  exit 2
fi
base=(-f "$here/values/keys.yaml" -f "$chart/profiles/site.yaml" -f "$here/values/release.yaml")
if helm template t "$chart" --namespace ow "${base[@]}" | grep -q "^kind: PrometheusRule"; then
  bad "a PrometheusRule without organisationWallet.prometheusRule.enabled"
else
  ok "no PrometheusRule by default"
fi
helm template t "$chart" --namespace ow "${base[@]}" --set organisationWallet.serviceMonitor.enabled=true \
  --set organisationWallet.prometheusRule.enabled=true --show-only templates/wallet/prometheusrule.yaml > "$work/render.yaml"
python3 -c '
import sys, yaml
rule = yaml.safe_load(open(sys.argv[1]))
assert rule["kind"] == "PrometheusRule", rule["kind"]
yaml.safe_dump({"groups": rule["spec"]["groups"]}, open(sys.argv[2], "w"), sort_keys=False)
' "$work/render.yaml" "$work/rules.yaml"
cp "$here/fixtures/alert-rules-test.yaml" "$work/test.yaml"
chmod 0755 "$work"; chmod 0644 "$work"/*
run() { docker run --rm --user 65534:65534 --read-only --tmpfs /tmp --network none -v "$work:/work:ro" -w /work --entrypoint promtool "$image" "$@"; }
if out="$(run check rules rules.yaml 2>&1)"; then ok "promtool check rules: $(grep -o '[0-9]* rules found' <<< "$out")"; else bad "promtool check rules: $out"; fi
if out="$(run test rules test.yaml 2>&1)"; then ok "promtool test rules: $(tail -1 <<< "$out")"; else bad "promtool test rules: $(tail -20 <<< "$out")"; fi
echo "result: $pass passed, $fail failed"
[ "$fail" = 0 ]
