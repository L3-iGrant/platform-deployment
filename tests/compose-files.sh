#!/usr/bin/env bash
# Tests of the files of docker-compose/ for the maintainers. No container
# starts and no image is pulled: "docker compose config" needs no Docker
# daemon. Checks:
#   - docker compose config for both engines (postgresql, mysql): the
#     database server of the engine only, the images, and the database type
#     and port in each configuration file of the components;
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
  local engine json services own other images
  for engine in postgresql mysql; do
    if ! json="$(DB_ENGINE="$engine" COMPOSE_PROFILES="$engine" docker compose config --format json 2>&1)"; then
      bad "$engine: docker compose config: $json"
      continue
    fi
    ok "$engine: docker compose config"
    services="$(DB_ENGINE="$engine" COMPOSE_PROFILES="$engine" docker compose config --services)"
    own=$([ "$engine" = mysql ] && echo mariadb || echo postgres)
    other=$([ "$engine" = mysql ] && echo postgres || echo mariadb)
    if grep -qx "$own" <<< "$services" && ! grep -qx "$other" <<< "$services"; then
      ok "$engine: database server $own only"
    else
      bad "$engine: the services must have $own and not $other"
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
port = {"postgresql": 5432, "mysql": 3306}[engine]
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
  # the wallet key "vault" (with its OpenBao comment) and the MariaDB
  # setting MARIADB_AUTO_UPGRADE.
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
  hits="$(grep -n -i -E 'hashicorp|vault|kms_key|platform: *database|db-backed|data_key|facade|keycloak|mongo|aries|aca-py|cloud ?agent|\bssi\b|backup|upgrade|migration step|mailpit|rotator' $text_files \
    | grep -v -E '^\./compose\.platform\.yaml:[0-9]+:( +vault:$| +# .*"vault" is| +MARIADB_AUTO_UPGRADE: "1"$| +organisation_key_store_types: \[vault, csc, gcp-kms, aws-kms, azure-key-vault\]$)' || true)"
  if [ -n "$hits" ]; then bad "removed product or setting: $hits"; else ok "no removed product or setting"; fi
  # The relative links of README.md (also into the docs of the chart): each
  # target file and each heading of an anchor exists.
  if hits="$(python3 ../tests/check_links.py README.md 2>&1)"; then ok "relative links of README.md"; else bad "relative links of README.md: $hits"; fi

  [ -z "$created_env" ] || rm -f .env
  finish "all checks passed (${warnings} warning(s))"
}

check_files
