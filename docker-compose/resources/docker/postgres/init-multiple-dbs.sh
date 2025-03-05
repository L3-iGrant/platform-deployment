#!/bin/bash
set -e

# Example environment variables to pass:
#   MULTIPLE_DATABASES="db1,db2,db3"
#
# You can adjust the variable naming/format to suit your needs.

export PGPASSWORD="${POSTGRESQL_PASSWORD}"

if [[ -n "$MULTIPLE_DATABASES" ]]; then
  IFS=',' read -ra DBS <<< "$MULTIPLE_DATABASES"
  for DB in "${DBS[@]}"; do
    DB_NAME=$(echo "$DB" | xargs)  # trim whitespace
    echo "Creating database '$DB_NAME'..."
    psql -U "${POSTGRESQL_USERNAME}" -d "${POSTGRESQL_DATABASE}" -c "CREATE DATABASE \"$DB_NAME\";"
  done
fi