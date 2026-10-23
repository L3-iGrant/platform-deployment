#!/bin/bash
# The service database-init: makes one database and one owner user for each
# component on the database server of DB_ENGINE (postgresql, or mysql: the
# MariaDB server). The
# user name is the database name. The script is idempotent: it makes a user
# or a database only when it does not exist, and it sets the password of
# each user each time.
#
# Environment: DB_ENGINE, DB_PORT, DB_ADMIN_USER (config/engine/*.env).
# Secret files in /run/secrets/database/: admin-password (the admin user)
# and <database>-password for each database. No password goes on a command
# line.
set -euo pipefail

DATABASES="igrant_api igrant_oidc igrant_consent igrant_wallet"
SECRETS=/run/secrets/database
HOST=database

# The text of a secret file without its trailing line breaks.
secret() {
  local value
  value="$(< "${SECRETS}/$1")"
  printf '%s' "${value%%[$'\r\n']*}"
}

# The passwords of make secrets are hexadecimal; another character could break
# the SQL text below.
check_password() {
  [[ $1 =~ ^[A-Za-z0-9._~-]+$ ]] || {
    echo "the password in ${SECRETS}/$2 has characters other than letters, digits and . _ ~ -" >&2
    exit 1
  }
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

postgresql() {
  export PGHOST="$HOST" PGPORT="$DB_PORT" PGUSER="$DB_ADMIN_USER" PGDATABASE=postgres
  PGPASSWORD="$(secret admin-password)"
  export PGPASSWORD
  wait_for pg_isready
  for database in $DATABASES; do
    echo "Configuring the user and the database ${database}"
    # psql reads the password from the environment of the command, so the
    # password is not on the command line.
    ROLE_PASSWORD="$(secret "${database}-password")" \
      psql -v ON_ERROR_STOP=1 -q -v role="$database" <<'SQL'
\set pw `printenv ROLE_PASSWORD`
SELECT format('CREATE ROLE %I LOGIN', :'role')
  WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = :'role') \gexec
ALTER ROLE :"role" WITH LOGIN PASSWORD :'pw';
SELECT format('CREATE DATABASE %I OWNER %I TEMPLATE template0 ENCODING %L LC_COLLATE %L LC_CTYPE %L',
              :'role', :'role', 'UTF8', 'C', 'C.UTF-8')
  WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = :'role') \gexec
REVOKE ALL ON DATABASE :"role" FROM PUBLIC;
SQL
  done
}

# The option file of the mariadb client (mode 0600): the admin login, not
# on the command line. Removed at the exit of the script.
OPTIONS=""
trap 'rm -f "$OPTIONS"' EXIT

mysql_engine() {
  OPTIONS="$(mktemp)"
  local options="$OPTIONS"
  local admin_password
  admin_password="$(secret admin-password)"
  check_password "$admin_password" admin-password
  printf '[client]\nhost=%s\nport=%s\nuser=%s\npassword=%s\nprotocol=TCP\n' \
    "$HOST" "$DB_PORT" "$DB_ADMIN_USER" "$admin_password" > "$options"
  wait_for mariadb-admin --defaults-extra-file="$options" ping
  for database in $DATABASES; do
    echo "Configuring the user and the database ${database}"
    local password
    password="$(secret "${database}-password")"
    check_password "$password" "${database}-password"
    # The tables of the components set utf8mb4 and utf8mb4_bin themselves;
    # the database default is the same.
    mariadb --defaults-extra-file="$options" <<SQL
CREATE DATABASE IF NOT EXISTS \`${database}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_bin;
CREATE USER IF NOT EXISTS '${database}'@'%' IDENTIFIED BY '${password}';
ALTER USER '${database}'@'%' IDENTIFIED BY '${password}';
GRANT ALL PRIVILEGES ON \`${database}\`.* TO '${database}'@'%';
SQL
  done
}

case "${DB_ENGINE:-}" in
  postgresql) postgresql ;;
  mysql) mysql_engine ;;
  *)
    echo "DB_ENGINE must be postgresql or mysql, not '${DB_ENGINE:-}'" >&2
    exit 1
    ;;
esac
echo "All databases are configured"
