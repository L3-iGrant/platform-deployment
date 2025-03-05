#!/bin/bash

# Vault Configuration
export VAULT_IMAGE="hashicorp/vault:latest"
export VAULT_CONTAINER_NAME="vault"
export VAULT_PORT="8200"
export VAULT_ADDR="http://0.0.0.0:8200"
export VAULT_API_ADDR="http://0.0.0.0:8200"
export VAULT_VOLUME_NAME="vault-data"

# SecureVault Configuration
export SECUREVAULT_IMAGE="europe-docker.pkg.dev/jenkins-189019/igrantio/securevault:2025.2.4"
export SECUREVAULT_CONTAINER_NAME="securevault"
export SECUREVAULT_PORT="8081"
export VAULT_USER="admin"
export VAULT_PASSWORD="admin"

# MongoDB Configuration
export MONGO_CONTAINER_NAME="mongo"
export MONGODB_DATABASE="igrant-consentdb"
export MONGODB_USER="igrant-user"
export MONGODB_PASSWORD="igrant-password"
export MONGODB_PORT="27017"
export MONGO_VOLUME_NAME="mongo-datadir"

# PostgreSQL Configuration
export POSTGRESQL_CONTAINER_NAME="postgresql"
export POSTGRESQL_USERNAME="bn_keycloak"
export POSTGRESQL_PASSWORD="bn_keycloak"
export POSTGRESQL_DATABASE="bitnami_keycloak"
export POSTGRESQL_PORT="5442"
export MULTIPLE_DATABASES="eudiwalletdb"
export POSTGRESQL_VOLUME_NAME="postgresql-datadir"

# Keycloak Configuration
export KEYCLOAK_IMAGE="bitnami/keycloak:12.0.4-debian-10-r1"
export KEYCLOAK_CONTAINER_NAME="keycloak"
export KEYCLOAK_USER="keycloak"
export KEYCLOAK_PASSWORD="j3ckN4914IOK"
export KEYCLOAK_DATABASE_PASSWORD="bn_keycloak"
export KEYCLOAK_PORT="8082"

# API Configuration
export API_IMAGE="europe-docker.pkg.dev/jenkins-189019/igrantio/api:2025.2.4-1"
export API_CONTAINER_NAME="api"
export API_PORT="8080"

# Webhook Configuration
export WEBHOOK_IMAGE="europe-docker.pkg.dev/jenkins-189019/igrantio/api:2025.2.4-1"
export WEBHOOK_CONTAINER_NAME="webhook"
export WEBHOOK_PORT="8085"

# Organisation Wallet Config Configuration
export OWCONFIG_IMAGE="europe-docker.pkg.dev/jenkins-189019/igrantio/organisationwallet:2025.2.4"
export OWCONFIG_CONTAINER_NAME="owconfig"
export OWCONFIG_PORT="8090"
export SECURE_VAULT_BASE_URL="http://securevault:8080"
export ROUTE_PERMITTED="config"
export DATABASE_USER="bn_keycloak"
export DATABASE_PASSWORD="bn_keycloak"
export DATABASE_HOST="postgresql"
export DATABASE_PORT="5432"
export DATABASE_DB="eudiwalletdb"
export EBSI_BASE_URL="https://api-pilot.ebsi.eu"
export WALLET_UNIT_PRODUCTION_CHECKS_ENABLED="true"
export WALLET_PROVIDER_BASE_URL="https://ow.igrant.io/organisation/2bd50451-ad41-4836-ad24-4f12194af215/service"


# Organisation Wallet Service Configuration
export OWSERVICE_IMAGE="europe-docker.pkg.dev/jenkins-189019/igrantio/organisationwallet:2025.2.4"
export OWSERVICE_CONTAINER_NAME="owservice"
export OWSERVICE_PORT="9090"


# Change these variables if you have custom domains configured
export API_PUBLIC_BASE_URL="http://localhost:8080"
export DOMAIN="https://ow.igrant.io"
export OWSERVICE_PUBLIC_BASE_URL="http://localhost:9090"