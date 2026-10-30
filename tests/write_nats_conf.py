#!/usr/bin/env python3
"""Writes the NATS configuration of one "helm template" output to a folder,
for "nats-server -t" (no server starts).

Usage: write_nats_conf.py <render.yaml> <folder>

The folder gets nats.conf of the ConfigMap <release>-nats, with the paths
of the TLS files, of the data and of the pid file in the folder, and the
files tls.crt, tls.key and ca.crt of the TLS Secret <release>-nats-tls of
the render (the test values of the chart: helm template makes a new CA). The
test nkeys of tests/values/keys.yaml are not valid nkeys: each one becomes a
valid public nkey made from its name (no secret).
"""

import base64
import hashlib
import os
import re
import sys

import yaml

RELEASE = "t"


def crc16(data: bytes) -> int:
    """The CRC-16 (XMODEM) of an nkey."""
    crc = 0
    for byte in data:
        crc ^= byte << 8
        for _ in range(8):
            crc = ((crc << 1) ^ 0x1021) & 0xFFFF if crc & 0x8000 else (crc << 1) & 0xFFFF
    return crc


def public_nkey(name: str) -> str:
    """A valid public user nkey (prefix U) made from a name."""
    data = bytes([20 << 3]) + hashlib.sha256(name.encode()).digest()
    return base64.b32encode(data + crc16(data).to_bytes(2, "little")).decode().rstrip("=")


def main() -> int:
    render, folder = sys.argv[1:3]
    docs = [doc for doc in yaml.safe_load_all(open(render, encoding="utf-8")) if doc]
    config = next(d for d in docs if d.get("kind") == "ConfigMap" and d["metadata"]["name"] == f"{RELEASE}-nats")["data"]["nats.conf"]
    secret = next(d for d in docs if d.get("kind") == "Secret" and d["metadata"]["name"] == f"{RELEASE}-nats-tls")["data"]
    os.makedirs(folder, exist_ok=True)
    for key in ("tls.crt", "tls.key", "ca.crt"):
        with open(os.path.join(folder, key), "wb") as handle:
            handle.write(base64.b64decode(secret[key]))
    config = config.replace("/etc/nats-tls", folder).replace('"/data"', f'"{folder}/data"').replace("/var/run/nats/nats.pid", f"{folder}/nats.pid")
    config = re.sub(r'nkey: "(UTEST[A-Z]+)"', lambda match: f'nkey: "{public_nkey(match.group(1))}"', config)
    with open(os.path.join(folder, "nats.conf"), "w", encoding="utf-8") as handle:
        handle.write(config)
    return 0


if __name__ == "__main__":
    sys.exit(main())
