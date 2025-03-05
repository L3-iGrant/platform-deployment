# Use the Bitnami PostgreSQL image as the base
FROM bitnami/postgresql:14.10.0

# Copy your init script into the container
COPY init-multiple-dbs.sh /docker-entrypoint-initdb.d/
