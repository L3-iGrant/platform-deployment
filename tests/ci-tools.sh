#!/usr/bin/env bash
# Installs the test tools for the CI workflow (.github/workflows/tests.yaml)
# into a folder and adds it to the PATH of the next steps (GITHUB_PATH):
# helm, kubeconform and nats-server (pinned versions; each archive is checked
# against its SHA-256), and a Python virtual environment with PyYAML. Linux
# x86-64 only.
#
# Usage: tests/ci-tools.sh <folder>
#   HELM_VERSION: 4.3.2 (the default) or 3.22.1. The chart tests pass with
#   both.
set -euo pipefail

tools="${1:?usage: tests/ci-tools.sh <folder>}"
mkdir -p "$tools/bin"
tools="$(cd "$tools" && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# fetch <url> <sha256>: download into $work and check the SHA-256.
fetch() {
  local file="$work/${1##*/}"
  curl -fsSL --retry 3 -o "$file" "$1"
  echo "$2  $file" | sha256sum -c --quiet -
  printf '%s' "$file"
}

# helm, a version that the chart tests use.
helm_version="${HELM_VERSION:-4.3.2}"
case "$helm_version" in
  3.22.1) helm_sha256=896cf63684a42a723d61c980369d6e588330927deb13676ca0d85006dd6da0ea ;;
  4.3.2) helm_sha256=d1c0278d46beab79582d7e50f5b3dc206944ba8e577cde618513fd07daa53983 ;;
  *) echo "ci-tools: HELM_VERSION must be 3.22.1 or 4.3.2, not $helm_version" >&2; exit 2 ;;
esac
archive="$(fetch "https://get.helm.sh/helm-v${helm_version}-linux-amd64.tar.gz" "$helm_sha256")"
tar -xzf "$archive" -C "$work" linux-amd64/helm
install -m 0755 "$work/linux-amd64/helm" "$tools/bin/helm"

# kubeconform 0.8.0, for the schema check in tests/render-matrix.sh.
archive="$(fetch https://github.com/yannh/kubeconform/releases/download/v0.8.0/kubeconform-linux-amd64.tar.gz 9bc2bffbf71f261128533edaf912153948b7ff238f9a531ae6d34466ec287883)"
tar -xzf "$archive" -C "$work" kubeconform
install -m 0755 "$work/kubeconform" "$tools/bin/kubeconform"

# nats-server 2.14.10, the version of nats.image, to test the rendered
# configuration with nats-server -t.
archive="$(fetch https://github.com/nats-io/nats-server/releases/download/v2.14.10/nats-server-v2.14.10-linux-amd64.tar.gz 464f118a8aecf293e405514c1ab2c197a5d9209e58e36a5d05ad9577e5ee9b99)"
tar -xzf "$archive" -C "$work" nats-server-v2.14.10-linux-amd64/nats-server
install -m 0755 "$work/nats-server-v2.14.10-linux-amd64/nats-server" "$tools/bin/nats-server"

# Python with PyYAML, for the checks of the renders and the Compose files.
python3 -m venv "$tools/venv"
"$tools/venv/bin/pip" install --quiet --disable-pip-version-check PyYAML==6.0.3

"$tools/bin/helm" version --short
"$tools/bin/kubeconform" -v
"$tools/bin/nats-server" --version
"$tools/venv/bin/python3" -c 'import yaml; print("PyYAML", yaml.__version__)'
if [ -n "${GITHUB_PATH:-}" ]; then
  echo "$tools/venv/bin" >> "$GITHUB_PATH"
  echo "$tools/bin" >> "$GITHUB_PATH"
fi
