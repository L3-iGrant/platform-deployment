#!/usr/bin/env bash
# Installs the test tools for the CI workflow (.github/workflows/tests.yaml)
# into a folder and adds it to the PATH of the next steps (GITHUB_PATH):
# helm, kubeconform and nats-server (pinned versions; each archive is checked
# against its SHA-256), and a Python virtual environment with PyYAML. Linux
# x86-64 only.
#
# Usage: tests/ci-tools.sh <folder>
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

# helm 3.16.2, the version that the chart tests use.
archive="$(fetch https://get.helm.sh/helm-v3.16.2-linux-amd64.tar.gz 9318379b847e333460d33d291d4c088156299a26cd93d570a7f5d0c36e50b5bb)"
tar -xzf "$archive" -C "$work" linux-amd64/helm
install -m 0755 "$work/linux-amd64/helm" "$tools/bin/helm"

# kubeconform 0.6.7, for the schema check in tests/render-matrix.sh.
archive="$(fetch https://github.com/yannh/kubeconform/releases/download/v0.6.7/kubeconform-linux-amd64.tar.gz 95f14e87aa28c09d5941f11bd024c1d02fdc0303ccaa23f61cef67bc92619d73)"
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
