#!/bin/bash
# The database-init service: creates one database and one owner user per
# component on the DB_ENGINE server (postgresql). The user name is the
# database name. Idempotent: it creates a user or a database only when it is
# missing, and sets every user's password on each run. The wallet's data
# scopes are schemas in igrant_wallet, which the wallet-database-roles
# service creates together with the wallet's database roles. No wallet
# process logs in as the owner user igrant_wallet.
#
# Environment: DB_ENGINE, DB_PORT, DB_ADMIN_USER (config/engine/*.env), and
# CONSENT_ENABLED (.env): the database igrant_consent only when it is not
# empty. Without consent, an existing igrant_consent stays as it is.
# Secret files in /run/secrets/database/: admin-password (the admin user)
# and <database>-password for each database. No password goes on a command
# line or into a statement: psql \password sends the SCRAM-SHA-256
# verifier, so the server's DDL log never shows the password.
set -euo pipefail

DATABASES="igrant_api igrant_oidc ${CONSENT_ENABLED:+igrant_consent }igrant_wallet"
SECRETS=/run/secrets/database
HOST=database

# The content of a secret file, without trailing line breaks.
secret() {
  local value
  value="$(< "${SECRETS}/$1")"
  printf '%s' "${value%%[$'\r\n']*}"
}

wait_for() {
  for attempt in $(seq 1 60); do
    if "$@" > /dev/null 2>&1; then
      return 0
    fi
    if [ "$attempt" -eq 60 ]; then
      echo "the database server at ${HOST}:${DB_PORT} is not ready after 300 seconds" >&2
      exit 1
    fi
    sleep 5
  done
}

# Sets the password of the user $1 with psql \password. psql reads the
# password twice from stdin (the service has no terminal), and printf is a
# shell builtin, so no process gets the password as an argument. The output
# (the two prompts) is shown only on an error.
set_password() {
  local role="$1" password output
  password="$(secret "${role}-password")"
  if ! output="$(printf '%s\n%s\n' "$password" "$password" \
      | psql -v ON_ERROR_STOP=1 -v role="$role" -c '\password :"role"' 2>&1)"; then
    printf '%s\n' "$output" >&2
    echo "the password of the user ${role} is not set" >&2
    exit 1
  fi
}

postgresql() {
  export PGHOST="$HOST" PGPORT="$DB_PORT" PGUSER="$DB_ADMIN_USER" PGDATABASE=postgres
  PGPASSWORD="$(secret admin-password)"
  export PGPASSWORD
  wait_for pg_isready
  for database in $DATABASES; do
    echo "Configuring the user and the database ${database}"
    psql -v ON_ERROR_STOP=1 -q -v role="$database" <<'SQL'
SELECT format('CREATE ROLE %I LOGIN', :'role')
  WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = :'role') \gexec
ALTER ROLE :"role" WITH LOGIN;
SELECT format('CREATE DATABASE %I OWNER %I TEMPLATE template0 ENCODING %L LC_COLLATE %L LC_CTYPE %L',
              :'role', :'role', 'UTF8', 'C', 'C.UTF-8')
  WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = :'role') \gexec
REVOKE ALL ON DATABASE :"role" FROM PUBLIC;
SQL
    set_password "$database"
  done
}

case "${DB_ENGINE:-}" in
  postgresql) postgresql ;;
  *)
    echo "DB_ENGINE must be postgresql, not '${DB_ENGINE:-}'" >&2
    exit 1
    ;;
esac
echo "All databases are configured"
