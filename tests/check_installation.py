#!/usr/bin/env python3
"""Checks the services of the installation in one "helm template" output.

Usage: check_installation.py <render.yaml> <case>

The cases:
  all              all services in this release: no Installation section,
                   the upstreams, read users, trusts, NATS users and
                   Valkey users of consent and of the wallet
  consent-elsewhere
                   consent of another release (gateway.upstreams.consent.url):
                   the same as all, the consent upstream is the URL, no
                   consent object
  wallet-elsewhere the wallet of another release
                   (gateway.upstreams.walletConfig.url): the same as all,
                   the wallet config upstream is the URL, no wallet object
  no-consent       consent is not installed
  no-wallet        the wallet is not installed

When a service is not installed: Installation.services in the api, webhook
and gateway files (and in no other object) names the other service; the
gateway file has no upstream of the service; the release has no object of
the service; no process reads its views (ReadAccess, read_access, the read
access Secret, the mounted password files); no process trusts its keys (the
trusted issuers and the service keys volumes); nats.conf has no user of the
service; the bundled Valkey has no user of the wallet. Without the wallet,
the consent file has no key ReadAccess.wallet, the NATS user of consent has
no rights of the consumers of the wallet events (consent-dda-present-proof,
consent-dda-presentation), consent has no read access Job for the reader
wallet (and without consent, the wallet has no read access Job for the
reader consent), the api file has no OpenIdDeployment and the dashboard has no
walletUrl.
"""

import json
import sys

import yaml

RELEASE = "t"
CONSENT_ISSUER = "igrant-consent-management"
WALLET_ISSUER = "eudi-wallet"

CASES = {
    "all": {"consent": "here", "wallet": "here"},
    "consent-elsewhere": {"consent": "http://consent.example.org", "wallet": "here"},
    "wallet-elsewhere": {"consent": "here", "wallet": "http://wallet.example.org"},
    "no-consent": {"consent": None, "wallet": "here"},
    "no-wallet": {"consent": "here", "wallet": None},
}


def main() -> int:
    path, case = sys.argv[1:3]
    expected = CASES[case]
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

    consent, wallet = expected["consent"], expected["wallet"]
    services = [name for name, where in (("wallet", wallet), ("consent", consent)) if where]
    want = None if len(services) == 2 else {"services": services}

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

    # The upstreams of the gateway.
    upstreams = files[(f"{RELEASE}-gateway", "config.yaml")]["Gateway"]["upstreams"]
    for service, upstream, where, own in (("consent", "consent", consent, f"http://{RELEASE}-consent.ow.svc:80"),
                                          ("wallet", "walletConfig", wallet, f"http://{RELEASE}-wallet-config.ow.svc:80")):
        url = (upstreams.get(upstream) or {}).get("url")
        if where is None:
            check(upstream not in upstreams, f"the gateway has the upstream {upstream} without {service}")
        else:
            check(url == (own if where == "here" else where), f"the gateway upstream {upstream} is {url!r}")

    # The objects of a service that this release does not run.
    def objects(prefixes: tuple) -> list:
        return sorted(f"{d['kind']} {d['metadata']['name']}" for d in docs
                      if d["metadata"]["name"].startswith(prefixes))
    if consent != "here":
        check(not objects((f"{RELEASE}-consent",)), f"objects of consent: {objects((f'{RELEASE}-consent',))}")
    if wallet != "here":
        prefixes = (f"{RELEASE}-wallet", f"{RELEASE}-openbao")
        check(not objects(prefixes), f"objects of the wallet: {objects(prefixes)}")

    # The views: ReadAccess of the api files and of consent, read_access of
    # the wallet config role, the read access Secret, the mounted password
    # files.
    for key in ("api.yaml", "webhook.yaml"):
        owners = sorted((files[(f"{RELEASE}-api", key)].get("ReadAccess") or {}))
        check(owners == (["wallet"] if wallet else []), f"{key} ReadAccess is {owners}")
    consent_file = config_map(f"{RELEASE}-consent").get("config.yaml")
    if consent == "here":
        read_access = yaml.safe_load(consent_file)["ReadAccess"]
        owners = sorted(read_access)
        check(owners == (["api", "wallet"] if wallet else ["api"]), f"consent ReadAccess is {owners}")
        # Without the wallet, no key ReadAccess.wallet at all: consent
        # refuses a key without a value.
        check(("wallet" in read_access) == bool(wallet), f"consent ReadAccess.wallet: {'wallet' in read_access}")
        check(wallet is None or read_access.get("wallet"), "consent ReadAccess.wallet has no value")
    wallet_file = config_map(f"{RELEASE}-wallet").get("config.yaml")
    if wallet == "here":
        owners = sorted(yaml.safe_load(wallet_file)["read_access"])
        check(owners == (["api", "consent"] if consent else ["api"]), f"wallet read_access is {owners}")
    readers = sorted((find("Secret", f"{RELEASE}-read-access") or {}).get("data") or {})
    pairs = []
    if wallet:
        pairs.append("api-wallet")
    if consent == "here":
        pairs += ["consent-api"] + (["consent-wallet"] if wallet else [])
    if wallet == "here":
        pairs += ["wallet-api"] + (["wallet-consent"] if consent else [])
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
        check(files_of == (["read-access-wallet-password"] if wallet else []), f"{name} mounts {files_of}")
        issuers = sorted(["igrant-api.json"] + ([f"{CONSENT_ISSUER}.json"] if consent else [])
                         + ([f"{WALLET_ISSUER}.json"] if wallet else []))
        check(service_keys(doc) == issuers, f"{name} mounts the service keys {service_keys(doc)}")
    if consent == "here":
        doc = find("Deployment", f"{RELEASE}-consent")
        files_of = [path for path in mounted(doc) if path.startswith("read-access-")]
        want_files = ["read-access-api-password"] + (["read-access-wallet-password"] if wallet else [])
        check(files_of == want_files, f"consent mounts {files_of}")
        keys = sorted(["igrant-api.json"] + ([f"{WALLET_ISSUER}.json"] if wallet else []))
        check(service_keys(doc) == keys, f"consent mounts the service keys {service_keys(doc)}")
        trusted = sorted(item["issuer"] for item in yaml.safe_load(consent_file)["ServiceEnvelope"]["trustedIssuers"])
        check(trusted == sorted(["igrant-api"] + ([WALLET_ISSUER] if wallet else [])), f"consent trusts {trusted}")
    if wallet == "here":
        doc = find("Deployment", f"{RELEASE}-wallet-config")
        files_of = [path for path in mounted(doc) if path.startswith("read-access-")]
        want_files = ["read-access-api-password"] + (["read-access-consent-password"] if consent else [])
        check(files_of == want_files, f"the wallet config role mounts {files_of}")

    # The trusts of the api: igrant-api and the installed services.
    for key in ("api.yaml", "webhook.yaml"):
        trusted = [item["issuer"] for item in files[(f"{RELEASE}-api", key)]["ServiceEnvelope"]["trustedIssuers"]]
        want_trusted = ["igrant-api"] + ([CONSENT_ISSUER] if consent else []) + ([WALLET_ISSUER] if wallet else [])
        check(trusted == want_trusted, f"{key} trusts {trusted}")
        has_wallet_url = "OpenIdDeployment" in files[(f"{RELEASE}-api", key)]
        check(has_wallet_url == bool(wallet), f"{key} OpenIdDeployment: {has_wallet_url}")

    # nats.conf: no user of a service that is not installed.
    nats = config_map(f"{RELEASE}-nats").get("nats.conf", "")
    for user, where in (("# consent", consent), ("# wallet-config", wallet), ("# wallet-service", wallet),
                        ("# wallet-worker", wallet)):
        check((user in nats) == bool(where), f"nats.conf: the user {user[2:]} is {'missing' if where else 'there'}")
    # The rights of the consent user: the consumers of the wallet events
    # (consent-dda-present-proof, consent-dda-presentation) only with the
    # wallet.
    lines = nats.split("\n")
    consent_rights = next((lines[i + 1] for i, line in enumerate(lines) if line.strip() == "# consent"), "")
    if consent:
        check(bool(consent_rights), "nats.conf: no rights of the user consent")
        for durable in ("consent-dda-present-proof", "consent-dda-presentation"):
            check((f"OWS_MICROSERVICE.{durable}" in consent_rights) == bool(wallet),
                  f"nats.conf: the user consent {'has no' if wallet else 'has the'} rights of {durable}")
        check("API_EVENTS.consent-api-organisation" in consent_rights, "nats.conf: the user consent cannot read API_EVENTS")

    # The read access Job of consent for the reader wallet (consent
    # read-access apply --reader wallet): only when this release runs
    # consent and the wallet.
    jobs = sorted(d["metadata"]["name"] for d in docs if d["kind"] == "Job")
    reader_jobs = [name for name in jobs if name.startswith(f"{RELEASE}-consent-read-access-wallet")]
    check(bool(reader_jobs) == (consent == "here" and wallet == "here"),
          f"the read access Jobs of consent for the wallet are {reader_jobs}")
    # The read access hook of the wallet for the reader consent (wallet
    # read-access apply --reader consent): only when this release runs the
    # wallet and consent.
    reader_jobs = [name for name in jobs if name == f"{RELEASE}-wallet-read-access-consent"]
    check(bool(reader_jobs) == (consent == "here" and wallet == "here"),
          f"the read access Jobs of the wallet for consent are {reader_jobs}")

    # The bundled Valkey: the users of the wallet only with the wallet.
    users = sorted((find("Secret", f"{RELEASE}-redis-users") or {}).get("data") or {})
    wallet_users = [user for user in users if user.startswith("wallet")]
    check(bool(wallet_users) == bool(wallet), f"the Valkey users are {users}")
    acl = config_map(f"{RELEASE}-redis").get("users.acl", "")
    check(("~ows:*" in acl) == bool(wallet), "the ACL file of Valkey has the rights of the wallet" if not wallet
          else "the ACL file of Valkey has no rights of the wallet")

    # The dashboard: the wallet URL only with the wallet.
    dashboard = json.loads(config_map(f"{RELEASE}-dashboard").get("config.json", "{}"))
    check(("walletUrl" in dashboard) == bool(wallet), f"the dashboard config.json is {dashboard}")

    for problem in problems:
        print(problem)
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
