#!/usr/bin/env bash
# Tests of the files of docker-compose/ for the maintainers. No container
# starts and no image is pulled: "docker compose config" needs no Docker
# daemon. Checks:
#   - docker compose config for each engine (postgresql): the database
#     server of the engine, the images, and the database type and port in
#     each configuration file of the components;
#   - the database roles of the wallet: the service wallet-database-roles,
#     the order of the one-shot services and the database user of each
#     wallet configuration;
#   - the DDL and connection logs of the database server, and
#     database-init sets the passwords with psql \password (no password in
#     a statement, so the DDL log does not show one);
#   - Valkey: the services valkey, valkey-replica and valkey-sentinel (the
#     image, the start script, the order, the healthchecks with the user
#     probe, the tmpfs, the password files), the settings of the templates
#     of config/valkey/, the ACL users and their rights, the passwords of
#     make secrets, and the redis section and the password file of each
#     wallet role and of the gateway (tests/compose-valkey.sh runs the
#     services against a real server);
#   - the worker and the clock: their commands, the health port of each
#     healthcheck, the state folder of the worker, and the files of the
#     clock (no NATS seed, no OpenBao password);
#   - the limits of the installation (MAX_ORGANISATIONS,
#     MAX_ORGANISATION_WALLET_UNITS): the keys only with a value;
#   - the webhooks of the api files (no Webhooks.events) and no
#     Installation key (Compose installs all services);
#   - the configuration files (make configs, render-configs.py): the
#     templates of compose.configs.yaml and the file configs of generated/
#     (one for each template, no config of content), the same values files
#     for the render and for the services, the hash label of each service
#     and its file, only the variables of .env.example in the templates
#     (no secret), no secret value in a file, and the renderer in a copy
#     of this folder ($$, ${VAR:+...}, a missing value, the file modes, a
#     stale file, --check, a second run);
#   - the security settings of EACH service of all profiles (a service
#     that the test does not know fails): a read-only root file system, a
#     non-root user, no capability, no new privileges, the tmpfs and
#     volumes of the writable paths, no config of content, no host
#     namespace, no device, only bind mounts of secrets/, no shell in the
#     api image; the one-shot services of root (nats-data-owner) with only
#     their capabilities and no network;
#   - bash -n / sh -n of the scripts;
#   - nats-server -t of the NATS configuration (when nats-server is on this
#     computer);
#   - the text rules of the files (no em or en dash, British English, no
#     name of a removed product or setting);
#   - the relative links of README.md (tests/check_links.py).
#
#   tests/compose-files.sh
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../docker-compose"
# The user of openbao-init (make sets them from your user): fixed values,
# so that the test gives the same result for each user.
export HOST_UID=4242 HOST_GID=4243

failures=0
warnings=0
ok() { printf 'ok    %s\n' "$*"; }
bad() { printf 'FAIL  %s\n' "$*" >&2; failures=$((failures + 1)); }
warn() { printf 'WARN  %s\n' "$*" >&2; warnings=$((warnings + 1)); }
finish() {
  if [ "$failures" -gt 0 ]; then
    echo "check: ${failures} check(s) failed" >&2
    exit 1
  fi
  echo "check: $1"
}

# project_json: docker compose config of the project (with the current
# environment) as JSON, with the text of each file config of generated/ as
# "content": the render of the templates with the same environment
# (render-configs.py --print), so that each case below checks the files
# that make configs writes for its values.
project_json() {
  local project files
  project="$(mktemp)"
  files="$(mktemp)"
  if ! docker compose config --format json > "$project" || ! python3 -I ./render-configs.py --print > "$files"; then
    rm -f "$project" "$files"
    return 1
  fi
  python3 -I - "$project" "$files" <<'PY' || { rm -f "$project" "$files"; return 1; }
import json, os, sys
project = json.load(open(sys.argv[1], encoding="utf-8"))
files = json.load(open(sys.argv[2], encoding="utf-8"))
for name, config in (project.get("configs") or {}).items():
    file = config.get("file", "")
    if os.path.basename(os.path.dirname(file)) == "generated":
        if os.path.basename(file) not in files:
            sys.exit(f"{name}: no template for {file}")
        config["content"] = files[os.path.basename(file)]
print(json.dumps(project))
PY
  rm -f "$project" "$files"
}

check_files() {
  local created_env="" created_generated="" render
  if [ ! -f .env ]; then
    cp .env.example .env
    created_env=1
  fi
  # The files of make configs: the project needs generated/configs.env.
  [ -d generated ] || created_generated=1
  if render="$(python3 -I ./render-configs.py 2>&1)"; then
    ok "make configs: ${render#configs: }"
  else
    bad "make configs: $render"
    [ -z "$created_env" ] || rm -f .env
    finish ""
  fi
  local engine json services server images
  for engine in postgresql; do
    if ! json="$(DB_ENGINE="$engine" COMPOSE_PROFILES="$engine" project_json 2>&1)"; then
      bad "$engine: docker compose config: $json"
      continue
    fi
    ok "$engine: docker compose config"
    services="$(DB_ENGINE="$engine" COMPOSE_PROFILES="$engine" docker compose config --services)"
    case "$engine" in postgresql) server=postgres ;; esac
    if grep -qx "$server" <<< "$services"; then
      ok "$engine: database server $server"
    else
      bad "$engine: the services must have $server"
    fi
    images="$(DB_ENGINE="$engine" COMPOSE_PROFILES="$engine" docker compose config --images)"
    if grep -Eiq 'hashicorp|(^|/)vault(:|@|$)|keycloak|facade|mongo' <<< "$images"; then
      bad "$engine: a forbidden image"
    else
      ok "$engine: images"
    fi
    if command -v python3 > /dev/null && python3 -c 'import yaml' 2> /dev/null; then
      local project_file output
      project_file="$(mktemp)"
      printf '%s' "$json" > "$project_file"
      if output="$(python3 - "$engine" "$project_file" 2>&1 <<'PY'
import json
import sys

import yaml

engine = sys.argv[1]
port = {"postgresql": 5432}[engine]
with open(sys.argv[2], encoding="utf-8") as project_file:
    project = json.load(project_file)
problems = []
count = 0


def databases(node, path=""):
    """The database blocks: a mapping with a "type" key."""
    if isinstance(node, dict):
        if "type" in node and ("name" in node or "port" in node):
            yield path, node
        for key, value in node.items():
            yield from databases(value, f"{path}.{key}".lstrip("."))
    elif isinstance(node, list):
        for item in node:
            yield from databases(item, path)


for name, config in sorted(project.get("configs", {}).items()):
    content = config.get("content")
    if content is None:
        continue
    count += 1
    try:
        document = json.loads(content) if name == "dashboard-config" else yaml.safe_load(content)
    except Exception as error:  # noqa: BLE001
        problems.append(f"{name}: {error}")
        continue
    if not isinstance(document, dict):
        problems.append(f"{name}: not a mapping")
        continue
    for path, block in databases(document):
        if block.get("type") != engine or block.get("port") != port:
            problems.append(f"{name}: {path} has type {block.get('type')!r}, port {block.get('port')!r}")
if problems:
    print("\n".join(problems))
    sys.exit(1)
print(f"{count} configuration files")
PY
)"; then
        ok "$engine: $output parse, database type $engine"
      else
        bad "$engine: configuration files: $output"
      fi
      rm -f "$project_file"
    else
      warn "$engine: configuration files not parsed (python3 with PyYAML is not on this computer)"
    fi
  done

  # The key stores of the wallet files: the local key store in OpenBao
  # (local_backend openbao) and the organisation key store types.
  if command -v python3 > /dev/null && python3 -c 'import yaml' 2> /dev/null; then
    local output project_file
    if ! json="$(project_json 2>&1)"; then
      bad "key stores: docker compose config: $json"
    else
      project_file="$(mktemp)"
      printf '%s' "$json" > "$project_file"
      if output="$(python3 - "$project_file" 2>&1 <<'PY'
import json
import sys

import yaml

with open(sys.argv[1], encoding="utf-8") as project_file:
    project = json.load(project_file)
problems = []
types = ["vault", "csc", "gcp-kms", "aws-kms", "azure-key-vault"]
for role in ("config", "service", "worker"):
    kms = yaml.safe_load(project["configs"][f"wallet-{role}-config"]["content"])["kms"]
    if kms.get("local_backend") != "openbao":
        problems.append(f"wallet-{role}: local_backend {kms.get('local_backend')!r}")
    if kms.get("organisation_key_store_types") != types:
        problems.append(f"wallet-{role}: organisation_key_store_types {kms.get('organisation_key_store_types')}")
if problems:
    print("; ".join(problems))
    sys.exit(1)
print("local key store openbao, organisation key store types " + ", ".join(types))
PY
)"; then
        ok "key stores: $output"
      else
        bad "key stores: $output"
      fi
      rm -f "$project_file"
    fi
  fi

  # The database roles of the wallet: wallet-database-roles (database-roles
  # apply as the admin user, one password file per login database role)
  # after database-init, then wallet-migrate as the migrator, then the
  # read access (admin user) and the wallet processes (launcher and jobs
  # database roles). The database user of each configuration has the
  # password file of make secrets for that user, and no service of the
  # wallet image mounts the password of the owner user igrant_wallet.
  if command -v python3 > /dev/null && python3 -c 'import yaml' 2> /dev/null; then
    local output project_file admin
    admin="$(sed -n 's/^DB_ADMIN_USER=//p' config/engine/postgresql.env)"
    if ! json="$(project_json 2>&1)"; then
      bad "database roles: docker compose config: $json"
    else
      project_file="$(mktemp)"
      printf '%s' "$json" > "$project_file"
      if output="$(python3 - "$project_file" "$admin" 2>&1 <<'PY'
import json
import sys

import yaml

with open(sys.argv[1], encoding="utf-8") as project_file:
    project = json.load(project_file)
admin = sys.argv[2]
services = project["services"]
problems = []
# The login database roles of database-roles, by the name without the
# prefix igrant_wallet (the name of the wallet database).
roles = ["migrator", "launcher_app", "jobs", "clock", "audit_reader", "issuer_app", "relying_party_app",
         "business_wallet_app", "individual_wp_app", "business_wp_app", "admin_app"]
# Each service of the wallet image: its database user and the service that
# it waits for.
wallet = {
    "wallet-database-roles": (admin, "database-init"),
    "wallet-migrate": ("igrant_wallet_migrator", "wallet-database-roles"),
    "wallet-export-index": ("igrant_wallet_migrator", "wallet-migrate"),
    "wallet-read-access-api": (admin, "wallet-migrate"),
    "wallet-read-access-consent": (admin, "wallet-migrate"),
    "wallet-config": ("igrant_wallet_launcher_app", "wallet-migrate"),
    "wallet-service": ("igrant_wallet_launcher_app", "wallet-migrate"),
    "wallet-worker": ("igrant_wallet_jobs", "wallet-migrate"),
    "wallet-clock": ("igrant_wallet_clock", "wallet-migrate"),
}


def secret_file(name):
    """The file of make secrets of the secret name."""
    return project.get("secrets", {}).get(name, {}).get("file", "")


def password_file(user):
    return f"/secrets/database/{'admin' if user == admin else user}-password"


images = sorted(name for name, service in services.items() if "/eudi-wallet:" in service.get("image", ""))
if images != sorted(wallet):
    problems.append(f"the services of the wallet image are {images}, not {sorted(wallet)}")
for name, (user, before) in wallet.items():
    service = services.get(name)
    if service is None:
        problems.append(f"no service {name}")
        continue
    if service.get("depends_on", {}).get(before, {}).get("condition") != "service_completed_successfully":
        problems.append(f"{name} does not wait for {before} (service_completed_successfully)")
    path = service.get("environment", {}).get("EUDI_WALLET_CONFIG", "/etc/eudi-wallet/config.yaml")
    sources = [config["source"] for config in service.get("configs", []) if config.get("target") == path]
    if len(sources) != 1:
        problems.append(f"{name}: no configuration file at {path}")
        continue
    database = yaml.safe_load(project["configs"][sources[0]]["content"])["database"]
    if database.get("user") != user:
        problems.append(f"{name}: database user {database.get('user')!r}, not {user!r}")
    mounted = {secret.get("target"): secret["source"] for secret in service.get("secrets", [])}
    if not secret_file(mounted.get(database.get("password_file"), "")).endswith(password_file(user)):
        problems.append(f"{name}: {database.get('password_file')} is not the password file of {user}")
    if "db-igrant-wallet-password" in mounted.values():
        problems.append(f"{name} mounts the password of the owner user igrant_wallet")

roles_service = services.get("wallet-database-roles", {})
if roles_service.get("entrypoint") != ["/app/.venv/bin/database-roles"]:
    problems.append(f"wallet-database-roles: entrypoint {roles_service.get('entrypoint')}")
command = ["apply", "--password-dir", "/run/secrets/database-roles", "--admin-user", admin,
           "--admin-password-file", "/run/secrets/database/admin-password"]
if roles_service.get("command") != command:
    problems.append(f"wallet-database-roles: command {roles_service.get('command')}, not {command}")
mounted = {secret.get("target"): secret["source"] for secret in roles_service.get("secrets", [])}
if not secret_file(mounted.get("/run/secrets/database/admin-password", "")).endswith(password_file(admin)):
    problems.append("wallet-database-roles: no admin password at /run/secrets/database/admin-password")
directory = {target.rsplit("/", 1)[1]: source for target, source in mounted.items()
             if target.startswith("/run/secrets/database-roles/")}
if sorted(directory) != sorted(roles):
    problems.append(f"wallet-database-roles: --password-dir has {sorted(directory)}, not {sorted(roles)}")
for role, source in sorted(directory.items()):
    if not secret_file(source).endswith(password_file(f"igrant_wallet_{role}")):
        problems.append(f"wallet-database-roles: {role} is not the password file of igrant_wallet_{role}")
if problems:
    print("; ".join(problems))
    sys.exit(1)
print(f"wallet-database-roles ({len(roles)} login database roles), the order and the user of each wallet configuration")
PY
)"; then
        ok "database roles: $output"
      else
        bad "database roles: $output"
      fi
      rm -f "$project_file"
    fi
  fi

  # The DDL and connection logs of the database server: log_statement=ddl,
  # log_connections=on and log_disconnections=on in the command of postgres,
  # each server parameter once.
  if command -v python3 > /dev/null; then
    local output project_file
    if ! json="$(project_json 2>&1)"; then
      bad "database logs: docker compose config: $json"
    else
      project_file="$(mktemp)"
      printf '%s' "$json" > "$project_file"
      if output="$(python3 - "$project_file" 2>&1 <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as project_file:
    project = json.load(project_file)
command = project["services"]["postgres"]["command"]
parameters = [arg.split("=", 1) for option, arg in zip(command, command[1:]) if option == "-c"]
names = [name for name, _ in parameters]
expected = {"log_statement": "ddl", "log_connections": "on", "log_disconnections": "on"}
logs = {name: value for name, value in parameters if name in expected}
if len(names) != len(set(names)):
    sys.exit(f"a server parameter is set twice: {sorted(names)}")
if logs != expected:
    sys.exit(f"the log parameters of postgres are {logs}, not {expected}")
print("postgres logs the DDL statements, the connections and the disconnections")
PY
)"; then
        ok "database logs: $output"
      else
        bad "database logs: $output"
      fi
      rm -f "$project_file"
    fi
  fi
  # psql \password sends a SCRAM-SHA-256 verifier, never the password: no
  # password in a statement of database-init.
  if grep -q -F '\password' config/database/create-databases.sh && ! grep -q -w 'PASSWORD' config/database/create-databases.sh; then
    ok "database-init sets the passwords with psql \\password"
  else
    bad "database-init sends a password in a statement, not with psql \\password"
  fi

  # The built-in test CA (TEST_CA_ENABLED, TEST_CA_LEAF_VALIDITY_DAYS): the
  # section kms.test_ca of the wallet files. Empty values: the defaults.
  if command -v python3 > /dev/null && python3 -c 'import yaml' 2> /dev/null; then
    local enabled days
    for case_name in default off; do
      case "$case_name" in
        default) enabled="" days="" ;;
        off) enabled=false days=90 ;;
      esac
      if ! json="$(TEST_CA_ENABLED="$enabled" TEST_CA_LEAF_VALIDITY_DAYS="$days" project_json 2>&1)"; then
        bad "test CA $case_name: docker compose config: $json"
        continue
      fi
      project_file="$(mktemp)"
      printf '%s' "$json" > "$project_file"
      if output="$(python3 - "$project_file" "${enabled:-true}" "${days:-365}" 2>&1 <<'PY'
import json
import sys

import yaml

with open(sys.argv[1], encoding="utf-8") as project_file:
    project = json.load(project_file)
expected = {"enabled": sys.argv[2] == "true", "leaf_validity_days": int(sys.argv[3])}
for role in ("config", "service", "worker"):
    test_ca = yaml.safe_load(project["configs"][f"wallet-{role}-config"]["content"])["kms"].get("test_ca")
    if test_ca != expected:
        sys.exit(f"wallet-{role}: kms.test_ca {test_ca!r}, not {expected!r}")
print(f"kms.test_ca {expected}")
PY
)"; then
        ok "test CA $case_name: $output"
      else
        bad "test CA $case_name: $output"
      fi
      rm -f "$project_file"
    done
  fi

  # The feature gate of the gateway (FEATURES_ENFORCE): Features.enforce in
  # the gateway file only (the api refuses the section). Empty value: the
  # default true.
  if command -v python3 > /dev/null && python3 -c 'import yaml' 2> /dev/null; then
    local gate
    for gate in "" false; do
      if ! json="$(FEATURES_ENFORCE="$gate" project_json 2>&1)"; then
        bad "feature gate ${gate:-default}: docker compose config: $json"
        continue
      fi
      project_file="$(mktemp)"
      printf '%s' "$json" > "$project_file"
      if output="$(python3 - "$project_file" "${gate:-true}" 2>&1 <<'PY'
import json
import sys

import yaml

with open(sys.argv[1], encoding="utf-8") as project_file:
    project = json.load(project_file)
expected = {"enforce": sys.argv[2] == "true"}
features = yaml.safe_load(project["configs"]["gateway-config"]["content"]).get("Features")
if features != expected:
    sys.exit(f"gateway: Features {features!r}, not {expected!r}")
for name in ("api-config", "webhook-config"):
    config = project["configs"].get(name)
    if config and "Features" in yaml.safe_load(config["content"]):
        sys.exit(f"{name} has a Features section (only the gateway file has it)")
print(f"Features {expected}")
PY
)"; then
        ok "feature gate ${gate:-default}: $output"
      else
        bad "feature gate ${gate:-default}: $output"
      fi
      rm -f "$project_file"
    done
  fi

  # The limits of the installation (MAX_ORGANISATIONS,
  # MAX_ORGANISATION_WALLET_UNITS): Limits.maxOrganisations in the api and
  # webhook files and wallet_unit.organisation_wallet_units_max in the
  # config, service and worker files, as integers, only when the setting
  # has a value (an api or a wallet of an earlier release refuses the
  # keys). No other file has them: not the gateway file (the gateway
  # refuses the section) or the clock file.
  if command -v python3 > /dev/null && python3 -c 'import yaml' 2> /dev/null; then
    local organisations units
    for case_name in default set; do
      case "$case_name" in
        default) organisations="" units="" ;;
        set) organisations=250 units=300 ;;
      esac
      if ! json="$(MAX_ORGANISATIONS="$organisations" MAX_ORGANISATION_WALLET_UNITS="$units" project_json 2>&1)"; then
        bad "installation limits $case_name: docker compose config: $json"
        continue
      fi
      project_file="$(mktemp)"
      printf '%s' "$json" > "$project_file"
      if output="$(python3 - "$project_file" "$organisations" "$units" 2>&1 <<'PY'
import json
import sys

import yaml

with open(sys.argv[1], encoding="utf-8") as project_file:
    project = json.load(project_file)
organisations = int(sys.argv[2]) if sys.argv[2] else None
units = int(sys.argv[3]) if sys.argv[3] else None
checked = set()
for name in ("api-config", "webhook-config"):
    limits = yaml.safe_load(project["configs"][name]["content"]).get("Limits")
    want = {"maxOrganisations": organisations} if organisations else None
    if limits != want or (limits and type(limits["maxOrganisations"]) is not int):
        sys.exit(f"{name}: Limits {limits!r}, not {want!r}")
    checked.add(name)
for role in ("config", "service", "worker"):
    name = f"wallet-{role}-config"
    unit = yaml.safe_load(project["configs"][name]["content"]).get("wallet_unit") or {}
    got = unit.get("organisation_wallet_units_max")
    if got != units or (got is not None and type(got) is not int):
        sys.exit(f"{name}: wallet_unit.organisation_wallet_units_max {got!r}, not {units!r}")
    checked.add(name)
for name, config in project["configs"].items():
    for word in ("maxOrganisations", "organisation_wallet_units_max"):
        if name not in checked and word in config.get("content", ""):
            sys.exit(f"{name} has {word}")
print(f"Limits.maxOrganisations {organisations}, wallet_unit.organisation_wallet_units_max {units}")
PY
)"; then
        ok "installation limits $case_name: $output"
      else
        bad "installation limits $case_name: $output"
      fi
      rm -f "$project_file"
    done
  fi

  # The webhooks and the services of the installation: Webhooks of the api
  # and webhook files has only DeliveryRetentionDays (the effective
  # features of each organisation select the event types), and no file has
  # Installation (Compose installs all services).
  if command -v python3 > /dev/null && python3 -c 'import yaml' 2> /dev/null; then
    if ! json="$(project_json 2>&1)"; then
      bad "webhooks and services: docker compose config: $json"
    else
      project_file="$(mktemp)"
      printf '%s' "$json" > "$project_file"
      if output="$(python3 - "$project_file" 2>&1 <<'PY'
import json
import sys

import yaml

with open(sys.argv[1], encoding="utf-8") as project_file:
    project = json.load(project_file)
for name in ("api-config", "webhook-config"):
    webhooks = yaml.safe_load(project["configs"][name]["content"]).get("Webhooks")
    if webhooks != {"DeliveryRetentionDays": 10}:
        sys.exit(f"{name}: Webhooks {webhooks!r}, not only DeliveryRetentionDays")
for name, config in sorted(project["configs"].items()):
    if "Installation" in config.get("content", ""):
        sys.exit(f"{name} has Installation")
print("Webhooks without events, no Installation")
PY
)"; then
        ok "webhooks and services: $output"
      else
        bad "webhooks and services: $output"
      fi
      rm -f "$project_file"
    fi
  fi

  # The platform operator targets of the Makefile (make -n: no container):
  # the commands of the api, the password of the first platform admin on
  # standard input (--password-file -, never an argument), and the API core
  # may publish the deletion of an organisation.
  local dry
  if dry="$(make -n platform-operator ADMIN_EMAIL=admin@example.com ADMIN_NAME='First Admin' ORG_NAME='Example Wallet Provider' \
      ORG_LOCATION=Stockholm ORG_POLICY_URL=https://example.com/privacy 2>&1)" \
    && grep -q -F 'onboard bootstrap-platform' <<< "$dry" && grep -q -F -- '--password-file - ' <<< "$dry" \
    && grep -q -F -- '--organisation-name "Example Wallet Provider" --type "Technology"' <<< "$dry" \
    && ! grep -q -E -- '--password[= ]' <<< "$dry"; then
    ok "make platform-operator runs onboard bootstrap-platform with the password on standard input"
  else
    bad "make platform-operator: $dry"
  fi
  if dry="$(make -n platform-set-operator ORGANISATION_ID=6731f0c2a1b2c3d4e5f60789 2>&1)" \
    && grep -q -F 'platform set-operator --organisation-id "6731f0c2a1b2c3d4e5f60789"' <<< "$dry" \
    && dry="$(make -n platform-grant-admin ADMIN_EMAIL=admin@example.com 2>&1)" \
    && grep -q -F 'platform grant-admin --email "admin@example.com"' <<< "$dry" \
    && dry="$(make -n platform-status 2>&1)" && grep -q -F 'platform status' <<< "$dry"; then
    ok "make platform-set-operator, platform-grant-admin and platform-status"
  else
    bad "the platform operator targets: $dry"
  fi
  if make platform-operator > /dev/null 2>&1 || make platform-set-operator > /dev/null 2>&1 || make platform-grant-admin > /dev/null 2>&1; then
    bad "a platform operator target runs without its values"
  else
    ok "the platform operator targets stop without their values"
  fi
  if grep -q -F '"api.v1.evt.organisation.deleted"' config/nats/users.conf; then
    ok "the NATS user of the api publishes api.v1.evt.organisation.deleted"
  else
    bad "config/nats/users.conf: the api cannot publish api.v1.evt.organisation.deleted (make nats-config)"
  fi

  # The audit log (AUDIT_RETENTION_YEARS): the same retention in the files of
  # the wallet roles and of wallet-migrate (the partition step), and no audit
  # bucket. Empty value: the default.
  if command -v python3 > /dev/null && python3 -c 'import yaml' 2> /dev/null; then
    local years
    for years in "" 10; do
      if ! json="$(AUDIT_RETENTION_YEARS="$years" project_json 2>&1)"; then
        bad "audit log ${years:-default}: docker compose config: $json"
        continue
      fi
      project_file="$(mktemp)"
      printf '%s' "$json" > "$project_file"
      if output="$(python3 - "$project_file" "${years:-7}" 2>&1 <<'PY'
import json
import sys

import yaml

with open(sys.argv[1], encoding="utf-8") as project_file:
    project = json.load(project_file)
expected = {"retention_years": int(sys.argv[2])}
for name in ("config", "service", "worker", "migrate"):
    audit = yaml.safe_load(project["configs"][f"wallet-{name}-config"]["content"]).get("audit")
    if audit != expected:
        sys.exit(f"wallet-{name}: audit {audit!r}, not {expected!r}")
if "audit" in yaml.safe_load(project["configs"]["wallet-clock-config"]["content"]):
    sys.exit("wallet-clock: an audit section (the clock writes no audit event)")
print(f"audit {expected}, no bucket")
PY
)"; then
        ok "audit log ${years:-default}: $output"
      else
        bad "audit log ${years:-default}: $output"
      fi
      rm -f "$project_file"
    done
  fi

  # Valkey: the three services, the templates of config/valkey/, the ACL
  # users of make secrets and the redis section of each wallet role.
  if command -v python3 > /dev/null && python3 -c 'import yaml' 2> /dev/null; then
    local output project_file
    if ! json="$(project_json 2>&1)"; then
      bad "Valkey: docker compose config: $json"
    else
      project_file="$(mktemp)"
      printf '%s' "$json" > "$project_file"
      if output="$(python3 - "$project_file" "$(sed -n 's/^VALKEY_IMAGE=//p' .env.example)" 2>&1 <<'PY'
import json
import re
import sys

import yaml

with open(sys.argv[1], encoding="utf-8") as project_file:
    project = json.load(project_file)
image = sys.argv[2]
services = project["services"]
problems = []
users = ["wallet-config", "wallet-service", "wallet-worker", "wallet-clock", "gateway", "replication", "sentinel", "probe"]
wallet_rights = "resetchannels ~ows:* ~ows-wallet ~ows-wallet:* -@all +@read +@write +@scripting +@connection -@dangerous +info +keys"
gateway_rights = "resetchannels ~gw:* -@all +@read +@write +@connection -@dangerous"
order = {"valkey": (None, "primary"), "valkey-replica": ("valkey", "replica"), "valkey-sentinel": ("valkey-replica", "sentinel")}
for name, (before, role) in order.items():
    service = services.get(name)
    if service is None:
        problems.append(f"no service {name}")
        continue
    if service.get("image") != image:
        problems.append(f"{name}: image {service.get('image')!r}, not VALKEY_IMAGE of .env.example")
    if service.get("user") != "999:1000" or service.get("entrypoint") != ["/bin/sh", "/etc/valkey/start.sh"] or service.get("command") != [role]:
        problems.append(f"{name}: not start.sh {role} as the user valkey (999:1000)")
    if before and (service.get("depends_on") or {}).get(before, {}).get("condition") != "service_healthy":
        problems.append(f"{name} does not wait for {before} (service_healthy)")
    if "--user probe" not in " ".join(service.get("healthcheck", {}).get("test", [])):
        problems.append(f"{name}: the healthcheck does not log in as probe")
    if not any(t.startswith("/run/valkey:") for t in service.get("tmpfs", [])):
        problems.append(f"{name}: /run/valkey is not a tmpfs")
    mounted = {s["target"]: project["secrets"][s["source"]]["file"] for s in service.get("secrets", [])}
    for user in users:
        if not mounted.get(f"/run/secrets/valkey/{user}", "").endswith(f"/secrets/valkey/{user}-password"):
            problems.append(f"{name}: no password file of {user}")
    targets = {c["target"]: project["configs"][c["source"]]["file"] for c in service.get("configs", [])}
    for target in ("start.sh", "valkey.conf", "users.acl", "sentinel.conf"):
        if not targets.get(f"/etc/valkey/{target}", "").endswith(f"/config/valkey/{target}"):
            problems.append(f"{name}: no /etc/valkey/{target}")
for name in ("valkey", "valkey-replica"):
    if not any(v.get("target") == "/data" for v in services.get(name, {}).get("volumes", [])):
        problems.append(f"{name}: no volume at /data")
server = open("config/valkey/valkey.conf", encoding="utf-8").read().splitlines()
for setting in ("appendonly yes", "appendfsync everysec", "maxmemory-policy noeviction", "min-replicas-to-write 1",
                "min-replicas-max-lag 10", "masteruser replication", "masterauth {password:replication}",
                "aclfile /run/valkey/users.acl", "replica-announce-ip {self}"):
    if setting not in server:
        problems.append(f"valkey.conf has not {setting!r}")
acl = open("config/valkey/users.acl", encoding="utf-8").read().splitlines()
expected_acl = ["user default off"] + [f"user {u} on {{hash:{u}}} {wallet_rights}" for u in users if u.startswith("wallet-")] + [f"user gateway on {{hash:gateway}} {gateway_rights}"]
for line in expected_acl:
    if line not in acl:
        problems.append(f"users.acl has not {line!r}")
if sorted(re.findall(r"^user (\S+)", "\n".join(acl), re.M)) != sorted(["default"] + users):
    problems.append("users.acl has other users than default and the users of make secrets")
sentinel = open("config/valkey/sentinel.conf", encoding="utf-8").read().splitlines()
for setting in ("sentinel monitor ows {primary} 6379 1", "sentinel resolve-hostnames yes", "sentinel announce-hostnames yes",
                "sentinel auth-user ows sentinel", "user default off"):
    if setting not in sentinel:
        problems.append(f"sentinel.conf has not {setting!r}")
made = re.search(r"for name in ([a-z -]+); do\n  password \"valkey/", open("secrets.sh", encoding="utf-8").read())
if not made or sorted(made.group(1).split()) != sorted(users):
    problems.append("make secrets does not make the password of each Valkey user")
for role in ("config", "service", "worker", "clock"):
    user = f"wallet-{role}"
    redis = yaml.safe_load(project["configs"][f"wallet-{role}-config"]["content"]).get("redis")
    expected = {"queue": {"sentinels": ["valkey-sentinel:26379"], "master_name": "ows", "username": user,
                          "password_file": "/run/secrets/eudi-wallet/redis-password", "sentinel_username": user,
                          "sentinel_password_file": "/run/secrets/eudi-wallet/redis-password", "tls": False}}
    if redis != expected:
        problems.append(f"wallet-{role}: redis {redis!r}")
    mounted = {s["target"]: s["source"] for s in services[f"wallet-{role}"].get("secrets", [])}
    if mounted.get("/run/secrets/eudi-wallet/redis-password") != f"valkey-{user}-password":
        problems.append(f"wallet-{role} does not mount the password of {user}")
mounted = {s["target"]: s["source"] for s in services["gateway"].get("secrets", [])}
if mounted.get("/run/secrets/igrant-gateway/redis-password") != "valkey-gateway-password":
    problems.append("the gateway does not mount the password of its Valkey user")
if "redis" in project["configs"]["gateway-config"]["content"].lower():
    problems.append("the gateway configuration has a Valkey key (the gateway refuses an unknown key)")
if problems:
    print("; ".join(problems))
    sys.exit(1)
print("the services, the templates, the ACL users and the redis section of each wallet role")
PY
)"; then
        ok "Valkey: $output"
      else
        bad "Valkey: $output"
      fi
      rm -f "$project_file"
    fi
  fi

  # The worker and the clock: the command of each (the worker with all
  # queues), the health port of the healthcheck, the state folder of the
  # worker, the worker and clock sections, and the files of the clock (only
  # the password of its database role and of its Valkey user: no NATS seed,
  # no OpenBao password).
  if command -v python3 > /dev/null && python3 -c 'import yaml' 2> /dev/null; then
    local output project_file
    if ! json="$(project_json 2>&1)"; then
      bad "worker and clock: docker compose config: $json"
    else
      project_file="$(mktemp)"
      printf '%s' "$json" > "$project_file"
      if output="$(python3 - "$project_file" 2>&1 <<'PY'
import json
import sys

import yaml

with open(sys.argv[1], encoding="utf-8") as project_file:
    project = json.load(project_file)
services = project["services"]
problems = []
worker, clock = services.get("wallet-worker", {}), services.get("wallet-clock", {})
command = ["/app/.venv/bin/dramatiq", "ows.worker.run:start", "--processes", "1", "--threads", "8",
           "--worker-shutdown-timeout", "3600000", "--worker-fork-timeout", "600000",
           "--queues", "realtime", "attestation", "status", "kms", "maintenance"]
if worker.get("command") != command:
    problems.append(f"wallet-worker: command {worker.get('command')}")
if clock.get("command") != ["/app/.venv/bin/start-clock"]:
    problems.append(f"wallet-clock: command {clock.get('command')}")
for name, service, port in (("wallet-worker", worker, 9191), ("wallet-clock", clock, 9192)):
    if f"http://127.0.0.1:{port}/readyz" not in " ".join(service.get("healthcheck", {}).get("test", [])):
        problems.append(f"{name}: the healthcheck is not /readyz of the port {port}")
if not any(t == "/run/ows-worker" or t.startswith("/run/ows-worker:") for t in worker.get("tmpfs", [])):
    problems.append("wallet-worker: /run/ows-worker is not a tmpfs")
worker_file = yaml.safe_load(project["configs"]["wallet-worker-config"]["content"])
if worker_file.get("worker") != {"health_port": 9191, "state_directory": "/run/ows-worker"}:
    problems.append(f"wallet-worker: worker {worker_file.get('worker')!r}")
clock_file = yaml.safe_load(project["configs"]["wallet-clock-config"]["content"])
if set(clock_file) != {"log_level", "database", "redis", "clock"}:
    problems.append(f"wallet-clock: the keys {sorted(clock_file)}")
if clock_file.get("clock") != {"health_port": 9192}:
    problems.append("wallet-clock: the health port is not 9192")
if "wallet-scheduler" in project["services"] or "wallet-scheduler-config" in project["configs"]:
    problems.append("the scheduler is still a service (organisation-wallet-suite removed it)")
targets = sorted(s["target"] for s in clock.get("secrets", []))
if targets != ["/run/secrets/eudi-wallet/database-password", "/run/secrets/eudi-wallet/redis-password"]:
    problems.append(f"wallet-clock mounts {targets}")
if "nats" in (clock.get("depends_on") or {}) or "openbao-init" in (clock.get("depends_on") or {}):
    problems.append("wallet-clock waits for NATS or OpenBao")
if problems:
    print("; ".join(problems))
    sys.exit(1)
print("the commands, the health ports, the state folder and the files of the clock")
PY
)"; then
        ok "worker and clock: $output"
      else
        bad "worker and clock: $output"
      fi
      rm -f "$project_file"
    fi
  fi

  # The configuration files (README.md, "Configuration files"): the
  # templates of compose.configs.yaml, each one in the list of the service
  # render; one file config of generated/ for each template and no config
  # of content in the project; the same values files for the render as for
  # the services (and generated/configs.env only for the services); the
  # label of each service that reads a file of generated/ is the SHA-256 of
  # the file; the templates have only the variables of .env.example and of
  # config/engine/ (the settings: no secret), and each key of a file with a
  # password, a secret or a seed names a file.
  if command -v python3 > /dev/null && python3 -c 'import yaml' 2> /dev/null; then
    local output project_file variables_file
    project_file="$(mktemp)"
    variables_file="$(mktemp)"
    if ! COMPOSE_PROFILES='*' docker compose config --format json > "$project_file" 2>&1; then
      bad "configuration files: docker compose config: $(cat "$project_file")"
    elif ! docker compose -f compose.configs.yaml --profile render config --variables --format json > "$variables_file" 2>&1; then
      bad "configuration files: the variables of the templates: $(cat "$variables_file")"
    elif output="$(python3 - "$project_file" "$variables_file" 2>&1 <<'PY'
import hashlib
import json
import os
import re
import sys

import yaml

project = json.load(open(sys.argv[1], encoding="utf-8"))
variables = json.load(open(sys.argv[2], encoding="utf-8"))
problems = []
templates_file = yaml.safe_load(open("compose.configs.yaml", encoding="utf-8"))
templates = templates_file.get("configs") or {}
listed = [entry if isinstance(entry, str) else entry.get("source") for entry in templates_file["services"]["render"].get("configs") or []]
if sorted(listed) != sorted(templates) or len(listed) != len(set(listed)):
    problems.append(f"the service render names {sorted(listed)}, not each template {sorted(templates)}")
if list(templates_file["services"]) != ["render"] or templates_file["services"]["render"].get("profiles") != ["render"]:
    problems.append("compose.configs.yaml has another service than render, or render is not only in the profile render")
for name, config in templates.items():
    if not re.match(r"^[a-z0-9][a-z0-9-]*\.(yaml|json)$", name) or set(config) != {"content"}:
        problems.append(f"the template {name} is not <name>.yaml or <name>.json with only content")
# The same values files, in the same order.
def env_files(path):
    return yaml.safe_load(open(path, encoding="utf-8"))["include"][0]["env_file"]
services_files, render_files = env_files("docker-compose.yaml"), env_files("compose.render.yaml")
if services_files != render_files + ["generated/configs.env"]:
    problems.append(f"the values files of the services {services_files} are not those of the render {render_files} and generated/configs.env")
# One file config of generated/ for each template, no config of content.
generated = {}
for name, config in project.get("configs", {}).items():
    if "content" in config:
        problems.append(f"the config {name} has content")
    file = config.get("file", "")
    if os.path.dirname(file) == os.path.join(os.getcwd(), "generated"):
        base = os.path.basename(file)
        if base.rsplit(".", 1)[0] != name:
            problems.append(f"the config {name} is the file {base}")
        generated[name] = base
if sorted(generated.values()) != sorted(templates):
    problems.append(f"the file configs of generated/ {sorted(generated.values())} are not the templates {sorted(templates)}")
# The hash label of each service, and the hash in generated/configs.env.
hashes = dict(line.split("=", 1) for line in open("generated/configs.env", encoding="utf-8").read().splitlines() if line and not line.startswith("#"))
labelled = 0
for service_name, service in project["services"].items():
    labels = service.get("labels") or {}
    sources = [entry["source"] for entry in service.get("configs") or [] if entry["source"] in generated]
    for source in sources:
        digest = hashlib.sha256(open(os.path.join("generated", generated[source]), "rb").read()).hexdigest()
        variable = "CONFIG_SHA256_" + source.upper().replace("-", "_")
        if labels.get(f"io.igrant.config-sha256.{source}") != digest or hashes.get(variable) != digest:
            problems.append(f"{service_name}: the label io.igrant.config-sha256.{source} is not the SHA-256 of generated/{generated[source]}")
        labelled += 1
    for label in labels:
        if label.startswith("io.igrant.config-sha256.") and label.split(".", 3)[3] not in sources:
            problems.append(f"{service_name}: the label {label} without its config")
# The variables of the templates: only the settings.
settings = set()
for path in (".env.example", "config/engine/postgresql.env"):
    settings |= set(re.findall(r"^([A-Z][A-Z0-9_]*)=", open(path, encoding="utf-8").read(), re.M))
unknown = sorted(set(variables) - settings)
if unknown:
    problems.append(f"the templates use {unknown}, which are not settings of .env.example or config/engine/")
# Each key with a password, a secret or a seed names a file (an absolute
# path), in each file of generated/.
def keys(node, path=""):
    if isinstance(node, dict):
        for key, value in node.items():
            yield f"{path}.{key}".lstrip("."), str(key), value
            yield from keys(value, f"{path}.{key}".lstrip("."))
    elif isinstance(node, list):
        for item in node:
            yield from keys(item, path)
for base in sorted(templates):
    text = open(os.path.join("generated", base), encoding="utf-8").read()
    document = json.loads(text) if base.endswith(".json") else yaml.safe_load(text)
    for path, key, value in keys(document):
        if re.search(r"password|secret|seed", key, re.I) and not isinstance(value, (dict, list)):
            if not re.search(r"file$", key, re.I) or not str(value).startswith("/"):
                problems.append(f"generated/{base}: {path} is a value, not the path of a file")
if problems:
    print("; ".join(problems))
    sys.exit(1)
print(f"{len(templates)} templates, {len(generated)} file configs of generated/, {labelled} hash labels, "
      f"{len(variables)} variables of the settings, no secret value")
PY
)"; then
      ok "configuration files: $output"
    else
      bad "configuration files: $output"
    fi
    rm -f "$project_file" "$variables_file"
  fi

  # The renderer (render-configs.py) in a copy of this folder, with one more
  # template: $$ gives $, ${VAR:+...} and a value with $ of the shell are
  # the rules of Compose; the modes 0644 (files) and 0755 (folder); a file
  # that is not a template (a stale file, a temporary file of a stopped
  # run) goes; --check passes, and fails after a change of a value; a
  # second run writes the same bytes; a missing required value stops the
  # run before it writes a file.
  if command -v python3 > /dev/null; then
    local copy output
    copy="$(mktemp -d)"
    tar -c --exclude ./secrets --exclude ./generated . | tar -x -C "$copy"
    if output="$(cd "$copy" && python3 - 2>&1 <<'PY'
import hashlib, os, stat, subprocess, sys
problems = []
text = open("compose.configs.yaml", encoding="utf-8").read()
text = text.replace("    configs:\n      - ", "    configs:\n      - zz-test.yaml\n      - ", 1)
text += "  zz-test.yaml:\n    content: |\n      dollar: $$HOME\n      ${RENDER_TEST:+test: ${RENDER_TEST}}\n      tag: ${PLATFORM_TAG}\n"
open("compose.configs.yaml", "w", encoding="utf-8").write(text)
os.makedirs("generated", exist_ok=True)
for stale in ("stale.yaml", ".render-left"):
    open(os.path.join("generated", stale), "w").write("x")
env = dict(os.environ, RENDER_TEST="a$b")
def run(*args, extra=None):
    return subprocess.run([sys.executable, "-I", "render-configs.py", *args], env=dict(env, **(extra or {})),
                          stdout=subprocess.PIPE, stderr=subprocess.STDOUT, universal_newlines=True)
first = run()
if first.returncode != 0:
    sys.exit(f"the render failed: {first.stdout}")
tag = [l.split("=", 1)[1] for l in open(".env", encoding="utf-8").read().splitlines() if l.startswith("PLATFORM_TAG=")][-1]
want = f"dollar: $HOME\ntest: a$b\ntag: {tag}\n".encode()
got = open("generated/zz-test.yaml", "rb").read()
if got != want:
    problems.append(f"zz-test.yaml is {got!r}, not {want!r}")
if stat.S_IMODE(os.stat("generated/zz-test.yaml").st_mode) != 0o644 or stat.S_IMODE(os.stat("generated").st_mode) != 0o755:
    problems.append("the modes are not 0644 (files) and 0755 (folder)")
if os.path.exists("generated/stale.yaml") or os.path.exists("generated/.render-left"):
    problems.append("a file that is not a template stays")
if f"CONFIG_SHA256_ZZ_TEST={hashlib.sha256(want).hexdigest()}" not in open("generated/configs.env").read():
    problems.append("configs.env has not the SHA-256 of zz-test.yaml")
snapshot = {name: open(os.path.join("generated", name), "rb").read() for name in os.listdir("generated")}
if run("--check").returncode != 0:
    problems.append("--check fails after the render")
changed = run("--check", extra={"RENDER_TEST": "other"})
if changed.returncode == 0 or "zz-test.yaml" not in changed.stdout or "configs.env" not in changed.stdout:
    problems.append(f"--check passes after a change of a value: {changed.stdout.strip()}")
if run().returncode != 0 or {name: open(os.path.join("generated", name), "rb").read() for name in os.listdir("generated")} != snapshot:
    problems.append("a second run writes other bytes")
text = open("compose.configs.yaml", encoding="utf-8").read()
open("compose.configs.yaml", "w", encoding="utf-8").write(text + "      required: ${RENDER_MISSING:?RENDER_MISSING is required}\n")
missing = run(extra={"RENDER_TEST": "new"})
if missing.returncode == 0 or "RENDER_MISSING is required" not in missing.stdout:
    problems.append(f"a missing required value does not stop the render: {missing.stdout.strip()}")
if {name: open(os.path.join("generated", name), "rb").read() for name in os.listdir("generated")} != snapshot:
    problems.append("a stopped render changed a file")
if problems:
    print("; ".join(problems))
    sys.exit(1)
print("$$, ${VAR:+...} and a value with $, the modes, the removal of a stale file, --check, a second run and a missing value")
PY
)"; then
      ok "make configs: $output"
    else
      bad "make configs: $output"
    fi
    rm -rf "$copy"
  fi

  # The security settings of EACH service (README.md, "Security settings"),
  # with all profiles: a read-only root file system, no capability, no new
  # privileges, its user (UID:GID, not root), the tmpfs (each with a size)
  # and the volumes of the paths that it writes, no config of "content", no
  # host namespace, no device, no privileged mode, and only bind mounts of
  # secrets/ (read-only, but the state folder of openbao-init). A service
  # that this list does not know fails: add it with its user and its
  # writable paths. The ports below 1024 come with the sysctl
  # net.ipv4.ip_unprivileged_port_start. The api image has no shell: no
  # service of the api image starts a shell. The one-shot services of root
  # (nats-data-owner) have only their capabilities, and no network.
  if command -v python3 > /dev/null; then
    local output project_file
    if ! json="$(COMPOSE_PROFILES='*' docker compose config --format json 2>&1)"; then
      bad "security settings: docker compose config: $json"
    else
      project_file="$(mktemp)"
      printf '%s' "$json" > "$project_file"
      if output="$(python3 - "$project_file" "$PWD" "$HOST_UID:$HOST_GID" 2>&1 <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as project_file:
    project = json.load(project_file)
folder, host_user = sys.argv[2], sys.argv[3]
services = project["services"]
problems = []
API, WALLET, CONSENT = "65532:65532", "65532:65532", "65532:65532"
# Each service: its user, the tmpfs paths and the volume paths that it
# writes.
expected = {
    "postgres": ("999:999", ["/var/run/postgresql", "/tmp"], ["/var/lib/postgresql"]),
    "database-init": ("999:999", ["/tmp"], []),
    "nats": ("65532:65532", [], ["/data"]),
    "openbao": ("100:1000", ["/tmp"], ["/openbao/file"]),
    "openbao-init": (host_user, ["/tmp"], []),
    "valkey": ("999:1000", ["/run/valkey", "/tmp"], ["/data"]),
    "valkey-replica": ("999:1000", ["/run/valkey", "/tmp"], ["/data"]),
    "valkey-sentinel": ("999:1000", ["/run/valkey", "/tmp"], []),
    "api-migrate": (API, ["/tmp"], []),
    "api-read-access-wallet": (API, ["/tmp"], []),
    "api-read-access-consent": (API, ["/tmp"], []),
    "api": (API, ["/tmp"], []),
    "webhook": (API, ["/tmp"], []),
    "gateway": (API, [], []),
    "consent-migrate": (CONSENT, ["/tmp"], []),
    "consent-read-access": (CONSENT, ["/tmp"], []),
    "consent": (CONSENT, ["/tmp"], []),
    "wallet-database-roles": (WALLET, ["/tmp"], []),
    "wallet-migrate": (WALLET, ["/tmp"], []),
    "wallet-export-index": (WALLET, ["/tmp"], []),
    "wallet-read-access-api": (WALLET, ["/tmp"], []),
    "wallet-read-access-consent": (WALLET, ["/tmp"], []),
    "wallet-config": (WALLET, ["/tmp"], []),
    "wallet-service": (WALLET, ["/tmp"], []),
    "wallet-worker": (WALLET, ["/run/ows-worker"], ["/tmp"]),
    "wallet-clock": (WALLET, ["/tmp"], []),
    "dashboard": ("101:101", ["/tmp"], []),
}
# The one-shot services of root: the capabilities, the volume paths and the
# command of each.
NATS_OWNER = ["find", "/data", "(", "!", "-user", "65532", "-o", "!", "-group", "65532", ")",
              "-exec", "chown", "-h", "65532:65532", "{}", "+"]
root_one_shots = {
    "nats-data-owner": (["CHOWN", "DAC_READ_SEARCH"], ["/data"], NATS_OWNER),
}
# The bind mounts that a service may write (all other bind mounts are
# read-only): the state folder of openbao-init (init.json).
writable_binds = {("openbao-init", f"{folder}/secrets/openbao")}
low_ports = {"api", "webhook", "consent", "dashboard"}
for name in sorted(set(services) - set(expected) - set(root_one_shots)):
    problems.append(f"{name}: a service that this test does not know (add its user and its writable paths)")
for name in sorted((set(expected) | set(root_one_shots)) - set(services)):
    problems.append(f"no service {name}")
for name, service in sorted(services.items()):
    if service.get("read_only") is not True:
        problems.append(f"{name}: read_only is not true")
    if service.get("cap_drop") != ["ALL"]:
        problems.append(f"{name}: cap_drop {service.get('cap_drop')}")
    if "no-new-privileges:true" not in (service.get("security_opt") or []):
        problems.append(f"{name}: no no-new-privileges:true")
    for key in ("privileged", "devices", "device_cgroup_rules"):
        if service.get(key):
            problems.append(f"{name}: {key}")
    for key in ("pid", "ipc", "network_mode", "userns_mode", "uts", "cgroup"):
        if service.get(key) == "host":
            problems.append(f"{name}: {key} host")
    content = [config["source"] for config in service.get("configs") or [] if "content" in project["configs"].get(config["source"], {})]
    if content:
        problems.append(f"{name}: configs of content {content} (Compose cannot write them into a read-only container)")
    for entry in service.get("tmpfs") or []:
        if "size=" not in entry:
            problems.append(f"{name}: the tmpfs {entry} has no size")
    for volume in service.get("volumes") or []:
        if volume.get("type") == "bind":
            source = volume.get("source", "")
            if not source.startswith(f"{folder}/secrets/"):
                problems.append(f"{name}: a bind mount of {source} (only folders of secrets/)")
            if not volume.get("read_only") and (name, source) not in writable_binds:
                problems.append(f"{name}: the bind mount of {source} is not read-only")
        elif volume.get("type") != "volume":
            problems.append(f"{name}: a volume of the type {volume.get('type')}")
    targets = [volume.get("target") for volume in service.get("volumes") or [] if volume.get("type") == "volume"]
    if name in root_one_shots:
        caps, paths, entrypoint = root_one_shots[name]
        if service.get("user") != "0:0" or sorted(service.get("cap_add") or []) != sorted(caps) or service.get("network_mode") != "none":
            problems.append(f"{name}: user {service.get('user')}, cap_add {service.get('cap_add')}, network_mode {service.get('network_mode')}")
        if entrypoint and service.get("entrypoint") != entrypoint:
            problems.append(f"{name}: entrypoint {service.get('entrypoint')}")
        if service.get("tmpfs") or sorted(targets) != sorted(paths):
            problems.append(f"{name}: tmpfs {service.get('tmpfs')}, volumes {targets}")
        continue
    user, tmpfs, volumes = expected.get(name, ("?", [], []))
    if service.get("user") != user:
        problems.append(f"{name}: user {service.get('user')!r}, not {user!r}")
    uid, _, gid = str(service.get("user")).partition(":")
    if not (uid.isdigit() and gid.isdigit() and int(uid) > 0 and int(gid) > 0):
        problems.append(f"{name}: user {service.get('user')!r} is not a UID:GID other than root")
    if service.get("cap_add"):
        problems.append(f"{name}: cap_add {service.get('cap_add')}")
    mounted = [entry.split(":", 1)[0] for entry in service.get("tmpfs") or []]
    if sorted(mounted) != sorted(tmpfs):
        problems.append(f"{name}: tmpfs {mounted}, not {tmpfs}")
    for path in volumes:
        if path not in targets:
            problems.append(f"{name}: no volume at {path}")
    sysctl = str((service.get("sysctls") or {}).get("net.ipv4.ip_unprivileged_port_start"))
    if (name in low_ports) != (sysctl == "0"):
        problems.append(f"{name}: sysctl net.ipv4.ip_unprivileged_port_start {sysctl}")
for name, service in services.items():
    if "/api:" in service.get("image", "") and any(part in ("/bin/sh", "sh", "bash", "/bin/bash") for part in (service.get("entrypoint") or [])):
        problems.append(f"{name}: a shell in the api image (the image has no shell)")
if (services.get("nats", {}).get("depends_on") or {}).get("nats-data-owner", {}).get("condition") != "service_completed_successfully":
    problems.append("nats does not wait for nats-data-owner")
if "wallet-worker-tmp" not in project.get("volumes", {}):
    problems.append("no volume wallet-worker-tmp")
if "api-read-access" in services:
    problems.append("the service api-read-access is still there (it ran a shell in the api image)")
if "wallet-read-access" in services:
    problems.append("the service wallet-read-access is still there (it ran a shell in the wallet image)")
for name, service in services.items():
    if "/eudi-wallet:" in service.get("image", "") and any(part in ("/bin/sh", "sh", "bash", "/bin/bash") for part in (service.get("entrypoint") or [])):
        problems.append(f"{name}: a shell in the wallet image (the image has no shell)")
if problems:
    print("; ".join(problems))
    sys.exit(1)
print(f"{len(services)} services of all profiles: read-only, no capability, no new privileges, the users, the tmpfs and volumes;"
      f" root only: {', '.join(sorted(root_one_shots))} (with {', '.join(sorted({c for v in root_one_shots.values() for c in v[0]}))})")
PY
)"; then
        ok "security settings: $output"
      else
        bad "security settings: $output"
      fi
      rm -f "$project_file"
    fi
  fi

  local script
  for script in secrets.sh check.sh config/database/create-databases.sh; do
    if bash -n "$script"; then ok "bash -n $script"; else bad "bash -n $script"; fi
  done
  if sh -n config/openbao/bootstrap.sh; then ok "sh -n config/openbao/bootstrap.sh"; else bad "sh -n config/openbao/bootstrap.sh"; fi
  if sh -n config/valkey/start.sh; then ok "sh -n config/valkey/start.sh"; else bad "sh -n config/valkey/start.sh"; fi
  if python3 -I -m py_compile render-configs.py 2> /dev/null; then ok "python3 -m py_compile render-configs.py"; else bad "python3 -m py_compile render-configs.py"; fi
  rm -rf __pycache__

  if command -v nats-server > /dev/null; then
    local dir
    dir="$(mktemp -d)"
    cp config/nats/nats.conf config/nats/users.conf "$dir/"
    sed -i.orig "s#store_dir: \"/data\"#store_dir: \"${dir}/data\"#" "$dir/nats.conf"
    # Stand-in public nkeys (no secret) with the names of make secrets.
    cat > "$dir/nkeys.conf" <<'NKEYS'
NATS_NKEY_API: "UCEKSPNUPXXRDG7XXDV7QP6OVL65PNZOQE3BC6D2DYMS6VSRZG6KATFL"
NATS_NKEY_API_WEBHOOK: "UDLNQ4V73THWJRSWY47PSTWVPH2G4AME5ZJ2BD743BNHOLIRQIK46KHY"
NATS_NKEY_CONSENT: "UB7OGI7MLCXOD6X65KXC22DH3QBKBJOOXNM5ASKTGOT6TGRLN7H2DRV3"
NATS_NKEY_WALLET_CONFIG: "UCUBGBWEFKGAAPHRHLNTDDL53F7QVKXLIXWDMA5EYCEFGEZ7TERRRJTD"
NATS_NKEY_WALLET_SERVICE: "UC3VBAJ2Y63SP755G2QEVR6HVKGIPTLNSJT74N53PLM6UQN466BGAB2K"
NATS_NKEY_WALLET_WORKER: "UAGXS2RAA3KKGT722PQLZPXUOGC2GM7UEOFHE4RVSFPEHPDKA3IDT7VY"
NKEYS
    local output
    if output="$(nats-server -t -c "$dir/nats.conf" 2>&1)"; then
      ok "nats-server -t config/nats/nats.conf"
    else
      bad "nats-server -t: $output"
    fi
    rm -rf "$dir"
  else
    warn "NATS configuration not checked (nats-server is not on this computer)"
  fi

  # Text rules of the files of this folder (not the generated files): no em
  # or en dash, British English, none of the removed products and settings,
  # and no backup or upgrade text. Exceptions (keys that the code reads):
  # the wallet key "vault" (with its OpenBao comment).
  local text_files
  text_files="$(find . -type f ! -path './secrets/*' ! -path './generated/*' ! -name .env ! -name '*.orig' | sort)"
  local hits dashes
  dashes="$(printf '\xe2\x80\x94|\xe2\x80\x93')"
  # shellcheck disable=SC2086
  hits="$(grep -n -E "$dashes" $text_files || true)"
  if [ -n "$hits" ]; then bad "em or en dash: $hits"; else ok "no em or en dash"; fi
  # shellcheck disable=SC2086
  hits="$(grep -n -i -E 'organiz|\binitializ|behavior|\bcolor|\bcenter\b|authoriz|optimiz|licens|analyz|customiz|recogniz|minimiz|normaliz' $text_files | grep -v -E 'Apache License|authorization \\?\{' || true)"
  if [ -n "$hits" ]; then bad "American spelling: $hits"; else ok "British English spelling"; fi
  # shellcheck disable=SC2086
  hits="$(grep -n -i -E 'hashicorp|vault|kms_key|platform: *database|db-backed|data_key|facade|keycloak|mongo|aries|aca-py|cloud ?agent|\bssi\b|backup|upgrade|migration step|mailpit|rotator|allowplainapikeys' $text_files \
    | grep -v -E '^\./compose\.configs\.yaml:[0-9]+:( +vault:$| +# .*"vault" is| +organisation_key_store_types: \[vault, csc, gcp-kms, aws-kms, azure-key-vault\]$)' || true)"
  if [ -n "$hits" ]; then bad "removed product or setting: $hits"; else ok "no removed product or setting"; fi
  # The relative links of README.md (also into the docs of the chart): each
  # target file and each heading of an anchor exists.
  if hits="$(python3 ../tests/check_links.py README.md 2>&1)"; then ok "relative links of README.md"; else bad "relative links of README.md: $hits"; fi

  [ -z "$created_env" ] || rm -f .env
  [ -z "$created_generated" ] || rm -rf generated
  finish "all checks passed (${warnings} warning(s))"
}

check_files
