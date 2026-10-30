#!/usr/bin/env python3
"""Checks the key facts of one "helm template" output of the chart.

Usage: check_render.py <render.yaml> <engine> <mode> <openbao> <exposure> <networkpolicy> [<database-logs>]
  engine: postgresql; mode: bundled | external;
  openbao: shamir | external;
  exposure: ingress | gatewayAPI | none; networkpolicy: off | on;
  database-logs: on (default) | off (database.postgresql.logDdlAndConnections
    false).

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
             "dead_letter_days": 30, "login_code_days": 1, "verifier_response_key_days": 1, "batch_size": 500}

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


def main() -> int:
    path, engine, mode, openbao, exposure, netpol = sys.argv[1:7]
    database_logs = sys.argv[7] if len(sys.argv) > 7 else "on"
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
            go_section(f"api {key} ReadAccess.wallet", api["ReadAccess"]["wallet"])
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
        check(wallet.get("audit") == AUDIT, f"wallet {role}.yaml audit is {wallet.get('audit')!r}, not {AUDIT}")
        check(wallet.get("retention") == RETENTION, f"wallet {role}.yaml retention is {wallet.get('retention')!r}, not {RETENTION}")

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
    logins = {"migrator", "launcher_app", "jobs", "audit_reader", "issuer_app", "relying_party_app",
              "business_wallet_app", "individual_wp_app", "business_wp_app", "admin_app"}

    # The role Secret: one key per login role.
    secret = find("Secret", roles_secret)
    check(secret is not None and set(secret.get("data", {})) == logins,
          f"the role Secret {roles_secret} is missing or has the keys {sorted((secret or {}).get('data', {}))}")
    # The Secrets that the hooks read: hooks before every other hook (Helm
    # makes the resources only after the pre-upgrade hooks), and kept.
    for name in (server, f"{RELEASE}-read-access", roles_secret):
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
    processes = {"wallet-service": "launcher_app", "wallet-config": "launcher_app", "wallet-scheduler": "jobs"}
    for component, role in processes.items():
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
        file = config_map_file(f"{RELEASE}-wallet", f"{component.removeprefix('wallet-')}.yaml")
        user = ((file or {}).get("database") or {}).get("user")
        check(user == f"igrant_wallet_{role}", f"the {component} pods connect as {user!r}, not igrant_wallet_{role}")
        check(admin_password not in secret_refs(pod), f"the {component} pods mount the password of the administrator")
        check(not [name for name in files if name.startswith("audit-bucket-")], f"the {component} pods mount the credentials of an audit bucket")
        if component != "wallet-scheduler":
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
