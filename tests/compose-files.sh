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

check_files() {
  local created_env=""
  if [ ! -f .env ]; then
    cp .env.example .env
    created_env=1
  fi
  local engine json services server images
  for engine in postgresql; do
    if ! json="$(DB_ENGINE="$engine" COMPOSE_PROFILES="$engine" docker compose config --format json 2>&1)"; then
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
    if ! json="$(docker compose config --format json 2>&1)"; then
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
for role in ("config", "service", "scheduler"):
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
    if ! json="$(docker compose config --format json 2>&1)"; then
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
roles = ["migrator", "launcher_app", "jobs", "audit_reader", "issuer_app", "relying_party_app",
         "business_wallet_app", "individual_wp_app", "business_wp_app", "admin_app"]
# Each service of the wallet image: its database user and the service that
# it waits for.
wallet = {
    "wallet-database-roles": (admin, "database-init"),
    "wallet-migrate": ("igrant_wallet_migrator", "wallet-database-roles"),
    "wallet-read-access": (admin, "wallet-migrate"),
    "wallet-config": ("igrant_wallet_launcher_app", "wallet-migrate"),
    "wallet-service": ("igrant_wallet_launcher_app", "wallet-migrate"),
    "wallet-scheduler": ("igrant_wallet_jobs", "wallet-migrate"),
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
    if ! json="$(docker compose config --format json 2>&1)"; then
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
      if ! json="$(TEST_CA_ENABLED="$enabled" TEST_CA_LEAF_VALIDITY_DAYS="$days" docker compose config --format json 2>&1)"; then
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
for role in ("config", "service", "scheduler"):
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

  # The audit log (AUDIT_RETENTION_YEARS): the same retention in the files of
  # the wallet roles and of wallet-migrate (the partition step), and no audit
  # bucket. Empty value: the default.
  if command -v python3 > /dev/null && python3 -c 'import yaml' 2> /dev/null; then
    local years
    for years in "" 10; do
      if ! json="$(AUDIT_RETENTION_YEARS="$years" docker compose config --format json 2>&1)"; then
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
for name in ("config", "service", "scheduler", "migrate"):
    audit = yaml.safe_load(project["configs"][f"wallet-{name}-config"]["content"]).get("audit")
    if audit != expected:
        sys.exit(f"wallet-{name}: audit {audit!r}, not {expected!r}")
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

  local script
  for script in secrets.sh check.sh config/database/create-databases.sh; do
    if bash -n "$script"; then ok "bash -n $script"; else bad "bash -n $script"; fi
  done
  if sh -n config/openbao/bootstrap.sh; then ok "sh -n config/openbao/bootstrap.sh"; else bad "sh -n config/openbao/bootstrap.sh"; fi

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
NATS_NKEY_WALLET_SCHEDULER: "UDHIVILUSG2WUL3E4IBGURECA4QSRCENVF6WQYYK5LIDDJ7ENFXRFB7Z"
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
  text_files="$(find . -type f ! -path './secrets/*' ! -name .env ! -name '*.orig' | sort)"
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
    | grep -v -E '^\./compose\.platform\.yaml:[0-9]+:( +vault:$| +# .*"vault" is| +organisation_key_store_types: \[vault, csc, gcp-kms, aws-kms, azure-key-vault\]$)' || true)"
  if [ -n "$hits" ]; then bad "removed product or setting: $hits"; else ok "no removed product or setting"; fi
  # The relative links of README.md (also into the docs of the chart): each
  # target file and each heading of an anchor exists.
  if hits="$(python3 ../tests/check_links.py README.md 2>&1)"; then ok "relative links of README.md"; else bad "relative links of README.md: $hits"; fi

  [ -z "$created_env" ] || rm -f .env
  finish "all checks passed (${warnings} warning(s))"
}

check_files
