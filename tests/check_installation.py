#!/usr/bin/env python3
"""Checks the services of the installation in one "helm template" output.

Usage: check_installation.py <render.yaml> <case> [<optional feature> ...]

The optional features after the case are the expected
installation.optionalFeatures (none: the default, an empty list). The api,
webhook and gateway files have them as Installation.optionalFeatures, and
each file of the wallet as installation.optional_features.

The cases:
  wallet-here      this release runs the organisation wallet
  wallet-elsewhere the wallet in another release
                   (gateway.upstreams.walletConfig.url): the wallet config
                   upstream is the URL and there is no wallet object

In both cases: Installation.services is [wallet] in the api, webhook and
gateway files (and in no other object); the gateway file has the upstreams
core and walletConfig only; the api reads the wallet views (ReadAccess.wallet,
the read access Secret, the mounted password file) and trusts the keys of
the wallet (trusted issuers and service keys volume); the api file has
OpenIdDeployment; nats.conf has the users of the wallet; the bundled Valkey
has the wallet users; and the dashboard has walletUrl. With the wallet in
this release, the wallet config role reads only the api views (read_access,
its mounted password file and its read access Job).
"""

import json
import sys

import yaml

RELEASE = "t"
WALLET_ISSUER = "eudi-wallet"

CASES = {
    "wallet-here": "here",
    "wallet-elsewhere": "http://wallet.example.org",
}


def main() -> int:
    path, case = sys.argv[1:3]
    optional = sys.argv[3:]
    wallet = CASES[case]
    with open(path, encoding="utf-8") as handle:
        docs = [doc for doc in yaml.safe_load_all(handle) if doc]
    problems = []

    def check(condition: bool, message: str) -> None:
        if not condition:
            problems.append(message)

    def find(kind: str, name: str) -> dict:
        return next((d for d in docs if d["kind"] == kind and d["metadata"]["name"] == name), None)

    def config_map(name: str) -> dict:
        doc = find("ConfigMap", name)
        return (doc or {}).get("data") or {}

    want = {"optionalFeatures": optional, "services": ["wallet"]}

    # Installation: in the api, webhook and gateway files only.
    files = {
        (f"{RELEASE}-api", "api.yaml"): yaml.safe_load(config_map(f"{RELEASE}-api")["api.yaml"]),
        (f"{RELEASE}-api", "webhook.yaml"): yaml.safe_load(config_map(f"{RELEASE}-api")["webhook.yaml"]),
        (f"{RELEASE}-gateway", "config.yaml"): yaml.safe_load(config_map(f"{RELEASE}-gateway")["config.yaml"]),
    }
    for (name, key), data in files.items():
        check(data.get("Installation") == want, f"{name} {key}: Installation is {data.get('Installation')!r}, not {want!r}")
    for doc in docs:
        name = doc["metadata"]["name"]
        parts = (doc.get("data") or {}).items() if doc["kind"] == "ConfigMap" else [("", yaml.safe_dump(doc))]
        for key, text in parts:
            if (name, key) not in files and "Installation:" in str(text):
                problems.append(f"{doc['kind']} {name} {key} has Installation")

    # The optional features in each file of the wallet (installation.optional_features).
    if wallet == "here":
        wallet_files = config_map(f"{RELEASE}-wallet")
        check(bool(wallet_files), "the wallet has no ConfigMap")
        for key, text in wallet_files.items():
            if key.endswith(".yaml"):
                data = yaml.safe_load(text) or {}
                got = (data.get("installation") or {}).get("optional_features")
                check(got == optional, f"{RELEASE}-wallet {key}: installation.optional_features is {got!r}, not {optional!r}")

    # Gateway upstreams: the api core and the wallet config role.
    upstreams = files[(f"{RELEASE}-gateway", "config.yaml")]["Gateway"]["upstreams"]
    check(sorted(upstreams) == ["core", "walletConfig"], f"the gateway upstreams are {sorted(upstreams)}")
    url = (upstreams.get("walletConfig") or {}).get("url")
    own = f"http://{RELEASE}-wallet-config.ow.svc:80"
    check(url == (own if wallet == "here" else wallet), f"the gateway upstream walletConfig is {url!r}")

    # The objects of the wallet when this release does not run it.
    if wallet != "here":
        prefixes = (f"{RELEASE}-wallet", f"{RELEASE}-openbao")
        found = sorted(f"{d['kind']} {d['metadata']['name']}" for d in docs if d["metadata"]["name"].startswith(prefixes))
        check(not found, f"wallet objects: {found}")

    # Views: ReadAccess in the api files, read_access of the wallet config
    # role, the read access Secret, and the mounted password files.
    for key in ("api.yaml", "webhook.yaml"):
        owners = sorted((files[(f"{RELEASE}-api", key)].get("ReadAccess") or {}))
        check(owners == ["wallet"], f"{key} ReadAccess is {owners}")
    if wallet == "here":
        owners = sorted((yaml.safe_load(config_map(f"{RELEASE}-wallet").get("config.yaml") or "") or {}).get("read_access") or {})
        check(owners == ["api"], f"wallet read_access is {owners}")
    readers = sorted((find("Secret", f"{RELEASE}-read-access") or {}).get("data") or {})
    pairs = ["api-wallet"] + (["wallet-api"] if wallet == "here" else [])
    check(readers == sorted(pairs), f"the read access Secret has {readers}, not {sorted(pairs)}")

    def mounted(doc: dict) -> list:
        spec = doc["spec"]["template"]["spec"]
        return sorted(item["path"] for volume in spec.get("volumes", []) if "projected" in volume
                      for source in volume["projected"]["sources"] if "secret" in source
                      for item in source["secret"].get("items", []))

    def service_keys(doc: dict) -> list:
        spec = doc["spec"]["template"]["spec"]
        return sorted(item["key"] for volume in spec.get("volumes", []) if volume["name"] == "service-keys"
                      for item in volume["configMap"]["items"])

    for name in (f"{RELEASE}-api", f"{RELEASE}-webhook"):
        doc = find("Deployment", name)
        files_of = [path for path in mounted(doc) if path.startswith("read-access-")]
        check(files_of == ["read-access-wallet-password"], f"{name} mounts {files_of}")
        check(service_keys(doc) == ["eudi-wallet.json", "igrant-api.json"], f"{name} mounts the service keys {service_keys(doc)}")
    if wallet == "here":
        doc = find("Deployment", f"{RELEASE}-wallet-config")
        files_of = [path for path in mounted(doc) if path.startswith("read-access-")] if doc else []
        check(files_of == ["read-access-api-password"], f"the wallet config role mounts {files_of}")

    # The api trusts igrant-api and the wallet, and has the URL of the wallet.
    for key in ("api.yaml", "webhook.yaml"):
        trusted = [item["issuer"] for item in files[(f"{RELEASE}-api", key)]["ServiceEnvelope"]["trustedIssuers"]]
        check(trusted == ["igrant-api", WALLET_ISSUER], f"{key} trusts {trusted}")
        check("OpenIdDeployment" in files[(f"{RELEASE}-api", key)], f"{key} has no OpenIdDeployment")

    # nats.conf: the users of the api and of the wallet.
    nats = config_map(f"{RELEASE}-nats").get("nats.conf", "")
    lines = nats.split("\n")
    users = sorted(line.strip()[2:] for i, line in enumerate(lines)
                   if line.strip().startswith("# ") and i + 1 < len(lines) and lines[i + 1].strip().startswith("{ nkey:"))
    want_users = ["api", "api-webhook", "wallet-config", "wallet-service", "wallet-worker"]
    check(sorted(set(users) - {"wallet-signer-manager"}) == want_users, f"nats.conf has the users {users}")

    # The wallet's read access hook: only for the reader api.
    jobs = sorted(d["metadata"]["name"] for d in docs if d["kind"] == "Job")
    reader_jobs = [name for name in jobs if name.startswith(f"{RELEASE}-wallet-read-access-")]
    check(reader_jobs == ([f"{RELEASE}-wallet-read-access-api"] if wallet == "here" else []),
          f"the wallet's read access Jobs are {reader_jobs}")

    # Bundled Valkey: the wallet users.
    valkey = sorted((find("Secret", f"{RELEASE}-redis-users") or {}).get("data") or {})
    check(any(user.startswith("wallet") for user in valkey), f"the Valkey users are {valkey}")
    acl = config_map(f"{RELEASE}-redis").get("users.acl", "")
    check("~ows:*" in acl, "the ACL file of Valkey has no rights of the wallet")

    # Dashboard: walletUrl.
    dashboard = json.loads(config_map(f"{RELEASE}-dashboard").get("config.json", "{}"))
    check("walletUrl" in dashboard, f"the dashboard config.json is {dashboard}")

    for problem in problems:
        print(problem)
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
