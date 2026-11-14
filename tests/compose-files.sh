#!/usr/bin/env bash
# Checks the files of docker-compose/ for maintainers. No container starts
# and no image is pulled: "docker compose config" needs no Docker daemon.
# Checks:
#   - docker compose config for each engine (postgresql): the engine's
#     database server, the images, and the database type and port in each
#     component config file;
#   - the wallet database roles: the service wallet-database-roles, the
#     order of the one-shot services and the database user of each wallet
#     config;
#   - the database server's DDL and connection logs, and that database-init
#     sets the passwords with psql \password (no password in a statement,
#     so the DDL log never shows one);
#   - Valkey: the services valkey, valkey-replica and valkey-sentinel (image,
#     start script, order, healthchecks with the user probe, tmpfs, password
#     files), the template settings in config/valkey/, the ACL users and
#     their rights, the passwords from make secrets, and the redis section
#     and password file of each wallet role and of the gateway
#     (tests/compose-valkey.sh runs the services against a real server);
#   - the worker and the clock: their commands, the health port of each
#     healthcheck, the worker state folder, and the clock's files (no NATS
#     seed, no OpenBao password);
#   - the installation limits (MAX_ORGANISATIONS,
#     MAX_ORGANISATION_WALLET_UNITS): the keys appear only with a value;
#   - the webhooks in the api files (no Webhooks.events);
#   - consent (CONSENT_ENABLED), off (the default) and on: the services of
#     the profile consent, the optional dependency of wallet-config, the
#     database igrant_consent, and the files: without consent, each file is
#     the file with consent less the consent parts, as in the Helm chart
#     (Installation.services, the gateway upstream, the trust of consent,
#     the consent reader of the wallet, the NATS user consent), and the
#     consent nkey of make secrets (with a stand-in for igrant-api). The
#     checks of the engine, the database roles and the webhooks run with
#     consent;
#   - the config files (make configs, render-configs.py): the templates of
#     compose.configs.yaml and the file configs in generated/ (one per
#     template, no content config), the same values files for the render
#     and the services, each service's hash label and its file, only
#     .env.example variables in the templates (no secrets), no secret value
#     in a file, and the renderer in a copy of this folder ($$,
#     ${VAR:+...}, #if and #unless, a missing value, file modes, a stale
#     file, --check, a second run);
#   - the security settings of EVERY service in all profiles (an unknown
#     service fails): read-only root file system, non-root user, no
#     capabilities, no new privileges, tmpfs and volumes for the writable
#     paths, no content config, no host namespace, no device, only bind
#     mounts from secrets/, no shell in the api image; the root one-shot
#     services (nats-data-owner) with only their capabilities and no
#     network;
#   - bash -n / sh -n of the scripts;
#   - nats-server -t of the NATS config, with and without consent (if
#     nats-server is installed);
#   - the text rules (no em or en dash, British English, no name of a
#     removed product or setting);
#   - the relative links of README.md (tests/check_links.py).
#
# Usage: tests/compose-files.sh
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../docker-compose"
# The openbao-init user (make sets it from your own user): fixed values,
# so the test gives the same result for everyone.
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

# project_json: the project's docker compose config (current environment)
# as JSON, with each generated/ file config filled in as "content" from the
# template render with the same environment (render-configs.py --print).
# So each case below checks the files that make configs writes for its
# values.
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

# consent_json <"" | true>: project_json with CONSENT_ENABLED, and the
# COMPOSE_PROFILES of .env (its derived line turns the profile consent on).
consent_json() {
  (unset COMPOSE_PROFILES; CONSENT_ENABLED="$1" project_json)
}

check_files() {
  local created_env="" created_generated="" render
  if [ ! -f .env ]; then
    cp .env.example .env
    created_env=1
  fi
  # The project needs generated/configs.env from make configs.
  [ -d generated ] || created_generated=1
  if render="$(python3 -I ./render-configs.py 2>&1)"; then
    ok "make configs: ${render#configs: }"
  else
    bad "make configs: $render"
    [ -z "$created_env" ] || rm -f .env
    finish ""
  fi
  local engine json services server images
  # With consent (CONSENT_ENABLED=true), so every configuration file is in
  # the project. Without consent, the files have less (the consent checks
  # below).
  for engine in postgresql; do
    if ! json="$(DB_ENGINE="$engine" CONSENT_ENABLED=true COMPOSE_PROFILES="$engine,consent" project_json 2>&1)"; then
      bad "$engine: docker compose config: $json"
      continue
    fi
    ok "$engine: docker compose config"
    services="$(DB_ENGINE="$engine" CONSENT_ENABLED=true COMPOSE_PROFILES="$engine,consent" docker compose config --services)"
    case "$engine" in postgresql) server=postgres ;; esac
    if grep -qx "$server" <<< "$services"; then
      ok "$engine: database server $server"
    else
      bad "$engine: no service $server"
    fi
    images="$(DB_ENGINE="$engine" CONSENT_ENABLED=true COMPOSE_PROFILES="$engine,consent" docker compose config --images)"
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
    if content is None or name == "nats-users":
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
      warn "$engine: configuration files not parsed (python3 with PyYAML is not installed)"
    fi
  done

  # Key stores in the wallet files: the local key store in OpenBao
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

  # Wallet database roles: wallet-database-roles (database-roles apply as
  # the admin user, one password file per login role) runs after
  # database-init, then wallet-migrate as the migrator, then the read access
  # (admin user) and the wallet processes (launcher and jobs roles). The
  # database user of each config has its password file from make secrets,
  # and no service of the wallet image mounts the password of the owner
  # user igrant_wallet. With consent, so wallet-read-access-consent is in
  # the project (the consent checks below: without it).
  if command -v python3 > /dev/null && python3 -c 'import yaml' 2> /dev/null; then
    local output project_file admin
    admin="$(sed -n 's/^DB_ADMIN_USER=//p' config/engine/postgresql.env)"
    if ! json="$(consent_json true 2>&1)"; then
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
# The login roles of database-roles, without the prefix igrant_wallet
# (the wallet database name).
roles = ["migrator", "launcher_app", "jobs", "clock", "audit_reader", "issuer_app", "relying_party_app",
         "business_wallet_app", "individual_wp_app", "business_wp_app", "admin_app"]
# Each service of the wallet image: its database user and the service it
# waits for.
wallet = {
    "wallet-database-roles": (admin, "database-init"),
    "wallet-migrate": ("igrant_wallet_migrator", "wallet-database-roles"),
    "wallet-read-access-api": (admin, "wallet-migrate"),
    "wallet-read-access-consent": (admin, "wallet-migrate"),
    "wallet-config": ("igrant_wallet_launcher_app", "wallet-migrate"),
    "wallet-service": ("igrant_wallet_launcher_app", "wallet-migrate"),
    "wallet-worker": ("igrant_wallet_jobs", "wallet-migrate"),
    "wallet-clock": ("igrant_wallet_clock", "wallet-migrate"),
}


def secret_file(name):
    """The make secrets file behind a secret name."""
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
print(f"wallet-database-roles ({len(roles)} login roles), the order, and the database user of each wallet config")
PY
)"; then
        ok "database roles: $output"
      else
        bad "database roles: $output"
      fi
      rm -f "$project_file"
    fi
  fi

  # Database server logs: log_statement=ddl, log_connections=on and
  # log_disconnections=on in the postgres command, each parameter once.
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
    sys.exit(f"the postgres log parameters are {logs}, not {expected}")
print("postgres logs DDL statements, connections and disconnections")
PY
)"; then
        ok "database logs: $output"
      else
        bad "database logs: $output"
      fi
      rm -f "$project_file"
    fi
  fi
  # psql \password sends a SCRAM-SHA-256 verifier, never the password, so
  # no database-init statement holds a password.
  if grep -q -F '\password' config/database/create-databases.sh && ! grep -q -w 'PASSWORD' config/database/create-databases.sh; then
    ok "database-init sets the passwords with psql \\password"
  else
    bad "database-init sends a password in a statement, not with psql \\password"
  fi

  # The built-in test CA (TEST_CA_ENABLED, TEST_CA_LEAF_VALIDITY_DAYS):
  # kms.test_ca in the wallet files. Empty values give the defaults.
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

  # The gateway feature gate (FEATURES_ENFORCE): Features.enforce only in
  # the gateway file (the api refuses the section). An empty value gives the
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

  # Installation limits (MAX_ORGANISATIONS, MAX_ORGANISATION_WALLET_UNITS):
  # Limits.maxOrganisations in the api and webhook files and
  # wallet_unit.organisation_wallet_units_max in the config, service and
  # worker files, as integers, only when the setting has a value. No other
  # file has them: not the gateway file (the gateway refuses the section)
  # and not the clock file.
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

  # Webhooks and installation services: the Webhooks section of the api and
  # webhook files has only DeliveryRetentionDays (each organisation's
  # effective features select the event types), and with consent no file
  # has Installation (all services; without consent: the consent checks).
  if command -v python3 > /dev/null && python3 -c 'import yaml' 2> /dev/null; then
    if ! json="$(consent_json true 2>&1)"; then
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

  # Consent (CONSENT_ENABLED; README.md, "Consent"), off (the default) and
  # on, with the derived COMPOSE_PROFILES of .env:
  #   - the five consent services run only with consent (the profile
  #     consent); of the other services, only wallet-config waits for one
  #     (consent-read-access), as an optional dependency;
  #   - database-init gets CONSENT_ENABLED and makes igrant_consent only
  #     with it;
  #   - the files: no #if, #unless or #end line is left. With consent, no
  #     file has Installation, and the NATS users are config/nats/users.conf.
  #     Without consent, each file is the file with consent less the consent
  #     parts, as in the Helm chart: Installation.services [wallet] in the
  #     api, webhook and gateway files, no trust of igrant-consent-management
  #     in the api files, no gateway upstream consent, no
  #     read_access.consent in wallet-config, no NATS user consent;
  #   - make secrets writes the public nkey of consent only with consent
  #     (NATS refuses an nkey that no user uses), and the other consent
  #     files also without consent;
  #   - CONSENT_ENABLED=false stops make configs and make secrets (any
  #     value turns the profile on).
  if command -v python3 > /dev/null && python3 -c 'import yaml' 2> /dev/null; then
    local off_file on_file output databases
    off_file="$(mktemp)"
    on_file="$(mktemp)"
    if ! consent_json "" > "$off_file" 2>&1; then
      bad "consent: docker compose config without consent: $(cat "$off_file")"
    elif ! consent_json true > "$on_file" 2>&1; then
      bad "consent: docker compose config with consent: $(cat "$on_file")"
    elif output="$(python3 - "$off_file" "$on_file" 2>&1 <<'PY'
import copy
import json
import re
import sys

import yaml

off = json.load(open(sys.argv[1], encoding="utf-8"))
on = json.load(open(sys.argv[2], encoding="utf-8"))
problems = []
CONSENT = {"consent", "consent-migrate", "consent-read-access", "api-read-access-consent", "wallet-read-access-consent"}
for case, project in (("without consent", off), ("with consent", on)):
    services = project["services"]
    want = CONSENT if project is on else set()
    if CONSENT & set(services) != want:
        problems.append(f"{case}: the consent services {sorted(CONSENT & set(services))}, not {sorted(want)}")
    for name in CONSENT & set(services):
        if services[name].get("profiles") != ["consent"]:
            problems.append(f"{name}: profiles {services[name].get('profiles')}, not [consent]")
    dependency = (services["wallet-config"].get("depends_on") or {}).get("consent-read-access")
    if dependency != {"condition": "service_completed_successfully", "required": False}:
        problems.append(f"{case}: wallet-config waits for consent-read-access with {dependency}")
    value = (services["database-init"].get("environment") or {}).get("CONSENT_ENABLED")
    if value != ("true" if project is on else ""):
        problems.append(f"{case}: database-init has CONSENT_ENABLED {value!r}")
for name, service in on["services"].items():
    for dependency in service.get("depends_on") or {}:
        if dependency in CONSENT and name not in CONSENT and name != "wallet-config":
            problems.append(f"{name} waits for the consent service {dependency}")


def files(project):
    return {name: config["content"] for name, config in project["configs"].items() if "content" in config}


off_files, on_files = files(off), files(on)
for case, contents in (("without consent", off_files), ("with consent", on_files)):
    for name, text in contents.items():
        if re.search(r"^[ \t]*#(if|unless|end)\b", text, re.M):
            problems.append(f"{case}: {name} has an #if, #unless or #end line")
# The NATS users.
users = open("config/nats/users.conf", encoding="utf-8").read()
if on_files.get("nats-users") != users:
    problems.append("with consent: the NATS users are not config/nats/users.conf")
lines = users.splitlines(keepends=True)
start = [i for i, line in enumerate(lines) if line.strip() == "# consent"]
if len(start) != 1:
    problems.append("config/nats/users.conf has no user consent")
elif off_files.get("nats-users") != "".join(lines[:start[0]] + lines[start[0] + 2:]):
    problems.append("without consent: the NATS users are not config/nats/users.conf less the user consent")


def issuers(document):
    return [entry["issuer"] for entry in document["ServiceEnvelope"]["trustedIssuers"]]


# Each file without consent: the file with consent less the consent parts.
installation = {"services": ["wallet"]}
for name in sorted(set(on_files) - {"nats-users"}):
    loads = json.loads if name == "dashboard-config" else yaml.safe_load
    with_consent = loads(on_files[name])
    if isinstance(with_consent, dict) and "Installation" in with_consent:
        problems.append(f"with consent: {name} has Installation")
    if name not in off_files:
        if name not in ("consent-config", "consent-migrate-config"):
            problems.append(f"without consent: no file {name}")
        continue
    expected = copy.deepcopy(with_consent)
    if name in ("api-config", "webhook-config"):
        if "igrant-consent-management" not in issuers(with_consent):
            problems.append(f"with consent: {name} does not trust igrant-consent-management")
        expected["ServiceEnvelope"]["trustedIssuers"] = [
            entry for entry in expected["ServiceEnvelope"]["trustedIssuers"] if entry["issuer"] != "igrant-consent-management"]
        expected["Installation"] = installation
    elif name == "gateway-config":
        if with_consent["Gateway"]["upstreams"].get("consent") != {"url": "http://consent:80", "requestTimeoutSeconds": 30}:
            problems.append("with consent: the gateway has no upstream consent")
        expected["Gateway"]["upstreams"].pop("consent", None)
        expected["Installation"] = installation
    elif name == "wallet-config-config":
        if "consent" not in with_consent.get("read_access", {}):
            problems.append("with consent: wallet-config has no read_access.consent")
        expected["read_access"].pop("consent", None)
    if loads(off_files[name]) != expected:
        problems.append(f"without consent: {name} is not the file with consent less the consent parts")
if problems:
    print("; ".join(problems))
    sys.exit(1)
print(f"the consent services, the files ({len(off_files)} without, {len(on_files)} with consent) and the NATS users")
PY
)"; then
      ok "consent: $output"
    else
      bad "consent: $output"
    fi
    rm -f "$off_file" "$on_file"
    # The derived line of .env.example, and the databases of database-init.
    if grep -qx 'COMPOSE_PROFILES=${DB_ENGINE}${CONSENT_ENABLED:+,consent}' .env.example; then
      ok "consent: the derived COMPOSE_PROFILES of .env.example"
    else
      bad "consent: .env.example does not derive COMPOSE_PROFILES from CONSENT_ENABLED"
    fi
    databases="$(sed -n 's/^DATABASES=//p' config/database/create-databases.sh)"
    if [ "$(CONSENT_ENABLED='' bash -c "DATABASES=${databases}; echo \$DATABASES")" = "igrant_api igrant_oidc igrant_wallet" ] \
      && [ "$(CONSENT_ENABLED=true bash -c "DATABASES=${databases}; echo \$DATABASES")" = "igrant_api igrant_oidc igrant_consent igrant_wallet" ]; then
      ok "consent: database-init makes igrant_consent only with consent"
    else
      bad "consent: the databases of database-init do not follow CONSENT_ENABLED"
    fi
    if output="$(CONSENT_ENABLED=false python3 -I ./render-configs.py --print 2>&1)" || ! grep -q 'CONSENT_ENABLED must be empty or true' <<< "$output"; then
      bad "consent: CONSENT_ENABLED=false does not stop make configs: ${output:0:200}"
    else
      ok "consent: CONSENT_ENABLED=false stops make configs"
    fi
    # make secrets (secrets.sh) in a copy of this folder, with a stand-in
    # for igrant-api (no real key): the public nkey of consent only with
    # consent (NATS refuses an nkey that no user uses), and the consent
    # files also without consent.
    local copy fake nkeys_off nkeys_on
    copy="$(mktemp -d)"
    tar -c --exclude ./secrets --exclude ./generated . | tar -x -C "$copy"
    fake="$copy/igrant-api-stand-in"
    cat > "$fake" <<'FAKE'
#!/bin/sh
# Stand-in for "igrant-api keys": writes placeholder files, no key.
[ "$1" = keys ] || exit 1
command="$2"
shift 2
out=""
while [ $# -gt 0 ]; do
  case "$1" in
    --file) [ "$command" = export-token-jwks ] || out="$2"; shift 2 ;;
    --out) out="$2"; shift 2 ;;
    *) shift ;;
  esac
done
if [ "$command" = generate-nats-seed ]; then
  printf 'SUTEST\n' > "$out"
  printf 'U%s\n' AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
else
  printf '{"keys": []}\n' > "$out"
fi
FAKE
    chmod 755 "$fake"
    if ! output="$(cd "$copy" && CONSENT_ENABLED='' SMTP_USERNAME='' IGRANT_API_BIN="$fake" ./secrets.sh 2>&1)"; then
      bad "consent: make secrets without consent: ${output:0:300}"
    else
      nkeys_off="$(grep -c '^NATS_NKEY_' "$copy/secrets/public/nats-nkeys.conf" || true)"
      if grep -q '^NATS_NKEY_CONSENT:' "$copy/secrets/public/nats-nkeys.conf" || [ ! -s "$copy/secrets/consent/nats-consent.nk" ] \
        || [ ! -s "$copy/secrets/database/igrant_consent-password" ]; then
        bad "consent: make secrets without consent: the consent nkey is in nats-nkeys.conf, or a consent file is missing"
      elif ! output="$(cd "$copy" && CONSENT_ENABLED=true SMTP_USERNAME='' IGRANT_API_BIN="$fake" ./secrets.sh 2>&1)"; then
        bad "consent: make secrets with consent: ${output:0:300}"
      else
        nkeys_on="$(grep -c '^NATS_NKEY_' "$copy/secrets/public/nats-nkeys.conf" || true)"
        if grep -q '^NATS_NKEY_CONSENT:' "$copy/secrets/public/nats-nkeys.conf" && [ "$nkeys_on" -eq $((nkeys_off + 1)) ]; then
          ok "consent: make secrets writes the consent nkey only with consent ($nkeys_off and $nkeys_on nkeys)"
        else
          bad "consent: make secrets with consent: no consent nkey in nats-nkeys.conf"
        fi
      fi
    fi
    if output="$(cd "$copy" && CONSENT_ENABLED=false SMTP_USERNAME='' IGRANT_API_BIN="$fake" ./secrets.sh 2>&1)" \
      || ! grep -q 'CONSENT_ENABLED must be empty' <<< "$output"; then
      bad "consent: CONSENT_ENABLED=false does not stop make secrets"
    else
      ok "consent: CONSENT_ENABLED=false stops make secrets"
    fi
    rm -rf "$copy"
  fi

  # The Makefile's platform operator targets (make -n: no container): the
  # api commands, the first platform admin's password on standard input
  # (--password-file -, never an argument), and the API core's right to
  # publish organisation deletion.
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
  if dry="$(make -n platform-grant-admin ADMIN_EMAIL=admin@example.com 2>&1)" \
    && grep -q -F 'platform grant-admin --email "admin@example.com"' <<< "$dry" \
    && dry="$(make -n platform-status 2>&1)" && grep -q -F 'platform status' <<< "$dry"; then
    ok "make platform-grant-admin and platform-status"
  else
    bad "the platform operator targets: $dry"
  fi
  if make platform-operator > /dev/null 2>&1 || make platform-grant-admin > /dev/null 2>&1; then
    bad "a platform operator target runs without its values"
  else
    ok "the platform operator targets stop without their values"
  fi
  if grep -q -F '"api.v1.evt.organisation.deleted"' config/nats/users.conf; then
    ok "the api NATS user publishes api.v1.evt.organisation.deleted"
  else
    bad "config/nats/users.conf: the api cannot publish api.v1.evt.organisation.deleted (make nats-config)"
  fi

  # Audit log (AUDIT_RETENTION_YEARS): the same retention in the wallet role
  # files and in wallet-migrate (the partition step), and no audit bucket.
  # An empty value gives the default.
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

  # Valkey: the three services, the templates in config/valkey/, the ACL
  # users from make secrets and the redis section of each wallet role.
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
        problems.append(f"{name}: image {service.get('image')!r}, not VALKEY_IMAGE from .env.example")
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
            problems.append(f"{name}: no password file for {user}")
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
        problems.append(f"valkey.conf does not have {setting!r}")
acl = open("config/valkey/users.acl", encoding="utf-8").read().splitlines()
expected_acl = ["user default off"] + [f"user {u} on {{hash:{u}}} {wallet_rights}" for u in users if u.startswith("wallet-")] + [f"user gateway on {{hash:gateway}} {gateway_rights}"]
for line in expected_acl:
    if line not in acl:
        problems.append(f"users.acl does not have {line!r}")
if sorted(re.findall(r"^user (\S+)", "\n".join(acl), re.M)) != sorted(["default"] + users):
    problems.append("users.acl has users other than default and the make secrets users")
sentinel = open("config/valkey/sentinel.conf", encoding="utf-8").read().splitlines()
for setting in ("sentinel monitor ows {primary} 6379 1", "sentinel resolve-hostnames yes", "sentinel announce-hostnames yes",
                "sentinel auth-user ows sentinel", "user default off"):
    if setting not in sentinel:
        problems.append(f"sentinel.conf does not have {setting!r}")
made = re.search(r"for name in ([a-z -]+); do\n  password \"valkey/", open("secrets.sh", encoding="utf-8").read())
if not made or sorted(made.group(1).split()) != sorted(users):
    problems.append("make secrets does not create a password for each Valkey user")
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
    problems.append("the gateway does not mount its Valkey user's password")
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

  # Worker and clock: the command of each (the worker with all queues), the
  # healthcheck's health port, the worker state folder, the worker and clock
  # sections, and the clock's files (only the passwords of its database
  # role and Valkey user: no NATS seed, no OpenBao password).
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
        problems.append(f"{name}: the healthcheck is not /readyz on port {port}")
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
    problems.append("the scheduler is still a service (the wallet no longer has one)")
targets = sorted(s["target"] for s in clock.get("secrets", []))
if targets != ["/run/secrets/eudi-wallet/database-password", "/run/secrets/eudi-wallet/redis-password"]:
    problems.append(f"wallet-clock mounts {targets}")
if "nats" in (clock.get("depends_on") or {}) or "openbao-init" in (clock.get("depends_on") or {}):
    problems.append("wallet-clock waits for NATS or OpenBao")
if problems:
    print("; ".join(problems))
    sys.exit(1)
print("the commands, the health ports, the state folder and the clock's files")
PY
)"; then
        ok "worker and clock: $output"
      else
        bad "worker and clock: $output"
      fi
      rm -f "$project_file"
    fi
  fi

  # Config files (README.md, "Configuration files"): the templates of
  # compose.configs.yaml, each listed in the service render; one generated/
  # file config per template and no content config in the project; the
  # same values files for the render as for the services (plus
  # generated/configs.env for the services only); the label of each
  # service that reads a generated/ file is the file's SHA-256; the
  # templates use only the variables of .env.example and config/engine/
  # (settings, no secrets), and each key with a password, a secret or a
  # seed names a file.
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
# One generated/ file config per template, and nats-users.conf (the NATS
# users, not a template); no content config.
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
if sorted(generated.values()) != sorted(list(templates) + ["nats-users.conf"]):
    problems.append(f"the generated/ file configs {sorted(generated.values())} are not the templates {sorted(templates)} and nats-users.conf")
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
            problems.append(f"{service_name}: the label {label} has no config")
# Template variables: settings only.
settings = set()
for path in (".env.example", "config/engine/postgresql.env"):
    settings |= set(re.findall(r"^([A-Z][A-Z0-9_]*)=", open(path, encoding="utf-8").read(), re.M))
unknown = sorted(set(variables) - settings)
if unknown:
    problems.append(f"the templates use {unknown}, which are not settings in .env.example or config/engine/")
# In each generated/ file, each key with a password, a secret or a seed
# names a file (an absolute path).
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
print(f"{len(templates)} templates, {len(generated)} generated/ file configs, {labelled} hash labels, "
      f"{len(variables)} setting variables, no secret value")
PY
)"; then
      ok "configuration files: $output"
    else
      bad "configuration files: $output"
    fi
    rm -f "$project_file" "$variables_file"
  fi

  # The renderer (render-configs.py) in a copy of this folder, with one
  # extra template: $$ gives $, and ${VAR:+...} and a value with a shell $
  # follow the Compose rules; #if and #unless keep their lines for a value
  # and for no value; modes 0644 (files) and 0755 (folder); a file that is
  # not a template (a stale file, a temporary file of a stopped run) is
  # removed; --check passes, and fails after a value changes; a second run
  # writes the same bytes; a missing required value and an #if without
  # #end stop the run before it writes a file.
  if command -v python3 > /dev/null; then
    local copy output
    copy="$(mktemp -d)"
    tar -c --exclude ./secrets --exclude ./generated . | tar -x -C "$copy"
    if output="$(cd "$copy" && python3 - 2>&1 <<'PY'
import hashlib, json, os, stat, subprocess, sys
problems = []
text = open("compose.configs.yaml", encoding="utf-8").read()
text = text.replace("    configs:\n      - ", "    configs:\n      - zz-test.yaml\n      - ", 1)
text += ("  zz-test.yaml:\n    content: |\n      dollar: $$HOME\n      ${RENDER_TEST:+test: ${RENDER_TEST}}\n"
         "      #if ${RENDER_TEST:-}\n      if: kept\n      #end\n      #unless ${RENDER_TEST:-}\n      unless: kept\n      #end\n"
         "      tag: ${PLATFORM_TAG}\n")
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
want = f"dollar: $HOME\ntest: a$b\nif: kept\ntag: {tag}\n".encode()
got = open("generated/zz-test.yaml", "rb").read()
if got != want:
    problems.append(f"zz-test.yaml is {got!r}, not {want!r}")
if stat.S_IMODE(os.stat("generated/zz-test.yaml").st_mode) != 0o644 or stat.S_IMODE(os.stat("generated").st_mode) != 0o755:
    problems.append("the modes are not 0644 (files) and 0755 (folder)")
if os.path.exists("generated/stale.yaml") or os.path.exists("generated/.render-left"):
    problems.append("a file that is not a template is not removed")
if f"CONFIG_SHA256_ZZ_TEST={hashlib.sha256(want).hexdigest()}" not in open("generated/configs.env").read():
    problems.append("configs.env does not have the SHA-256 of zz-test.yaml")
snapshot = {name: open(os.path.join("generated", name), "rb").read() for name in os.listdir("generated")}
if run("--check").returncode != 0:
    problems.append("--check fails after the render")
changed = run("--check", extra={"RENDER_TEST": "other"})
if changed.returncode == 0 or "zz-test.yaml" not in changed.stdout or "configs.env" not in changed.stdout:
    problems.append(f"--check passes after a value changes: {changed.stdout.strip()}")
if run().returncode != 0 or {name: open(os.path.join("generated", name), "rb").read() for name in os.listdir("generated")} != snapshot:
    problems.append("a second run writes other bytes")
empty = run("--print", extra={"RENDER_TEST": ""})
if empty.returncode != 0 or json.loads(empty.stdout).get("zz-test.yaml") != f"dollar: $HOME\n\nunless: kept\ntag: {tag}\n":
    problems.append(f"#if and #unless without a value: {empty.stdout.strip()[:200]}")
text = open("compose.configs.yaml", encoding="utf-8").read()
open("compose.configs.yaml", "w", encoding="utf-8").write(text + "      required: ${RENDER_MISSING:?RENDER_MISSING is required}\n")
missing = run(extra={"RENDER_TEST": "new"})
if missing.returncode == 0 or "RENDER_MISSING is required" not in missing.stdout:
    problems.append(f"a missing required value does not stop the render: {missing.stdout.strip()}")
if {name: open(os.path.join("generated", name), "rb").read() for name in os.listdir("generated")} != snapshot:
    problems.append("a stopped render changed a file")
open("compose.configs.yaml", "w", encoding="utf-8").write(text + "      #if ${RENDER_TEST:-}\n")
unclosed = run(extra={"RENDER_TEST": "new"})
if unclosed.returncode == 0 or "without #end" not in unclosed.stdout:
    problems.append(f"an #if without #end does not stop the render: {unclosed.stdout.strip()}")
if {name: open(os.path.join("generated", name), "rb").read() for name in os.listdir("generated")} != snapshot:
    problems.append("a stopped render changed a file")
if problems:
    print("; ".join(problems))
    sys.exit(1)
print("$$, ${VAR:+...} and a value with $, #if and #unless, the modes, the removal of a stale file, --check, a second run, a missing value and an #if without #end")
PY
)"; then
      ok "make configs: $output"
    else
      bad "make configs: $output"
    fi
    rm -rf "$copy"
  fi

  # Security settings of EVERY service (README.md, "Security settings"),
  # with all profiles: read-only root file system, no capabilities, no new
  # privileges, its user (UID:GID, not root), tmpfs (each with a size) and
  # volumes for the paths it writes, no "content" config, no host namespace,
  # no device, no privileged mode, and only bind mounts from secrets/
  # (read-only, except the openbao-init state folder). A service that this
  # list does not know fails: add it with its user and writable paths.
  # Ports below 1024 need the sysctl net.ipv4.ip_unprivileged_port_start.
  # The api image has no shell, so no api service starts one. The root
  # one-shot services (nats-data-owner) have only their capabilities and no
  # network.
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
# Each service: its user, and the tmpfs and volume paths it writes.
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
    "wallet-read-access-api": (WALLET, ["/tmp"], []),
    "wallet-read-access-consent": (WALLET, ["/tmp"], []),
    "wallet-config": (WALLET, ["/tmp"], []),
    "wallet-service": (WALLET, ["/tmp"], []),
    "wallet-worker": (WALLET, ["/run/ows-worker"], ["/tmp"]),
    "wallet-clock": (WALLET, ["/tmp"], []),
    "dashboard": ("101:101", ["/tmp"], []),
}
# The root one-shot services: the capabilities, volume paths and command
# of each.
NATS_OWNER = ["find", "/data", "(", "!", "-user", "65532", "-o", "!", "-group", "65532", ")",
              "-exec", "chown", "-h", "65532:65532", "{}", "+"]
root_one_shots = {
    "nats-data-owner": (["CHOWN", "DAC_READ_SEARCH"], ["/data"], NATS_OWNER),
}
# Bind mounts that a service may write (all others are read-only): the
# openbao-init state folder (init.json).
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
        problems.append(f"{name}: content configs {content} (Compose cannot write them into a read-only container)")
    for entry in service.get("tmpfs") or []:
        if "size=" not in entry:
            problems.append(f"{name}: the tmpfs {entry} has no size")
    for volume in service.get("volumes") or []:
        if volume.get("type") == "bind":
            source = volume.get("source", "")
            if not source.startswith(f"{folder}/secrets/"):
                problems.append(f"{name}: a bind mount of {source} (only folders in secrets/ are allowed)")
            if not volume.get("read_only") and (name, source) not in writable_binds:
                problems.append(f"{name}: the bind mount of {source} is not read-only")
        elif volume.get("type") != "volume":
            problems.append(f"{name}: a volume of type {volume.get('type')}")
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
    cp config/nats/nats.conf "$dir/"
    sed -i.orig "s#store_dir: \"/data\"#store_dir: \"${dir}/data\"#" "$dir/nats.conf"
    # Stand-in public nkeys (no secrets) with the make secrets names.
    cat > "$dir/nkeys.conf" <<'NKEYS'
NATS_NKEY_API: "UCEKSPNUPXXRDG7XXDV7QP6OVL65PNZOQE3BC6D2DYMS6VSRZG6KATFL"
NATS_NKEY_API_WEBHOOK: "UDLNQ4V73THWJRSWY47PSTWVPH2G4AME5ZJ2BD743BNHOLIRQIK46KHY"
NATS_NKEY_CONSENT: "UB7OGI7MLCXOD6X65KXC22DH3QBKBJOOXNM5ASKTGOT6TGRLN7H2DRV3"
NATS_NKEY_WALLET_CONFIG: "UCUBGBWEFKGAAPHRHLNTDDL53F7QVKXLIXWDMA5EYCEFGEZ7TERRRJTD"
NATS_NKEY_WALLET_SERVICE: "UC3VBAJ2Y63SP755G2QEVR6HVKGIPTLNSJT74N53PLM6UQN466BGAB2K"
NATS_NKEY_WALLET_WORKER: "UAGXS2RAA3KKGT722PQLZPXUOGC2GM7UEOFHE4RVSFPEHPDKA3IDT7VY"
NKEYS
    # The users of make configs (generated/nats-users.conf), without and
    # with consent. make secrets writes the consent nkey only with consent.
    local output consent
    cp "$dir/nkeys.conf" "$dir/nkeys-with-consent.conf"
    for consent in "" true; do
      if [ -n "$consent" ]; then
        cp "$dir/nkeys-with-consent.conf" "$dir/nkeys.conf"
      else
        grep -v '^NATS_NKEY_CONSENT:' "$dir/nkeys-with-consent.conf" > "$dir/nkeys.conf"
      fi
      if ! CONSENT_ENABLED="$consent" python3 -I ./render-configs.py --print \
          | python3 -c 'import json, sys; sys.stdout.write(json.load(sys.stdin)["nats-users.conf"])' > "$dir/users.conf"; then
        bad "nats-server -t${consent:+ with consent}: no NATS users from make configs"
      elif output="$(nats-server -t -c "$dir/nats.conf" 2>&1)"; then
        ok "nats-server -t config/nats/nats.conf${consent:+ with consent}"
      else
        bad "nats-server -t${consent:+ with consent}: $output"
      fi
    done
    rm -rf "$dir"
  else
    warn "NATS configuration not checked (nats-server is not installed)"
  fi

  # Text rules for this folder (not the generated files): no em or en dash,
  # British English, no removed products or settings, and no backup or
  # upgrade text. Exception (a key that the code reads): the wallet key
  # "vault", with its OpenBao comment.
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
  # The relative links of README.md (also into the chart docs): each target
  # file and each anchor heading exists.
  if hits="$(python3 ../tests/check_links.py README.md 2>&1)"; then ok "relative links of README.md"; else bad "relative links of README.md: $hits"; fi

  [ -z "$created_env" ] || rm -f .env
  [ -z "$created_generated" ] || rm -rf generated
  finish "all checks passed (${warnings} warning(s))"
}

check_files
