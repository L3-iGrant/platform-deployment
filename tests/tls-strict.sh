#!/usr/bin/env bash
# Tests the TLS certificates that the chart creates (genCA and genSignedCert
# in templates/secrets.yaml, for the bundled PostgreSQL, OpenBao, NATS and
# Valkey) against the strict RFC 5280 checks that Python 3.13 applies by
# default (ssl.create_default_context sets VERIFY_X509_STRICT). The wallet
# image runs Python 3.13 and refuses a server certificate without an
# authority key identifier, and a CA without a subject key identifier, key
# usage or critical basic constraints.
#
# For each TLS Secret of a render:
# 1. openssl verify -x509_strict -purpose sslserver (the local OpenSSL);
# 2. a TLS connection in a Python 3.13 container: a server with tls.crt and
#    tls.key, and a strict client with ssl.create_default_context(cafile=
#    ca.crt) that checks the certificate's service name.
# 3. A control: a CA without a subject key identifier and a server
#    certificate without an authority key identifier. Both checks must
#    refuse them, which proves that the test detects the fault.
#
# Usage: tests/tls-strict.sh <Python 3.13 image>
#   For example python:3.13-slim-trixie. The image must be local (the
#   script never pulls). The containers have no network.
set -euo pipefail

image="${1:?usage: tests/tls-strict.sh <Python 3.13 image>}"
here="$(cd "$(dirname "$0")" && pwd)"
chart="$(dirname "$here")"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
pass=0
fail=0
ok() { pass=$((pass + 1)); echo "ok   $1"; }
bad() { fail=$((fail + 1)); echo "FAIL $1"; }

docker run --rm --pull never --network none "$image" python -c '
import ssl, sys
assert sys.version_info >= (3, 13), sys.version
assert ssl.create_default_context().verify_flags & ssl.VERIFY_X509_STRICT, "no VERIFY_X509_STRICT"
' || { echo "FAIL $image is not Python 3.13 with VERIFY_X509_STRICT by default"; exit 1; }

# The Python check: a server with the certificate and a client with the CA.
cat > "$work/handshake.py" <<'PY'
"""A TLS connection on 127.0.0.1: the server has the certificate, the client
checks it with the CA and the name (the default context of Python 3.13 is
strict). Exit 0: the client accepts; exit 1: it refuses (the reason on
stderr)."""
import socket
import ssl
import sys
import threading

folder, name = sys.argv[1], sys.argv[2]
server = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
server.load_cert_chain(f"{folder}/tls.crt", f"{folder}/tls.key")
client = ssl.create_default_context(cafile=f"{folder}/ca.crt")
assert client.verify_flags & ssl.VERIFY_X509_STRICT
listener = socket.create_server(("127.0.0.1", 0))
port = listener.getsockname()[1]


def serve():
    connection, _ = listener.accept()
    try:
        with server.wrap_socket(connection, server_side=True) as tls:
            tls.recv(1)
    except (ssl.SSLError, OSError):
        pass


threading.Thread(target=serve, daemon=True).start()
try:
    with socket.create_connection(("127.0.0.1", port)) as raw:
        with client.wrap_socket(raw, server_hostname=name) as tls:
            tls.sendall(b"x")
    print(f"accepted {name}")
except ssl.SSLCertVerificationError as error:
    print(f"refused {name}: {error.verify_message}", file=sys.stderr)
    sys.exit(1)
PY

# check <label> <folder with ca.crt tls.crt tls.key> <expected: accept|refuse>
check() {
  local label="$1" folder="$2" expect="$3" name openssl_result python_result
  # The certificate's service name (the name that the wallet checks).
  names="$(openssl x509 -in "$folder/tls.crt" -noout -ext subjectAltName 2>/dev/null | tr ',' '\n' | sed -n 's/^ *DNS://p')"
  name="$(grep -m1 '\.svc$' <<< "$names" || head -1 <<< "$names")"
  openssl_result="$(openssl verify -x509_strict -purpose sslserver -CAfile "$folder/ca.crt" "$folder/tls.crt" 2>&1)" && openssl_ok=1 || openssl_ok=0
  python_result="$(docker run --rm --pull never --network none --read-only --user 65532:65532 -v "$folder:/certs:ro" -v "$work/handshake.py:/handshake.py:ro" \
    "$image" python -I /handshake.py /certs "$name" 2>&1)" && python_ok=1 || python_ok=0
  if [ "$expect" = accept ] && [ "$openssl_ok" = 1 ] && [ "$python_ok" = 1 ]; then
    ok "$label: openssl verify -x509_strict and Python 3.13 accept it ($name)"
  elif [ "$expect" = refuse ] && [ "$openssl_ok" = 0 ] && [ "$python_ok" = 0 ]; then
    ok "$label: openssl verify -x509_strict and Python 3.13 refuse it ($(printf '%s' "$python_result" | tail -1 | cut -c1-90))"
  else
    bad "$label: expected $expect; openssl: $(printf '%s' "$openssl_result" | tail -1); python: $(printf '%s' "$python_result" | tail -1)"
  fi
}

# 1 and 2: the TLS Secrets of a render with all bundled servers.
helm template t "$chart" --namespace ow -f "$here/values/keys.yaml" -f "$chart/profiles/site.yaml" -f "$here/values/release.yaml" \
  --show-only templates/secrets.yaml > "$work/secrets.yaml"
python3 - "$work/secrets.yaml" "$work" <<'PY'
import base64, os, sys, yaml
for doc in yaml.safe_load_all(open(sys.argv[1])):
    if doc and doc.get("kind") == "Secret" and {"ca.crt", "tls.crt", "tls.key"} <= set(doc.get("data") or {}):
        folder = os.path.join(sys.argv[2], doc["metadata"]["name"])
        os.makedirs(folder)
        for key in ("ca.crt", "tls.crt", "tls.key"):
            path = os.path.join(folder, key)
            with open(path, "wb") as handle:
                handle.write(base64.b64decode(doc["data"][key]))
            os.chmod(path, 0o644)
        os.chmod(folder, 0o755)
        print(doc["metadata"]["name"])
PY
secrets=0
for folder in "$work"/t-*-tls; do
  secrets=$((secrets + 1))
  check "$(basename "$folder")" "$folder" accept
done
[ "$secrets" -ge 4 ] && ok "the render has $secrets TLS Secrets (PostgreSQL, OpenBao, NATS, Valkey)" || bad "only $secrets TLS Secrets in the render"

# 3: the control. A CA without a subject key identifier, and a server
# certificate without an authority key identifier.
control="$work/control"
mkdir -m 755 "$control"
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 1 -subj "/CN=control-ca" \
  -addext "basicConstraints=critical,CA:TRUE" -addext "keyUsage=critical,keyCertSign" \
  -addext "subjectKeyIdentifier=none" -addext "authorityKeyIdentifier=none" \
  -keyout "$control/ca.key" -out "$control/ca.crt" 2> /dev/null
openssl req -new -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -subj "/CN=control.ow.svc" \
  -keyout "$control/tls.key" -out "$control/tls.csr" 2> /dev/null
printf '%s\n' 'basicConstraints = critical, CA:false' 'keyUsage = critical, digitalSignature' 'extendedKeyUsage = serverAuth' \
  'subjectAltName = DNS:control.ow.svc' 'subjectKeyIdentifier = none' 'authorityKeyIdentifier = none' > "$control/server.ext"
openssl x509 -req -in "$control/tls.csr" -CA "$control/ca.crt" -CAkey "$control/ca.key" -set_serial 1 -days 1 \
  -extfile "$control/server.ext" -out "$control/tls.crt" 2> /dev/null
chmod 644 "$control"/*
check "control (no key identifiers)" "$control" refuse

echo "result: ${pass} passed, ${fail} failed"
[ "$fail" -eq 0 ]
