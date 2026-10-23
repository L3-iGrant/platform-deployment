#!/usr/bin/env python3
"""Checks the key facts of one "helm template" output of the chart.

Usage: check_render.py <render.yaml> <engine> <mode> <openbao> <exposure> <networkpolicy>
  engine: postgresql | mysql; mode: bundled | external;
  openbao: shamir | external;
  exposure: ingress | gatewayAPI | none; networkpolicy: off | on.

The values are tests/values/keys.yaml, examples/site.yaml and one example
file of each group (see tests/render-matrix.sh). The script writes one line
per failed check and exits 1 when a check fails. It never prints a Secret
value: it reads only the names and the keys of the Secrets.
"""

import re
import sys

import yaml

RELEASE = "t"
NAMESPACE = "ow"
EXTERNAL_DB_HOST = "db.example.org"
EXTERNAL_OPENBAO = "https://openbao.example.org:8200"
HOSTS = {"t-api": "api.example.org", "t-wallet-service": "wallet.example.org", "t-dashboard": "dashboard.example.org"}
KEY_STORE_TYPES = ["vault", "csc", "gcp-kms", "aws-kms", "azure-key-vault"]

# Words that must not be in a render (case-insensitive).
FORBIDDEN = [
    (r"hashicorp", "the name HashiCorp"),
    (r"keycloak", "Keycloak"),
    (r"backup", "backup content"),
    (r"kms_key", "the database KMS table"),
    (r"platform: database", "the database KMS platform"),
    (r"data_key", "the KMS data key"),
    (r"\baries\b|aca-py|cloud ?agent|\bssi\b", "an Aries or SSI name"),
    (r"apikey-rotator|apiKeyRotator", "the API key rotator"),
    (r"cert-manager\.io/v1", "a cert-manager object"),
    ("\u2014", "an em dash"),
    ("\u2013", "an en dash"),
]


def main() -> int:
    path, engine, mode, openbao, exposure, netpol = sys.argv[1:7]
    with open(path, encoding="utf-8") as handle:
        text = handle.read()
    docs = [d for d in yaml.safe_load_all(text) if d]
    failures: list[str] = []

    def check(condition: bool, message: str) -> None:
        if not condition:
            failures.append(message)

    def find(kind: str, name: str):
        for doc in docs:
            if doc.get("kind") == kind and doc["metadata"]["name"] == name:
                return doc
        return None

    def config_map_file(name: str, key: str, raw: bool = False):
        cm = find("ConfigMap", name)
        if cm is None:
            failures.append(f"ConfigMap {name} is missing")
            return {}
        if key not in cm.get("data", {}):
            failures.append(f"ConfigMap {name} has no key {key}")
            return {}
        return cm["data"][key] if raw else yaml.safe_load(cm["data"][key])

    port = 3306 if engine == "mysql" else 5432
    server = f"{RELEASE}-mysql" if engine == "mysql" else f"{RELEASE}-postgres"
    host = f"{server}.{NAMESPACE}.svc" if mode == "bundled" else EXTERNAL_DB_HOST

    # --- The engine in each config file ----------------------------------
    def go_section(where: str, section: dict) -> None:
        check(section.get("type") == engine, f"{where}.type is {section.get('type')!r}, not {engine}")
        check(section.get("port") == port, f"{where}.port is {section.get('port')!r}, not {port}")
        check(section.get("hosts") == [host], f"{where}.hosts is {section.get('hosts')!r}")
        tls = section.get("tls") or {}
        check(bool(tls.get("caFile")), f"{where}.tls.caFile is missing")
        if engine == "mysql":
            check("sslMode" not in tls, f"{where}.tls.sslMode is set for mysql (no effect there)")
            check("maxConns" not in section, f"{where}.maxConns is set for mysql (no effect there)")
            check((section.get("params") or {}).get("time_zone") == "'+00:00'", f"{where}.params.time_zone is not '+00:00'")
        else:
            check(tls.get("sslMode") == "verify-full", f"{where}.tls.sslMode is {tls.get('sslMode')!r}, not verify-full")

    def wallet_section(where: str, section: dict) -> None:
        check(section.get("type") == engine, f"{where}.type is {section.get('type')!r}, not {engine}")
        check(section.get("port") == port, f"{where}.port is {section.get('port')!r}, not {port}")
        check(section.get("host") == host, f"{where}.host is {section.get('host')!r}")
        check(bool(section.get("ssl_ca_file")), f"{where}.ssl_ca_file is missing")
        if engine == "mysql":
            check("ssl_mode" not in section, f"{where}.ssl_mode is set for mysql (postgresql only)")
        else:
            check(section.get("ssl_mode") == "verify-full", f"{where}.ssl_mode is {section.get('ssl_mode')!r}, not verify-full")

    for key in ("api.yaml", "webhook.yaml"):
        api = config_map_file(f"{RELEASE}-api", key)
        if api:
            go_section(f"api {key} DataBase", api["DataBase"])
            go_section(f"api {key} Extensions.oidc.database", api["Extensions"]["oidc"]["database"])
            go_section(f"api {key} ReadAccess.wallet", api["ReadAccess"]["wallet"])
            check(api["KeyStorage"].get("allowPlainApiKeys") is False, f"api {key} KeyStorage.allowPlainApiKeys is not false")
            check(api["KeyStorage"].get("allowPlaintextProviderKeys") is False, f"api {key} KeyStorage.allowPlaintextProviderKeys is not false")
            check("PrivacyDashboardDeployment" not in api, f"api {key} has PrivacyDashboardDeployment")
    gateway = config_map_file(f"{RELEASE}-gateway", "config.yaml")
    if gateway:
        go_section("gateway DataBase", gateway["DataBase"])
    consent = config_map_file(f"{RELEASE}-consent", "config.yaml")
    if consent:
        go_section("consent DataBase", consent["DataBase"])
        for owner in ("api", "wallet"):
            go_section(f"consent ReadAccess.{owner}", consent["ReadAccess"][owner])
    consent_migrate = config_map_file(f"{RELEASE}-consent", "migrate.yaml")
    if consent_migrate:
        go_section("consent migrate.yaml DataBase", consent_migrate["DataBase"])
    openbao_address = EXTERNAL_OPENBAO if openbao == "external" else f"https://{RELEASE}-openbao.{NAMESPACE}.svc:8200"
    for role in ("service", "config", "scheduler"):
        wallet = config_map_file(f"{RELEASE}-wallet", f"{role}.yaml")
        if not wallet:
            continue
        wallet_section(f"wallet {role}.yaml database", wallet["database"])
        kms = wallet.get("kms", {})
        check(kms.get("platform") == "transit", f"wallet {role}.yaml kms.platform is {kms.get('platform')!r}, not transit")
        keys = {"platform", "local_backend", "vault", "organisation_key_store_types", "key_store_providers", "allow_private_addresses", "test_ca"}
        check(set(kms) == keys, f"wallet {role}.yaml kms has the keys {sorted(kms)}")
        check(
            kms.get("organisation_key_store_types") == KEY_STORE_TYPES
            and kms.get("key_store_providers") == {"add": [], "hide": []}
            and kms.get("allow_private_addresses") is False
            and kms.get("test_ca") == {"enabled": True, "leaf_validity_days": 365},
            f"wallet {role}.yaml kms key store settings are not the defaults",
        )
        check(kms.get("local_backend") == "openbao", f"wallet {role}.yaml kms.local_backend is {kms.get('local_backend')!r}")
        check("cloud_endpoints" not in kms, f"wallet {role}.yaml has kms.cloud_endpoints (development only)")
        login = kms.get("vault", {})
        check(login.get("addr") == openbao_address, f"wallet {role}.yaml OpenBao address is {login.get('addr')!r}")
        check(login.get("user") == "wallet" and bool(login.get("password_file")), f"wallet {role}.yaml has no OpenBao login")
        check(bool(login.get("ca_cert_file")), f"wallet {role}.yaml has no OpenBao CA")
        storage = wallet.get("storage", {})
        check(bool(storage.get("gcs_bucket")) and bool(storage.get("gcs_project")), f"wallet {role}.yaml has no storage bucket")
        if role == "config":
            for owner in ("api", "consent"):
                wallet_section(f"wallet config.yaml read_access.{owner}", wallet["read_access"][owner])
    wallet_migrate = config_map_file(f"{RELEASE}-wallet", "migrate.yaml")
    if wallet_migrate:
        wallet_section("wallet migrate.yaml database", wallet_migrate["database"])

    # The migration hooks (their own ConfigMaps).
    for name, kind in (
        (f"{RELEASE}-api-migrate", "go"),
        (f"{RELEASE}-consent-migrate", "go"),
        (f"{RELEASE}-consent-migrate-after", "go"),
        (f"{RELEASE}-wallet-migrate", "wallet"),
    ):
        hook = config_map_file(name, "config.yaml")
        if not hook:
            continue
        if kind == "go":
            go_section(f"{name} DataBase", hook["DataBase"])
            if "Extensions" in hook:
                go_section(f"{name} Extensions.oidc.database", hook["Extensions"]["oidc"]["database"])
        else:
            wallet_section(f"{name} database", hook["database"])

    # --- The database server and the Jobs --------------------------------
    pg = find("StatefulSet", f"{RELEASE}-postgres")
    my = find("StatefulSet", f"{RELEASE}-mysql")
    if mode == "bundled":
        check((my if engine == "mysql" else pg) is not None, f"the bundled server StatefulSet {server} is missing")
        check((pg if engine == "mysql" else my) is None, "the StatefulSet of the other engine is rendered")
        svc = find("Service", server)
        check(svc is not None and svc["spec"]["ports"][0]["port"] == port, f"Service {server} has not port {port}")
        tls = find("Secret", f"{server}-tls")
        check(tls is not None and set(tls.get("data", {})) == {"tls.crt", "tls.key", "ca.crt"},
              f"the TLS Secret {server}-tls is missing or has other keys")
    else:
        check(pg is None and my is None, "a database StatefulSet is rendered with mode external")
    init = [d for d in docs if d.get("kind") == "Job" and d["metadata"]["name"].startswith(f"{RELEASE}-db-init-")]
    check(len(init) == 1, "the database init Job is missing")
    init_cm = find("ConfigMap", f"{RELEASE}-db-init")
    if init_cm:
        script = init_cm["data"]["create-databases.sh"]
        if engine == "mysql":
            check("utf8mb4_bin" in script and "mariadb " in script, "the init script is not the MySQL script")
        else:
            check("CREATE ROLE" in script and "psql" in script, "the init script is not the PostgreSQL script")
    db_secret = find("Secret", server)
    if db_secret:
        keys = set(db_secret.get("data", {}))
        admin = {"MARIADB_ROOT_PASSWORD"} if engine == "mysql" else {"POSTGRES_PASSWORD"}
        expected = {"igrant_api", "igrant_oidc", "igrant_consent", "igrant_wallet"} | (admin if mode == "bundled" else set())
        check(keys == expected, f"the database Secret {server} has the keys {sorted(keys)}, not {sorted(expected)}")
    else:
        check(False, f"the database Secret {server} is missing")
    read_access = [d for d in docs if d.get("kind") == "Job" and "-read-access-" in d["metadata"]["name"]]
    check(len(read_access) == 5, f"{len(read_access)} read access Jobs, not 5")
    for doc in docs:
        if doc.get("kind") == "Job":
            spec = doc["spec"]["template"]["spec"]
            check(spec.get("automountServiceAccountToken") is False, f"Job {doc['metadata']['name']} mounts a service account token")
    readers = find("Secret", f"{RELEASE}-read-access")
    check(readers is not None and set(readers.get("data", {})) == {"api-wallet", "consent-api", "consent-wallet", "wallet-api", "wallet-consent"},
          "the read access Secret is missing or has other keys")
    check(not any(d.get("kind") == "CronJob" for d in docs), "a CronJob is rendered")

    # --- Exposure ------------------------------------------------------------
    ingresses = {d["metadata"]["name"]: d for d in docs if d.get("kind") == "Ingress"}
    routes = {d["metadata"]["name"]: d for d in docs if d.get("kind") == "HTTPRoute"}
    if exposure == "ingress":
        check(set(ingresses) == set(HOSTS) and not routes, f"the Ingresses are {sorted(ingresses)}, the routes {sorted(routes)}")
        for name, ingress in ingresses.items():
            rule = ingress["spec"]["rules"][0]
            check(rule["host"] == HOSTS[name], f"Ingress {name} has the host {rule['host']}")
            check(ingress["spec"].get("ingressClassName") == "nginx", f"Ingress {name} has no ingressClassName nginx")
    elif exposure == "gatewayAPI":
        check(set(routes) == set(HOSTS) and not ingresses, f"the routes are {sorted(routes)}, the Ingresses {sorted(ingresses)}")
        for name, route in routes.items():
            check(route["spec"]["hostnames"] == [HOSTS[name]], f"HTTPRoute {name} has the hostnames {route['spec']['hostnames']}")
            check(bool(route["spec"]["parentRefs"]), f"HTTPRoute {name} has no parentRefs")
        api_route = routes.get(f"{RELEASE}-api")
        if api_route:
            check(api_route["spec"]["rules"][0].get("timeouts", {}).get("request") == "3900s", "the api HTTPRoute has no request timeout of 3900s")
    else:
        check(not ingresses and not routes, "an Ingress or an HTTPRoute is rendered with exposure none")
    for name in ("gateway", "wallet-service", "dashboard"):
        check(find("Service", f"{RELEASE}-{name}") is not None, f"the Service {RELEASE}-{name} is missing")

    # --- NetworkPolicy ports -------------------------------------------------
    policies = [d for d in docs if d.get("kind") == "NetworkPolicy"]
    if netpol == "on":
        check(bool(policies), "no NetworkPolicy with networkPolicy.enabled")
        ports = set()
        for policy in policies:
            for rule in policy["spec"].get("egress", []):
                for target in rule.get("to", []):
                    selector = (target.get("podSelector") or {}).get("matchLabels") or {}
                    block = (target.get("ipBlock") or {}).get("cidr")
                    if selector.get("netpol.igrant.io/role") == "db" or block == "192.0.2.10/32":
                        ports |= {p["port"] for p in rule.get("ports", [])}
        check(ports == {port}, f"the database egress ports are {sorted(ports)}, not [{port}]")
        if mode == "bundled":
            ingress = find("NetworkPolicy", f"{RELEASE}-netpol-ingress-db")
            check(ingress is not None and all(p["port"] == port for r in ingress["spec"]["ingress"] for p in r["ports"]),
                  f"the database ingress policy has not port {port}")
    else:
        check(not policies, "a NetworkPolicy is rendered with networkPolicy.enabled false")

    # --- OpenBao -------------------------------------------------------------
    sts = find("StatefulSet", f"{RELEASE}-openbao")
    if openbao == "external":
        check(sts is None, "the OpenBao StatefulSet is rendered with openbao.mode external")
        check(find("Secret", f"{RELEASE}-openbao-wallet") is None, "the OpenBao wallet Secret is rendered with an external OpenBao")
    else:
        check(sts is not None, "the OpenBao StatefulSet is missing")
        check(find("Secret", f"{RELEASE}-openbao-wallet") is not None, "the OpenBao wallet Secret is missing")
        hcl = config_map_file(f"{RELEASE}-openbao", "openbao.hcl", raw=True) or ""
        # The Shamir seal: no seal and no plugin stanza.
        check(not re.search(r'^(seal|plugin|plugin_directory)\b', hcl, re.M), "the configuration has a seal or a plugin stanza")
        if sts:
            container = sts["spec"]["template"]["spec"]["containers"][0]
            env = {e["name"]: e.get("value") for e in container.get("env", [])}
            check(container["image"].split("/")[-1].startswith("openbao:"), f"the OpenBao image is {container['image']}")
            check(not sts["spec"]["template"]["spec"].get("initContainers"), "the OpenBao pods have init containers")

    # --- NATS and consent ----------------------------------------------------
    nats = find("StatefulSet", f"{RELEASE}-nats")
    check(nats is not None and len(nats["spec"]["template"]["spec"]["containers"]) == 2, "NATS has no reloader sidecar")
    nats_conf = config_map_file(f"{RELEASE}-nats", "nats.conf", raw=True) or ""
    users = re.findall(r"^\s*# (\S+)$", nats_conf, re.M)
    check(users == ["api", "api-webhook", "consent", "wallet-config", "wallet-service", "wallet-scheduler"],
          f"the NATS users are {users}")
    # The WIA pool refill event: the config and service roles publish it,
    # the scheduler subscribes to it, no other user has it.
    refill = "ows.wia_pool.refill_requested"
    for nkey, role in (("UTESTWALLETCONFIG", "config"), ("UTESTWALLETSERVICE", "service")):
        line = next((line for line in nats_conf.splitlines() if nkey in line), "")
        check(f'"{refill}"' in line.split("subscribe:")[0], f"the wallet {role} role cannot publish the WIA pool refill event")
        check(f'"{refill}"' not in line.split("subscribe:")[-1], f"the wallet {role} role subscribes to the WIA pool refill event")
    scheduler_line = next((line for line in nats_conf.splitlines() if "UTESTWALLETSCHEDULER" in line), "")
    check(f'subscribe: {{ allow: ["{refill}", "_INBOX_wallet.>"] }}' in scheduler_line, "the wallet scheduler role does not subscribe to the WIA pool refill event")
    check(f'"{refill}"' not in scheduler_line.split("subscribe:")[0], "the wallet scheduler role can publish the WIA pool refill event")
    others = [line for line in nats_conf.splitlines() if refill in line and not any(n in line for n in ("UTESTWALLETCONFIG", "UTESTWALLETSERVICE", "UTESTWALLETSCHEDULER"))]
    check(not others, "a NATS user other than the wallet roles has the WIA pool refill event")

    # --- Words that must not be in the render ------------------------------
    lowered = text.lower()
    for pattern, what in FORBIDDEN:
        check(not re.search(pattern, lowered if pattern.isascii() else text), f"the render has {what}")
    # "vault" only as the wallet config section of OpenBao (kms.vault), in
    # its comment, and as the key store type "vault" (an external OpenBao) in
    # kms.organisation_key_store_types.
    # A base64 value (Secret data, generated keys) is not text: random
    # characters can spell the word.
    for line in text.splitlines():
        if "vault" in line.lower() and not re.fullmatch(r"\s*[\w.-]+: [A-Za-z0-9+/]{40,}={0,2}", line):
            allowed = (
                re.fullmatch(r"\s*vault:", line)
                or re.fullmatch(r"\s*- vault", line)
                or re.fullmatch(r"\s*- azure-key-vault", line)
                or "kms.vault: the login of the wallet to OpenBao" in line
            )
            check(bool(allowed), f"the render has the word vault: {line.strip()[:80]}")

    for failure in failures:
        print(f"  FAIL: {failure}")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
