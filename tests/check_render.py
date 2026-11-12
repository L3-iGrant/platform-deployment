#!/usr/bin/env python3
"""Checks the key facts of one "helm template" output of the chart.

Usage: check_render.py <render.yaml> <engine> <mode> <openbao> <exposure> <networkpolicy> [<database-logs> [<redis>]]
  engine: postgresql; mode: bundled | external;
  openbao: shamir | external;
  exposure: ingress | gatewayAPI | none | on-premise (only the wallet host
    on the public IngressClass); networkpolicy: off | on;
  database-logs: on (default) | off (database.postgresql.logDdlAndConnections
    false);
  redis: bundled (default) | external (examples/redis-external.yaml).

The values are tests/values/keys.yaml, examples/site.yaml and one example
file of each group (see tests/render-matrix.sh). The script writes one line
per failed check and exits 1 when a check fails. It never prints a Secret
value: it reads only the names and the keys of the Secrets.
"""

import base64
import json
import re
import sys

import yaml

RELEASE = "t"
NAMESPACE = "ow"
EXTERNAL_DB_HOST = "db.example.org"
EXTERNAL_OPENBAO = "https://openbao.example.org:8200"
HOSTS = {"t-api": "api.example.org", "t-wallet-service": "wallet.example.org", "t-dashboard": "dashboard.example.org"}
# The public path of the routes of the OIDC provider extension of the api
# (Extensions.oidc.apiPathBase and qrPollPrefix of the api configuration).
OIDC_PROVIDER_PATH = "/v4/service/platform/extension/oidc"
KEY_STORE_TYPES = ["vault", "csc", "gcp-kms", "aws-kms", "azure-key-vault"]
# The facts of each engine of the chart helper ow.db.engines: the name
# suffix of the bundled server, the port and the admin password key.
ENGINES = {"postgresql": {"server": "postgres", "port": 5432, "admin_key": "POSTGRES_PASSWORD"}}
# The server parameters of the DDL and connection logs of the bundled
# server (database.postgresql.logDdlAndConnections).
DATABASE_LOGS = {"log_statement": "ddl", "log_connections": "on", "log_disconnections": "on"}
# The audit log and the retention purge of the wallet with the defaults of
# the values: the retention of the audit events in every wallet file and in
# the migration hook, no audit bucket.
AUDIT = {"retention_years": 7}
RETENTION = {"soft_deleted_days": 30, "deactivated_organisation_days": 30, "deactivated_sandbox_days": 7,
             "dead_letter_days": 30, "login_code_days": 1, "verifier_response_key_days": 1,
             "issued_credential_token_days": 30, "batch_size": 500}
# Valkey: the ACL user of each process (the values key and the user name),
# the settings of the data servers (WORKERS-AND-REDIS-PLAN.md section 2.7)
# and the rights of the wallet users (the rights of the wallet tests,
# organisation-wallet-suite ows/testing/redis_servers.py).
REDIS_USERS = {"walletService": "wallet-service", "walletConfig": "wallet-config", "walletWorker": "wallet-worker", "walletClock": "wallet-clock",
               "gateway": "gateway"}
# The wallet processes with the defaults of the values: the configuration
# key of each (ConfigMap <release>-wallet), its Deployment, its Valkey
# user and its database role. The worker groups of
# organisationWallet.workers.groups: their queues, replicas, processes,
# threads, shutdown timeout and grace period.
WORKER_GROUPS = {
    "main": (["realtime", "attestation", "status", "kms"], 2, 1, 8, 600, 630),
    "maintenance": (["maintenance"], 1, 1, 2, 14400, 14430),
}
WALLET_PROCESSES = {
    "service.yaml": ("wallet-service", "walletService", "launcher_app"),
    "config.yaml": ("wallet-config", "walletConfig", "launcher_app"),
    **{f"worker-{name}.yaml": (f"wallet-worker-{name}", "walletWorker", "jobs") for name in WORKER_GROUPS},
    "clock.yaml": ("wallet-clock", "walletClock", "clock"),
}
# The files of the processes with the KMS, the trust list and the audit
# log (all but the clock, which only sends the cron actors).
KMS_FILES = [key for key in WALLET_PROCESSES if key != "clock.yaml"]
WORKER_FILES = [f"worker-{name}.yaml" for name in WORKER_GROUPS]
REDIS_SETTINGS = ["port 0", "tls-port 6379", "tls-auth-clients no", "tls-replication yes", "appendonly yes", "appendfsync everysec",
                  "maxmemory-policy noeviction", "min-replicas-to-write 1", "min-replicas-max-lag 10", "masteruser replication",
                  "masterauth {password:replication}", "replica-announce-ip {self}", "aclfile /run/valkey/users.acl"]
REDIS_WALLET_RIGHTS = "resetchannels ~ows:* ~ows-wallet ~ows-wallet:* -@all +@read +@write +@scripting +@connection -@dangerous +info +keys"
REDIS_IMAGE = "docker.io/valkey/valkey@sha256:081c2f5cb575efc901aa80ff9cdbd1ec6a301682fd35e1ebb4b0990a4a4a8507"
# The values of examples/redis-external.yaml.
REDIS_EXTERNAL_SENTINELS = ["redis-1.example.org:26379", "redis-2.example.org:26379", "redis-3.example.org:26379"]
REDIS_EXTERNAL_CIDRS = {"192.0.2.50/32", "192.0.2.51/32", "192.0.2.52/32"}

# The NATS durables of the api that the contract removed (contract/v2
# streams.json removedConsumers): the API core and the webhook handler can
# only read and delete them.
API_RETIRED_DURABLES = ["api-wua-revocation", "api-webhook-issue-credential", "api-webhook-issuer-event", "api-webhook-credential",
                        "api-webhook-present-proof", "api-webhook-presentation"]
WALLET_NATS_USERS = ["wallet-config", "wallet-service", "wallet-worker"]

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
    (r"allowplainapikeys", "the removed api setting of the plain API key window"),
    (r"cert-manager\.io/v1", "a cert-manager object"),
    ("\u2014", "an em dash"),
    ("\u2013", "an en dash"),
]


def nats_rights(nats_conf: str) -> dict:
    """The publish and subscribe subjects of each user of nats.conf, by the name in its comment."""
    rights, name = {}, None
    for line in nats_conf.splitlines():
        match = re.match(r"^\s*# (\S+)$", line)
        if match:
            name = match.group(1)
        elif name and "nkey:" in line:
            lists = {kind: re.search(kind + r": \{ allow: \[(.*?)\] \}", line) for kind in ("publish", "subscribe")}
            rights[name] = {kind: set(re.findall(r'"([^"]*)"', found.group(1))) if found else set() for kind, found in lists.items()}
            name = None
    return rights


def main() -> int:
    path, engine, mode, openbao, exposure, netpol = sys.argv[1:7]
    database_logs = sys.argv[7] if len(sys.argv) > 7 else "on"
    redis = sys.argv[8] if len(sys.argv) > 8 else "bundled"
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

    facts = ENGINES[engine]
    port = facts["port"]
    server = f"{RELEASE}-{facts['server']}"
    host = f"{server}.{NAMESPACE}.svc" if mode == "bundled" else EXTERNAL_DB_HOST

    # --- The engine in each config file ----------------------------------
    def go_section(where: str, section: dict) -> None:
        check(section.get("type") == engine, f"{where}.type is {section.get('type')!r}, not {engine}")
        check(section.get("port") == port, f"{where}.port is {section.get('port')!r}, not {port}")
        check(section.get("hosts") == [host], f"{where}.hosts is {section.get('hosts')!r}")
        tls = section.get("tls") or {}
        check(bool(tls.get("caFile")), f"{where}.tls.caFile is missing")
        check(tls.get("sslMode") == "verify-full", f"{where}.tls.sslMode is {tls.get('sslMode')!r}, not verify-full")

    def wallet_section(where: str, section: dict) -> None:
        check(section.get("type") == engine, f"{where}.type is {section.get('type')!r}, not {engine}")
        check(section.get("port") == port, f"{where}.port is {section.get('port')!r}, not {port}")
        check(section.get("host") == host, f"{where}.host is {section.get('host')!r}")
        check(bool(section.get("ssl_ca_file")), f"{where}.ssl_ca_file is missing")
        check(section.get("ssl_mode") == "verify-full", f"{where}.ssl_mode is {section.get('ssl_mode')!r}, not verify-full")

    for key in ("api.yaml", "webhook.yaml"):
        api = config_map_file(f"{RELEASE}-api", key)
        if api:
            go_section(f"api {key} DataBase", api["DataBase"])
            go_section(f"api {key} Extensions.oidc.database", api["Extensions"]["oidc"]["database"])
            oidc = api["Extensions"]["oidc"]
            check(oidc.get("apiPathBase") == f"{OIDC_PROVIDER_PATH}/{{organisationId}}/{{sandboxOrgId}}",
                  f"api {key} Extensions.oidc.apiPathBase is {oidc.get('apiPathBase')!r}")
            check(oidc.get("qrPollPrefix") == api["ApiBaseUrl"] + OIDC_PROVIDER_PATH,
                  f"api {key} Extensions.oidc.qrPollPrefix is {oidc.get('qrPollPrefix')!r}")
            go_section(f"api {key} ReadAccess.wallet", api["ReadAccess"]["wallet"])
            check(api["KeyStorage"].get("allowPlaintextProviderKeys") is False, f"api {key} KeyStorage.allowPlaintextProviderKeys is not false")
            check("PrivacyDashboardDeployment" not in api, f"api {key} has PrivacyDashboardDeployment")
    gateway = config_map_file(f"{RELEASE}-gateway", "config.yaml")
    if gateway:
        go_section("gateway DataBase", gateway["DataBase"])
        # The feature gate of the gateway is on by default, and only the
        # gateway file has the section (the api refuses it).
        check(gateway.get("Features") == {"enforce": True}, f"the gateway Features section is {gateway.get('Features')}")
        for file in ("api.yaml", "webhook.yaml"):
            check("Features" not in (config_map_file(f"{RELEASE}-api", file) or {}), f"{file} has a Features section (only the gateway file has it)")
        # The limits of the installation are not set by default: no Limits
        # section in the api files (an api of an earlier release refuses
        # it), and never in the gateway file (the gateway refuses it).
        check("Limits" not in gateway, "the gateway file has a Limits section (the gateway refuses it)")
        for file in ("api.yaml", "webhook.yaml"):
            check("Limits" not in (config_map_file(f"{RELEASE}-api", file) or {}), f"{file} has a Limits section (the default values set no limit)")
    # The operator Jobs of the api are off by default: no Job makes an
    # admin, an organisation or the platform operator.
    operator_jobs = sorted(d["metadata"]["name"] for d in docs if d.get("kind") == "Job" and re.search(
        r"-api-(bootstrap-platform|platform-operator|register-admin|create-organisation(-type)?)-\d+$", d["metadata"]["name"]))
    check(not operator_jobs, f"the default values render the operator Jobs {operator_jobs}")
    consent = config_map_file(f"{RELEASE}-consent", "config.yaml")
    if consent:
        go_section("consent DataBase", consent["DataBase"])
        for owner in ("api", "wallet"):
            go_section(f"consent ReadAccess.{owner}", consent["ReadAccess"][owner])
    consent_migrate = config_map_file(f"{RELEASE}-consent", "migrate.yaml")
    if consent_migrate:
        go_section("consent migrate.yaml DataBase", consent_migrate["DataBase"])
    openbao_address = EXTERNAL_OPENBAO if openbao == "external" else f"https://{RELEASE}-openbao.{NAMESPACE}.svc:8200"
    for file in KMS_FILES:
        role = file.removesuffix(".yaml")
        wallet = config_map_file(f"{RELEASE}-wallet", file)
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
        check("storage" not in wallet, f"wallet {role}.yaml has a storage section (the PDF files are in the database)")
        check((wallet.get("nats") or {}).get("command_reply_seconds") == (300 if file == "config.yaml" else None),
              f"wallet {file} has nats.command_reply_seconds {(wallet.get('nats') or {}).get('command_reply_seconds')!r}")
        # The interval of the writes of the issuer status lists: only the
        # workers write the lists (the actor status_list.write_changes).
        check(wallet.get("status_list") == ({"write_interval_seconds": 30} if file in WORKER_FILES else None),
              f"wallet {file} has status_list {wallet.get('status_list')!r}")
        if file == "config.yaml":
            for owner in ("api", "consent"):
                wallet_section(f"wallet config.yaml read_access.{owner}", wallet["read_access"][owner])
        check(wallet.get("audit") == AUDIT, f"wallet {role}.yaml audit is {wallet.get('audit')!r}, not {AUDIT}")
        check(wallet.get("retention") == RETENTION, f"wallet {role}.yaml retention is {wallet.get('retention')!r}, not {RETENTION}")
        # The limit of the organisation wallet units is not set by default:
        # a wallet of an earlier release refuses the key.
        check("organisation_wallet_units_max" not in (wallet.get("wallet_unit") or {}),
              f"wallet {role}.yaml has wallet_unit.organisation_wallet_units_max (the default values set no limit)")

    # The workers and the clock (docs/workers.md): one Deployment for each
    # worker group (dramatiq with the queues of the group) and the clock
    # (start-clock); the health port (the probes and /metrics), the stop,
    # the state folder of the worker processes, no service account token.
    # The clock file has only the log level, the database, Valkey and the
    # health port (load_clock_settings of the wallet: no domain, nats or
    # kms).
    def probe(container: dict, name: str) -> tuple:
        get = ((container.get(name) or {}).get("httpGet") or {})
        return get.get("path"), get.get("port")

    # The metrics of the servers (organisation-wallet-suite): server.metrics_port 9190
    # (/metrics only) and server.metrics_directory on an emptyDir in memory;
    # the probes stay on the port of the routes.
    for server_role in ("service", "config"):
        server_file = (config_map_file(f"{RELEASE}-wallet", f"{server_role}.yaml") or {}).get("server") or {}
        check((server_file.get("metrics_port"), server_file.get("metrics_directory")) == (9190, "/run/ows-server"),
              f"wallet {server_role}.yaml has the metrics {server_file.get('metrics_port')!r} {server_file.get('metrics_directory')!r}")
        server_deploy = find("Deployment", f"{RELEASE}-wallet-{server_role}")
        if server_deploy:
            server_pod = server_deploy["spec"]["template"]["spec"]
            server_container = server_pod["containers"][0]
            check({"name": "metrics", "containerPort": 9190} in server_container.get("ports", []), f"the {server_role} pods have no port metrics 9190")
            check({"name": "server-metrics", "mountPath": "/run/ows-server"} in server_container.get("volumeMounts", []),
                  f"the {server_role} pods do not mount the metrics folder")
            check({"name": "server-metrics", "emptyDir": {"medium": "Memory", "sizeLimit": "64Mi"}} in server_pod.get("volumes", []),
                  f"the {server_role} pods have no emptyDir of the metrics folder")
            check(probe(server_container, "readinessProbe") == ("/readyz", "http"), f"the {server_role} readiness probe is not /readyz of the port http")
        route_service = find("Service", f"{RELEASE}-wallet-{server_role}")
        if route_service:
            check(all(port.get("port") != 9190 and port.get("targetPort") != "metrics" for port in route_service["spec"]["ports"]),
                  f"the Service of the {server_role} routes has the metrics port")

    for name, (queues, replicas, processes, threads, shutdown, grace) in WORKER_GROUPS.items():
        component = f"wallet-worker-{name}"
        deploy = find("Deployment", f"{RELEASE}-{component}")
        if deploy is None:
            failures.append(f"the Deployment {RELEASE}-{component} is missing")
            continue
        pod = deploy["spec"]["template"]["spec"]
        container = pod["containers"][0]
        command = ["/app/.venv/bin/dramatiq", "ows.worker.run:start", "--processes", str(processes), "--threads", str(threads),
                   "--worker-shutdown-timeout", str(shutdown * 1000), "--worker-fork-timeout", "650000", "--queues", *queues]
        # Dramatiq starts the health server (a fork process) after the fork
        # timeout at the latest: the wait is as long as the startup probe.
        startup = container.get("startupProbe") or {}
        check(startup.get("periodSeconds", 0) * startup.get("failureThreshold", 0) * 1000 == 650000,
              f"the startup probe of the {component} pods does not give the 650 s of --worker-fork-timeout")
        check(container.get("command") == command, f"the {component} pods have the command {container.get('command')}")
        check(deploy["spec"]["replicas"] == replicas, f"the {component} Deployment has {deploy['spec']['replicas']} replicas, not {replicas}")
        check(pod.get("terminationGracePeriodSeconds") == grace, f"the {component} pods have the grace period {pod.get('terminationGracePeriodSeconds')}, not {grace}")
        check(pod.get("automountServiceAccountToken") is False, f"the {component} pods mount a service account token")
        check(deploy["spec"]["template"]["metadata"]["labels"].get("netpol.igrant.io/role") == "wallet-worker", f"the {component} pods have not the network role wallet-worker")
        check(container.get("ports") == [{"name": "health", "containerPort": 9191}], f"the {component} pods have the ports {container.get('ports')}")
        check(probe(container, "livenessProbe") == ("/healthz", "health") and probe(container, "readinessProbe") == ("/readyz", "health")
              and probe(container, "startupProbe") == ("/healthz", "health"), f"the {component} probes are not /healthz and /readyz of the health port")
        startup = container.get("startupProbe") or {}
        check(startup.get("periodSeconds", 10) * startup.get("failureThreshold", 3) >= 630,
              f"the startup probe of the {component} pods ends before the wait for the schema head (630 s)")
        state = next((v for v in pod["volumes"] if v["name"] == "worker-state"), {})
        mounts = {m["name"]: m["mountPath"] for m in container.get("volumeMounts", [])}
        check((state.get("emptyDir") or {}).get("medium") == "Memory" and mounts.get("worker-state") == "/run/ows-worker",
              f"the {component} pods have no emptyDir at the state folder /run/ows-worker")
        check(pod["volumes"][0]["configMap"]["items"][0]["key"] == f"worker-{name}.yaml", f"the {component} pods do not mount worker-{name}.yaml")
        worker = config_map_file(f"{RELEASE}-wallet", f"worker-{name}.yaml") or {}
        check(worker.get("worker") == {"health_port": 9191, "state_directory": "/run/ows-worker"}, f"wallet worker-{name}.yaml worker is {worker.get('worker')!r}")
        check("server" not in worker and "clock" not in worker, f"wallet worker-{name}.yaml has a server or a clock section")
    clock = find("Deployment", f"{RELEASE}-wallet-clock")
    if clock is None:
        failures.append(f"the Deployment {RELEASE}-wallet-clock is missing")
    else:
        pod = clock["spec"]["template"]["spec"]
        container = pod["containers"][0]
        check(container.get("command") == ["/app/.venv/bin/start-clock"], f"the clock pods have the command {container.get('command')}")
        check(clock["spec"]["replicas"] == 2, "the clock has not 2 replicas")
        check(pod.get("terminationGracePeriodSeconds") == 30 and pod.get("automountServiceAccountToken") is False,
              "the clock pods have not the grace period 30 without a service account token")
        check(clock["spec"]["template"]["metadata"]["labels"].get("netpol.igrant.io/role") == "wallet-clock", "the clock pods have not the network role wallet-clock")
        check(container.get("ports") == [{"name": "health", "containerPort": 9192}], f"the clock pods have the ports {container.get('ports')}")
        check(probe(container, "livenessProbe") == ("/healthz", "health") and probe(container, "readinessProbe") == ("/readyz", "health"),
              "the clock probes are not /healthz and /readyz of the health port")
        paths = {item["path"] for source in pod["volumes"][1]["projected"]["sources"] for item in source["secret"]["items"]}
        check({"database-password", "redis-password"} <= paths <= {"database-password", "database-ca.crt", "redis-password", "redis-ca.crt"},
              f"the clock pods mount {sorted(paths)}, not only the files of the database and of Valkey")
    clock_file = config_map_file(f"{RELEASE}-wallet", "clock.yaml") or {}
    # The scheduler is gone (organisation-wallet-suite removed it): no
    # Deployment and no configuration key.
    check(find("Deployment", f"{RELEASE}-wallet-scheduler") is None, "the Deployment of the scheduler is rendered")
    check("scheduler.yaml" not in ((find("ConfigMap", f"{RELEASE}-wallet") or {}).get("data") or {}), "the wallet ConfigMap has scheduler.yaml")
    check(set(clock_file) == {"log_level", "database", "redis", "clock"}, f"the clock file has the keys {sorted(clock_file)}")
    check(clock_file.get("clock") == {"health_port": 9192}, f"the clock file has clock {clock_file.get('clock')!r}")
    if clock_file:
        wallet_section("wallet clock.yaml database", clock_file["database"])
    # The pools (database.pools; docs/database.md, "Connection budget"): the
    # session and allocation pools of the service and config roles, one
    # session connection for each thread of a worker process, the reader of
    # the wallet views of the api and of the webhook handler.
    pools = {"service.yaml": (12, 4, 5), "config.yaml": (8, 4, 2),
             **{f"worker-{name}.yaml": (group[3], 2, 2) for name, group in WORKER_GROUPS.items()}}
    for file, (size, overflow, allocation) in pools.items():
        database = (config_map_file(f"{RELEASE}-wallet", file) or {}).get("database") or {}
        found = (database.get("pool_size"), database.get("max_overflow"), database.get("allocation_pool_size"))
        check(found == (size, overflow, allocation), f"wallet {file} has the pools {found}, not {(size, overflow, allocation)}")
    clock_database = (config_map_file(f"{RELEASE}-wallet", "clock.yaml") or {}).get("database") or {}
    check(not {"pool_size", "max_overflow", "allocation_pool_size"} & set(clock_database), "wallet clock.yaml has a pool value")
    for key in ("api.yaml", "webhook.yaml"):
        reader = ((config_map_file(f"{RELEASE}-api", key) or {}).get("ReadAccess") or {}).get("wallet") or {}
        check((reader.get("maxConns"), reader.get("minConns")) == (5, 1), f"api {key} ReadAccess.wallet has not the pool 5/1")
    check(not [d for d in docs if d.get("kind") == "ServiceMonitor" and d["metadata"]["name"] == f"{RELEASE}-wallet-metrics"],
          "the ServiceMonitor of the wallet is rendered without organisationWallet.serviceMonitor.enabled")

    # The migration hooks and the other hooks of the wallet (their own
    # ConfigMaps).
    for name, kind in (
        (f"{RELEASE}-api-migrate", "go"),
        (f"{RELEASE}-consent-migrate", "go"),
        (f"{RELEASE}-consent-migrate-after", "go"),
        (f"{RELEASE}-wallet-database-roles", "wallet"),
        (f"{RELEASE}-wallet-migrate", "wallet"),
        (f"{RELEASE}-wallet-read-access", "wallet"),
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
            # Only the migration hook reads the retention of the audit log
            # (the partition step of migrate-database).
            expected = {"log_level", "database"} | ({"audit"} if name == f"{RELEASE}-wallet-migrate" else set())
            check(set(hook) == expected, f"{name} has the keys {sorted(hook)}, not {sorted(expected)}")
            if "audit" in expected:
                check(hook.get("audit") == AUDIT, f"{name} audit is {hook.get('audit')!r}, not {AUDIT}")

    # --- The database server and the Jobs --------------------------------
    # The database server: the StatefulSet with the network role db.
    servers = [d["metadata"]["name"] for d in docs if d.get("kind") == "StatefulSet"
               and d["spec"]["template"]["metadata"]["labels"].get("netpol.igrant.io/role") == "db"]
    if mode == "bundled":
        check(servers == [server], f"the database StatefulSets are {servers}, not [{server}]")
        svc = find("Service", server)
        check(svc is not None and svc["spec"]["ports"][0]["port"] == port, f"Service {server} has not port {port}")
        tls = find("Secret", f"{server}-tls")
        check(tls is not None and set(tls.get("data", {})) == {"tls.crt", "tls.key", "ca.crt"},
              f"the TLS Secret {server}-tls is missing or has other keys")
        # The server parameters (postgres -c name=value): each name once,
        # and the DDL and connection logs unless they are off.
        sts = find("StatefulSet", server)
        if sts:
            args = sts["spec"]["template"]["spec"]["containers"][0].get("args", [])
            check({"ssl=on", "ssl_cert_file=/etc/pg-tls/tls.crt", "ssl_key_file=/etc/pg-tls/tls.key"} <= set(args),
                  "the bundled server does not always serve TLS")
            parameters = [arg.split("=", 1) for option, arg in zip(args, args[1:]) if option == "-c"]
            names = [name for name, _ in parameters]
            check(len(names) == len(set(names)), f"a server parameter is set twice: {sorted(names)}")
            logs = {name: value for name, value in parameters if name in DATABASE_LOGS}
            expected = DATABASE_LOGS if database_logs == "on" else {}
            check(logs == expected, f"the database log parameters are {logs}, not {expected}")
    else:
        check(not servers, f"a database StatefulSet is rendered with mode external: {servers}")
    check(find("Job", f"{RELEASE}-db-init") is not None, "the database init hook is missing")
    check(not [d for d in docs if d.get("kind") == "Job" and d["metadata"]["name"].startswith(f"{RELEASE}-db-init-")],
          "a database init Job has the release revision in its name: the init is a hook")
    init_cm = find("ConfigMap", f"{RELEASE}-db-init")
    if init_cm:
        script = init_cm["data"]["create-databases.sh"]
        check("CREATE ROLE" in script and "psql" in script, "the init script is not the PostgreSQL script")
        # psql \password sends a SCRAM-SHA-256 verifier, never the password:
        # the DDL log of the server must not show a password.
        check("\\password" in script and not re.search(r"\bPASSWORD\b", script),
              "the init script sends a password in a statement, not with psql \\password")
    db_secret = find("Secret", server)
    if db_secret:
        keys = set(db_secret.get("data", {}))
        admin = {facts["admin_key"]}
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

    # --- The database roles of the wallet ------------------------------------
    # Each wallet process connects with its own database role
    # (<prefix>_<role>; the prefix is the wallet database name): the hooks
    # make the roles (the administrator), migrate (the migrator) and give the
    # read access (the administrator); the pods connect as the launcher or
    # the jobs role. No wallet pod or Job mounts the password of the database
    # owner user, and no wallet pod mounts the password of the administrator.
    admin_user, admin_secret, admin_key = (
        ("postgres", server, facts["admin_key"]) if mode == "bundled" else ("igrant_admin", "db-admin", "password"))
    roles_secret = f"{RELEASE}-wallet-database-roles"
    secret_dir = "/run/secrets/eudi-wallet"

    def annotations(doc) -> dict:
        return doc["metadata"].get("annotations") or {}

    def pod_of(doc) -> dict:
        return doc["spec"]["template"]["spec"]

    def secret_refs(pod: dict) -> set:
        """(Secret, key) of each Secret that a pod mounts or reads (key None: all keys)."""
        refs = set()
        for volume in pod.get("volumes", []):
            sources = [volume] if "secret" in volume else (volume.get("projected") or {}).get("sources", [])
            for source in sources:
                secret = source.get("secret")
                if not secret:
                    continue
                name = secret.get("secretName") or secret.get("name")
                items = secret.get("items")
                refs |= {(name, item["key"]) for item in items} if items else {(name, None)}
        for container in pod.get("containers", []) + pod.get("initContainers", []):
            for env in container.get("env", []):
                ref = (env.get("valueFrom") or {}).get("secretKeyRef")
                if ref:
                    refs.add((ref["name"], ref["key"]))
            for source in container.get("envFrom", []):
                if source.get("secretRef"):
                    refs.add((source["secretRef"]["name"], None))
        return refs

    def projected_files(pod: dict) -> dict:
        """The files of the projected volume "secrets": path -> (Secret, key)."""
        volume = next((v for v in pod.get("volumes", []) if v["name"] == "secrets"), {})
        return {item["path"]: (source["secret"]["name"], item["key"])
                for source in (volume.get("projected") or {}).get("sources", []) for item in source["secret"]["items"]}

    owner_password = (server, "igrant_wallet")
    admin_password = (admin_secret, admin_key)
    logins = {"migrator", "launcher_app", "jobs", "clock", "audit_reader", "issuer_app", "relying_party_app",
              "business_wallet_app", "individual_wp_app", "business_wp_app", "admin_app"}

    # The role Secret: one key per login role.
    secret = find("Secret", roles_secret)
    check(secret is not None and set(secret.get("data", {})) == logins,
          f"the role Secret {roles_secret} is missing or has the keys {sorted((secret or {}).get('data', {}))}")
    # The Secrets that the hooks read: hooks before every other hook (Helm
    # makes the resources only after the pre-upgrade hooks), and kept.
    # The TLS Secret of the bundled server is a hook too: an upgrade that
    # turns database.tls.enabled on gives the CA to the hooks, and the
    # server always serves TLS.
    server_tls = [f"{server}-tls"] if mode == "bundled" else []
    for name in [server, f"{RELEASE}-read-access", roles_secret, *server_tls]:
        doc = find("Secret", name)
        check(doc is not None and annotations(doc).get("helm.sh/resource-policy") == "keep",
              f"the Secret {name} is missing or not kept (resource-policy keep)")

    # The hook kinds and weights: the Secrets, the init of the databases,
    # the roles, the migration, the read access.
    install_upgrade = "post-install,pre-upgrade"
    hooks = (
        ("Secret", server, "pre-install,pre-upgrade", "-30"),
        ("Secret", f"{RELEASE}-read-access", "pre-install,pre-upgrade", "-30"),
        ("Secret", roles_secret, "pre-install,pre-upgrade", "-30"),
        *[("Secret", name, "pre-install,pre-upgrade", "-30") for name in server_tls],
        ("ConfigMap", f"{RELEASE}-db-init", install_upgrade, "-28"),
        ("Job", f"{RELEASE}-db-init", install_upgrade, "-27"),
        ("ConfigMap", f"{RELEASE}-wallet-database-roles", install_upgrade, "-25"),
        ("Job", f"{RELEASE}-wallet-database-roles", install_upgrade, "-20"),
        ("ConfigMap", f"{RELEASE}-wallet-migrate", install_upgrade, "-10"),
        ("Job", f"{RELEASE}-wallet-migrate", install_upgrade, "-5"),
        ("ConfigMap", f"{RELEASE}-wallet-read-access", install_upgrade, "0"),
        ("Job", f"{RELEASE}-wallet-read-access-api", install_upgrade, "5"),
        ("Job", f"{RELEASE}-wallet-read-access-consent", install_upgrade, "5"),
    )
    for kind, name, when, weight in hooks:
        doc = find(kind, name)
        if doc is None:
            failures.append(f"the hook {kind} {name} is missing")
            continue
        found = tuple(annotations(doc).get(f"helm.sh/{key}") for key in ("hook", "hook-weight", "hook-delete-policy"))
        check(found == (when, weight, "before-hook-creation"), f"the hook {kind} {name} has {found}, not ({when}, {weight}, before-hook-creation)")
    weights = [int(weight) for _, _, _, weight in hooks]
    check(weights == sorted(weights), "the hooks are not in the order Secrets, init, roles, migration, read access")
    # The api and consent migration hooks stay pre-upgrade (and post-upgrade),
    # after the init hook.
    for name, when in ((f"{RELEASE}-api-migrate", "pre-upgrade"), (f"{RELEASE}-consent-migrate", "pre-upgrade"),
                       (f"{RELEASE}-consent-migrate-after", "post-upgrade")):
        doc = find("Job", name)
        check(doc is not None and annotations(doc).get("helm.sh/hook") == when, f"the hook {name} is not {when}")
        check(doc is not None and int(annotations(doc).get("helm.sh/hook-weight", "0")) > -27, f"the hook {name} does not run after the init hook")
    # A new installation has no api or consent hook: their pods migrate at
    # the start. The api pod runs "igrant-api migrate" in an init container;
    # the consent process ("serve") applies its migrations before it serves.
    api_deploy = find("Deployment", f"{RELEASE}-api")
    if api_deploy:
        init = [c.get("command") for c in pod_of(api_deploy).get("initContainers", [])]
        check(init == [["/app/bin/igrant-api", "migrate", "--config", "/etc/igrant-api/config.yaml"]],
              f"the api pods do not migrate in an init container (init containers {init})")
    consent_deploy = find("Deployment", f"{RELEASE}-consent")
    if consent_deploy:
        args = pod_of(consent_deploy)["containers"][0].get("args") or []
        check(args[:1] == ["serve"], f"the consent pods do not run serve (args {args})")

    # The user of each hook configuration.
    for name, user in ((f"{RELEASE}-wallet-database-roles", admin_user), (f"{RELEASE}-wallet-migrate", "igrant_wallet_migrator"),
                       (f"{RELEASE}-wallet-read-access", admin_user)):
        database = (config_map_file(name, "config.yaml") or {}).get("database") or {}
        check(database.get("user") == user, f"the hook configuration {name} has the database user {database.get('user')!r}, not {user}")
        expected_file = f"{secret_dir}/{'database-password' if user.endswith('_migrator') else 'database-admin-password'}"
        check(database.get("password_file") == expected_file, f"the hook configuration {name} has the password file {database.get('password_file')!r}")

    # The roles hook: database-roles apply with the administrator and the
    # role Secret.
    roles_job = find("Job", f"{RELEASE}-wallet-database-roles")
    if roles_job:
        pod = pod_of(roles_job)
        container = pod["containers"][0]
        check(container.get("command") == ["/app/.venv/bin/database-roles", "apply", "--password-dir", "/run/secrets/database-roles",
                                           "--admin-user", admin_user, "--admin-password-file", f"{secret_dir}/database-admin-password"]
              and "args" not in container, f"the roles hook has the command {container.get('command')}")
        # The init hook runs before it: no wait for the server or the database.
        check(roles_job["spec"].get("backoffLimit") == 1 and "activeDeadlineSeconds" not in roles_job["spec"],
              "the roles hook has not backoffLimit 1 without activeDeadlineSeconds")
        check(pod.get("restartPolicy") == "Never", "the roles hook has not restartPolicy Never")
        mounts = {m["name"]: m["mountPath"] for m in container.get("volumeMounts", [])}
        check(mounts.get("database-roles") == "/run/secrets/database-roles", "the roles hook does not mount the role Secret at /run/secrets/database-roles")
        refs = secret_refs(pod)
        check({(roles_secret, login) for login in logins} | {admin_password} <= refs,
              "the roles hook does not mount every key of the role Secret and the password of the administrator")
        check(projected_files(pod).get("database-admin-password") == admin_password, "the roles hook has not the password of the administrator as database-admin-password")

    # The migration hook: the migrator, only the key migrator of the role Secret.
    migrate_job = find("Job", f"{RELEASE}-wallet-migrate")
    if migrate_job:
        pod = pod_of(migrate_job)
        check(pod["containers"][0].get("command") == ["/app/.venv/bin/migrate-database"], "the wallet migration hook has not the command migrate-database")
        files = projected_files(pod)
        check(files.get("database-password") == (roles_secret, "migrator"), f"the wallet migration hook mounts {files.get('database-password')} as database-password")
        check({ref for ref in secret_refs(pod) if ref[0] == roles_secret} == {(roles_secret, "migrator")},
              "the wallet migration hook mounts other keys of the role Secret than migrator")
        check(admin_password not in secret_refs(pod), "the wallet migration hook mounts the password of the administrator")

    # The read access hooks: the command (not the image entrypoint) and the
    # administrator.
    for reader in ("api", "consent"):
        job = find("Job", f"{RELEASE}-wallet-read-access-{reader}")
        if not job:
            continue
        container = pod_of(job)["containers"][0]
        command = container.get("command") or []
        check(command[:3] == ["/app/.venv/bin/read-access", "apply", "--reader"] and "args" not in container,
              f"the read access hook of {reader} has not the command read-access (or has args)")
        options = dict(zip(command, command[1:]))
        check(options.get("--admin-user") == admin_user and options.get("--admin-password-file") == f"{secret_dir}/database-admin-password",
              f"the read access hook of {reader} has not the administrator {admin_user} and its password file")
        check(projected_files(pod_of(job)).get("database-admin-password") == admin_password,
              f"the read access hook of {reader} has not the password of the administrator as database-admin-password")

    # The Deployments: the user and the Secret key of each process.
    for file, (component, _, role) in WALLET_PROCESSES.items():
        deploy = find("Deployment", f"{RELEASE}-{component}")
        if deploy is None:
            failures.append(f"the Deployment {RELEASE}-{component} is missing")
            continue
        pod = pod_of(deploy)
        files = projected_files(pod)
        check(files.get("database-password") == (roles_secret, role),
              f"the {component} pods mount {files.get('database-password')} as database-password, not ({roles_secret}, {role})")
        check({ref for ref in secret_refs(pod) if ref[0] == roles_secret} == {(roles_secret, role)},
              f"the {component} pods mount other keys of the role Secret than {role}")
        user = ((config_map_file(f"{RELEASE}-wallet", file) or {}).get("database") or {}).get("user")
        check(user == f"igrant_wallet_{role}", f"the {component} pods connect as {user!r}, not igrant_wallet_{role}")
        check(admin_password not in secret_refs(pod), f"the {component} pods mount the password of the administrator")
        check(not [name for name in files if name.startswith("audit-bucket-")], f"the {component} pods mount the credentials of an audit bucket")
        if component in ("wallet-service", "wallet-config"):
            # The server waits up to 600 s for the schema head before it
            # answers /healthz: the startup probe covers the wait.
            probe = pod["containers"][0].get("startupProbe") or {}
            check(probe.get("periodSeconds", 10) * probe.get("failureThreshold", 3) >= 630,
                  f"the startup probe of the {component} pods ends before the wait for the schema head (630 s)")

    # No wallet pod or Job mounts the password of the database owner user.
    for doc in docs:
        if doc.get("kind") in ("Deployment", "Job", "StatefulSet") and doc["metadata"]["name"].startswith(f"{RELEASE}-wallet-"):
            check(owner_password not in secret_refs(pod_of(doc)) and (server, None) not in secret_refs(pod_of(doc)),
                  f"{doc['kind']} {doc['metadata']['name']} mounts the password of the database owner user")

    # --- Replicas (H2; the placement belongs to the scaled deployment) --------
    # The processes of the wallet have a CPU request and a memory limit; no
    # PodDisruptionBudget, no default anti-affinity or zone spread and no
    # HorizontalPodAutoscaler (docs/scaled-deployments.md).
    for component, replicas in {"api": 1, "webhook": 1, "wallet-service": 1, "wallet-config": 1, "wallet-clock": 2,
                                **{f"wallet-worker-{n}": g[1] for n, g in WORKER_GROUPS.items()}}.items():
        deploy = find("Deployment", f"{RELEASE}-{component}")
        if deploy is None:
            continue
        pod = pod_of(deploy)
        check(deploy["spec"].get("replicas") == replicas, f"the {component} Deployment has {deploy['spec'].get('replicas')} replicas, not {replicas}")
        check(not (pod.get("affinity") or {}).get("podAntiAffinity") and not pod.get("topologySpreadConstraints"),
              f"the {component} pods have a default anti-affinity or spread")
        resources = pod["containers"][0].get("resources") or {}
        check(bool((resources.get("requests") or {}).get("cpu")) and bool((resources.get("limits") or {}).get("memory")),
              f"the {component} pods have no CPU request or no memory limit")
    check(not [d for d in docs if d.get("kind") in ("HorizontalPodAutoscaler", "PodDisruptionBudget")],
          "a HorizontalPodAutoscaler or a PodDisruptionBudget is rendered")

    # --- Exposure ------------------------------------------------------------
    ingresses = {d["metadata"]["name"]: d for d in docs if d.get("kind") == "Ingress"}
    routes = {d["metadata"]["name"]: d for d in docs if d.get("kind") == "HTTPRoute"}
    if exposure in ("ingress", "on-premise"):
        check(set(ingresses) == set(HOSTS) and not routes, f"the Ingresses are {sorted(ingresses)}, the routes {sorted(routes)}")
        for name, ingress in ingresses.items():
            rule = ingress["spec"]["rules"][0]
            check(rule["host"] == HOSTS[name], f"Ingress {name} has the host {rule['host']}")
            # On premise only the wallet host is on the public class nginx;
            # the api and dashboard hosts are on the internal class.
            public = exposure == "ingress" or name == f"{RELEASE}-wallet-service"
            want = "nginx" if public else "nginx-internal"
            check(ingress["spec"].get("ingressClassName") == want, f"Ingress {name} has not the ingressClassName {want}")
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
    # Only the gateway calls the config role of the wallet: no route to it.
    backends = [path["backend"]["service"]["name"] for ingress in ingresses.values()
                for rule in ingress["spec"]["rules"] for path in rule["http"]["paths"]]
    backends += [ref["name"] for route in routes.values() for rule in route["spec"]["rules"] for ref in rule["backendRefs"]]
    check(f"{RELEASE}-wallet-config" not in backends, "a route goes to the Service of the wallet config role")
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
    # NATS (H5): TLS for the clients and mutual TLS for the routes with the
    # TLS Secret of the chart; each process of the chart trusts its CA.
    if nats:
        pod = pod_of(nats)
        tls_volume = next((v for v in pod["volumes"] if v["name"] == "tls"), {})
        check((tls_volume.get("secret") or {}).get("secretName") == f"{RELEASE}-nats-tls", "the NATS pods do not mount the TLS Secret of the chart")
        # The reloader watches each file of nats.conf: it needs the same
        # mounts as the server for them, else it stops at its start.
        for container in pod["containers"]:
            mounts = {m["mountPath"] for m in container.get("volumeMounts", [])}
            for path in sorted(set(re.findall(r'"(/etc/[^"]+)"', nats_conf))):
                check(any(path.startswith(m.rstrip("/") + "/") for m in mounts),
                      f"the NATS container {container['name']} does not mount {path} of nats.conf")
    files = {"cert_file": '"/etc/nats-tls/tls.crt"', "key_file": '"/etc/nats-tls/tls.key"', "ca_file": '"/etc/nats-tls/ca.crt"'}
    blocks = re.findall(r"^(\s*)tls \{\n(.*?)^\1\}", nats_conf, re.M | re.S)
    settings = [dict(line.strip().split(": ", 1) for line in body.strip().splitlines()) for _, body in blocks]
    check(len(settings) == 2 and all(files.items() <= block.items() for block in settings),
          "nats.conf has not the TLS of the clients and of the routes with the files of the TLS Secret")
    check(len(settings) == 2 and settings[1].get("verify") == "true" and "verify" not in settings[0],
          "the routes of NATS have no mutual TLS (verify), or the clients must give a certificate")
    tls_secret = find("Secret", f"{RELEASE}-nats-tls") or {}
    check(tls_secret.get("type") == "kubernetes.io/tls" and set(tls_secret.get("data", {})) == {"tls.crt", "tls.key", "ca.crt"}
          and annotations(tls_secret).get("helm.sh/resource-policy") == "keep" and "helm.sh/hook" not in annotations(tls_secret),
          "the NATS TLS Secret is missing, is not kept, or is a hook")
    for doc in docs:
        if doc.get("kind") not in ("Deployment", "StatefulSet", "Job") or doc["metadata"].get("namespace", NAMESPACE) != NAMESPACE:
            continue
        mounted = projected_files(pod_of(doc))
        if "nats-seed" in mounted:
            check(mounted.get("nats-ca.crt") == (f"{RELEASE}-nats-tls", "ca.crt"), f"{doc['kind']} {doc['metadata']['name']} has a NATS user but not the NATS CA")
    for name, key, path in ((f"{RELEASE}-api", "api.yaml", ("Nats", "tlsCaFile")), (f"{RELEASE}-api", "webhook.yaml", ("Nats", "tlsCaFile")),
                            (f"{RELEASE}-consent", "config.yaml", ("Nats", "tlsCaFile"))):
        section = (config_map_file(name, key) or {}).get(path[0]) or {}
        check(str(section.get(path[1], "")).endswith("/nats-ca.crt"), f"{name} {key} has no {'.'.join(path)}")
    for file in KMS_FILES:
        section = (config_map_file(f"{RELEASE}-wallet", file) or {}).get("nats") or {}
        check(section.get("tls_ca_file") == "/run/secrets/eudi-wallet/nats-ca.crt", f"wallet {file} has no nats.tls_ca_file")
    users = re.findall(r"^\s*# (\S+)$", nats_conf, re.M)
    # The clock connects to no NATS: it has no user.
    check(users == ["api", "api-webhook", "consent", "wallet-config", "wallet-service", "wallet-worker"],
          f"the NATS users are {users}")
    # The WIA pool refill is an actor of the workers (P3-B): no NATS user
    # publishes or subscribes to ows.wia_pool.refill_requested.
    check("ows.wia_pool.refill_requested" not in nats_conf, "a NATS user has the removed WIA pool refill event")
    # The webhook events of the wallet (contract/v2 E9): each wallet role
    # publishes them, the webhook handler has their durable api-webhook-event,
    # and the API core and the webhook handler can only read and delete the
    # retired durables of the api (they delete them at their start).
    rights = nats_rights(nats_conf)
    for user in WALLET_NATS_USERS:
        check("ows.*.evt.webhook_event" in rights.get(user, {}).get("publish", set()),
              f"the NATS user {user} cannot publish the webhook events ows.*.evt.webhook_event")
    durable = "OWS_MICROSERVICE.api-webhook-event"
    webhook_publish = rights.get("api-webhook", {}).get("publish", set())
    check({f"$JS.API.CONSUMER.DURABLE.CREATE.{durable}", f"$JS.API.CONSUMER.INFO.{durable}", f"$JS.ACK.{durable}.>"} <= webhook_publish,
          "the NATS user api-webhook has not the rights of the durable api-webhook-event")
    # The webhook handler sends one command of the wallet: the revocation of
    # an issuance (the earlier Authenticator credential of an admin).
    commands = sorted(subject for subject in webhook_publish if subject.startswith("ows.cmd."))
    check(commands == ["ows.cmd.*.issuance.revoke"], f"the NATS user api-webhook publishes the wallet commands {commands}")
    # The events of the api (contract/v2, stream API_EVENTS): the API core
    # publishes each subject by name, also the deletion of an organisation
    # (E10). Its wallet commands are ows.cmd.> (also
    # organisation.set_suspended).
    api_publish = rights.get("api", {}).get("publish", set())
    api_events = sorted(subject for subject in api_publish if subject.startswith("api.v1.evt."))
    check(api_events == sorted(f"api.v1.evt.{name}" for name in (
        "organisation.created", "organisation.updated", "organisation.deleted",
        "sandbox.updated", "sandbox.deleted", "extension.updated")),
          f"the NATS user api publishes the api events {api_events}")
    check("ows.cmd.>" in api_publish, "the NATS user api cannot publish the wallet commands ows.cmd.>")
    for user in ("api", "api-webhook"):
        publish = rights.get(user, {}).get("publish", set())
        for retired in API_RETIRED_DURABLES:
            subject = f"OWS_MICROSERVICE.{retired}"
            check({f"$JS.API.CONSUMER.INFO.{subject}", f"$JS.API.CONSUMER.DELETE.{subject}"} <= publish,
                  f"the NATS user {user} cannot delete the retired durable {retired}")
            check(not {f"$JS.API.CONSUMER.DURABLE.CREATE.{subject}", f"$JS.ACK.{subject}.>"} & publish,
                  f"the NATS user {user} can use the retired durable {retired}")
    # The clears of the process caches (core NATS ows.cache.cleared): the
    # service and config pods send and get them, the workers do not.
    for user in WALLET_NATS_USERS:
        server = user != "wallet-worker"
        for kind in ("publish", "subscribe"):
            check(("ows.cache.cleared" in rights.get(user, {}).get(kind, set())) == server,
                  f"the NATS user {user} {'cannot' if server else 'can'} {kind} ows.cache.cleared")

    # --- Valkey ---------------------------------------------------------------
    # The bundled Valkey: normal resources, no hook (the processes need it only
    # after the install): the StatefulSet (3 pods, each with a data container
    # and a Sentinel container),
    # the headless Service, the Service of the Sentinels, the ConfigMap and
    # the two kept Secrets (no PodDisruptionBudget and no anti-affinity: the
    # scaled deployment). Each wallet role has the redis section with its own
    # ACL user; the gateway mounts the password of its user (no key in its
    # configuration).
    redis_objects = {(d["kind"], d["metadata"]["name"]) for d in docs if d["metadata"]["name"].startswith(f"{RELEASE}-redis")}
    users_secret, tls_secret = f"{RELEASE}-redis-users", f"{RELEASE}-redis-tls"
    if redis == "bundled":
        expected = {("StatefulSet", f"{RELEASE}-redis"), ("Service", f"{RELEASE}-redis-headless"), ("Service", f"{RELEASE}-redis-sentinel"),
                    ("ConfigMap", f"{RELEASE}-redis"), ("Secret", users_secret), ("Secret", tls_secret)}
        check(redis_objects == expected, f"the Valkey objects are {sorted(redis_objects)}")
        for kind, name in redis_objects:
            doc = find(kind, name)
            check("helm.sh/hook" not in annotations(doc), f"the Valkey object {kind} {name} is a hook")
        secret = find("Secret", users_secret) or {}
        check(set(secret.get("data", {})) == set(REDIS_USERS) | {"replication", "sentinel", "probe"}, f"the Secret {users_secret} has the keys {sorted(secret.get('data', {}))}")
        tls = find("Secret", tls_secret) or {}
        check(tls.get("type") == "kubernetes.io/tls" and set(tls.get("data", {})) == {"tls.crt", "tls.key", "ca.crt"}, f"the Secret {tls_secret} is not a TLS Secret with ca.crt")
        for doc in (secret, tls):
            check(annotations(doc).get("helm.sh/resource-policy") == "keep" if doc else False, f"the Secret {(doc.get('metadata') or {}).get('name')} is not kept")
        sts = find("StatefulSet", f"{RELEASE}-redis")
        if sts:
            pod = pod_of(sts)
            check(sts["spec"]["replicas"] == 3 and sts["spec"].get("podManagementPolicy") == "Parallel", "the Valkey StatefulSet has not 3 replicas with Parallel")
            check([c["name"] for c in pod["containers"]] == ["valkey", "sentinel"], "the Valkey pods have not the containers valkey and sentinel")
            check(all(c["image"] == REDIS_IMAGE for c in pod["containers"]), f"the Valkey image is {pod['containers'][0]['image']}")
            check("affinity" not in pod, "the Valkey pods have an affinity without redis.affinity")
            check(sts["spec"]["template"]["metadata"]["labels"].get("netpol.igrant.io/role") == "redis", "the Valkey pods have not the network role redis")
            check(pod.get("automountServiceAccountToken") is False, "the Valkey pods mount a service account token")
            check((pod.get("securityContext") or {}).get("runAsNonRoot") is True, "the Valkey pods are not non-root")
            check(pod["containers"][0]["lifecycle"]["preStop"]["exec"]["command"] == ["/bin/sh", "/etc/valkey/prestop.sh"], "the data container has not the preStop failover")
            for container in pod["containers"]:
                for probe in ("startupProbe", "readinessProbe", "livenessProbe"):
                    command = ((container.get(probe) or {}).get("exec") or {}).get("command") or []
                    check(command[:2] == ["/bin/sh", "/etc/valkey/probe.sh"], f"the {probe} of the container {container['name']} is not probe.sh")
            users = next((v for v in pod["volumes"] if v["name"] == "users"), {})
            items = {(source["secret"]["name"], item["key"], item["path"]) for source in (users.get("projected") or {}).get("sources", [])
                     for item in source["secret"]["items"]}
            check(items == {(users_secret, key, key) for key in list(REDIS_USERS) + ["replication", "sentinel", "probe"]},
                  "the Valkey pods do not mount the password of each ACL user")
            run = next((v for v in pod["volumes"] if v["name"] == "run"), {})
            check((run.get("emptyDir") or {}).get("medium") == "Memory", "the files with the passwords are not in memory")
            check([c["metadata"]["name"] for c in sts["spec"].get("volumeClaimTemplates", [])] == ["data"], "the Valkey pods have no data volume")
        headless = find("Service", f"{RELEASE}-redis-headless") or {"spec": {}}
        check(headless["spec"].get("clusterIP") == "None" and headless["spec"].get("publishNotReadyAddresses") is True
              and {p["port"] for p in headless["spec"].get("ports", [])} == {6379, 26379}, "the headless Service of Valkey is not right")
        sentinel_svc = find("Service", f"{RELEASE}-redis-sentinel") or {"spec": {}}
        check({p["port"] for p in sentinel_svc["spec"].get("ports", [])} == {26379}, "the Service of the Sentinels has not only the port 26379")
        server = config_map_file(f"{RELEASE}-redis", "valkey.conf", raw=True) or ""
        lines = server.splitlines()
        for setting in REDIS_SETTINGS:
            check(setting in lines, f"valkey.conf has not \"{setting}\"")
        acl = (config_map_file(f"{RELEASE}-redis", "users.acl", raw=True) or "").splitlines()
        check("user default off" in acl, "the ACL file does not turn the default user off")
        for key, user in REDIS_USERS.items():
            rights = REDIS_WALLET_RIGHTS if key != "gateway" else "resetchannels ~gw:* -@all +@read +@write +@connection -@dangerous"
            check(f"user {user} on {{hash:{key}}} {rights}" in acl, f"the ACL file has not the user {user} with its rights")
        sentinel = (config_map_file(f"{RELEASE}-redis", "sentinel.conf", raw=True) or "").splitlines()
        for setting in ("sentinel monitor ows {primary} 6379 2", "sentinel resolve-hostnames yes", "sentinel announce-hostnames yes",
                        "sentinel auth-user ows sentinel", "user default off", "tls-replication yes"):
            check(setting in sentinel, f"sentinel.conf has not \"{setting}\"")
        scripts = set((find("ConfigMap", f"{RELEASE}-redis") or {}).get("data", {}))
        check({"common.sh", "valkey.sh", "sentinel.sh", "probe.sh", "prestop.sh"} <= scripts, f"the Valkey ConfigMap has the keys {sorted(scripts)}")
        # No password in the ConfigMap: only the fields of the templates.
        values = {base64.b64decode(v).decode() for v in secret.get("data", {}).values()}
        check(not any(value in json.dumps(find("ConfigMap", f"{RELEASE}-redis") or {}) for value in values), "the Valkey ConfigMap has a password")
        ca = (tls_secret, "ca.crt")
        endpoint = {"sentinels": [f"{RELEASE}-redis-{i}.{RELEASE}-redis-headless.{NAMESPACE}.svc:26379" for i in range(3)], "master_name": "ows"}
        password_of = {key: (users_secret, key) for key in REDIS_USERS}
    else:
        check(not redis_objects, f"Valkey objects with redis.mode external: {sorted(redis_objects)}")
        ca = ("ows-redis-ca", "ca.crt")
        endpoint = {"sentinels": REDIS_EXTERNAL_SENTINELS, "master_name": "ows"}
        password_of = {key: (f"ows-redis-{user}", "password") for key, user in REDIS_USERS.items()}
    for file, (component, key, _) in WALLET_PROCESSES.items():
        user = REDIS_USERS[key]
        wallet = config_map_file(f"{RELEASE}-wallet", file) or {}
        files = f"{secret_dir}/redis-password"
        expected = {"queue": dict(endpoint, username=user, password_file=files, sentinel_username=user, sentinel_password_file=files,
                                  tls=True, ca_file=f"{secret_dir}/redis-ca.crt", connect_timeout_seconds=2, timeout_seconds=2),
                    "replica_wait_milliseconds": 100}
        check(wallet.get("redis") == expected, f"wallet {file} redis is {wallet.get('redis')!r}")
        deploy = find("Deployment", f"{RELEASE}-{component}")
        if deploy:
            mounted = projected_files(pod_of(deploy))
            check(mounted.get("redis-password") == password_of[key] and mounted.get("redis-ca.crt") == ca,
                  f"the {component} pods mount {mounted.get('redis-password')} and {mounted.get('redis-ca.crt')} as the Valkey files")
    gateway_deploy = find("Deployment", f"{RELEASE}-gateway")
    if gateway_deploy:
        mounted = projected_files(pod_of(gateway_deploy))
        check(mounted.get("redis-password") == password_of["gateway"] and mounted.get("redis-ca.crt") == ca,
              f"the gateway pods mount {mounted.get('redis-password')} and {mounted.get('redis-ca.crt')} as the Valkey files")
        check("redis" not in json.dumps(gateway).lower(), "the gateway configuration has a Valkey key (the gateway refuses an unknown key)")
    if netpol == "on":
        if redis == "bundled":
            check(find("NetworkPolicy", f"{RELEASE}-netpol-ingress-redis") is not None, "no ingress policy of Valkey")
        else:
            reach = {d["metadata"]["name"] for d in policies for rule in d["spec"].get("egress", [])
                     if {(t.get("ipBlock") or {}).get("cidr") for t in rule.get("to", [])} == REDIS_EXTERNAL_CIDRS
                     and {p["port"] for p in rule.get("ports", [])} == {6379, 26379}}
            want = {f"{RELEASE}-netpol-egress-{role}" for role in ("gateway", "wallet-service", "wallet-config", "wallet-worker", "wallet-clock")}
            check(reach == want, f"the policies to the external Valkey are {sorted(reach)}, not {sorted(want)}")

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
