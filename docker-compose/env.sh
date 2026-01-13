#!/bin/bash

# =============================================================================
# Organisation Wallet Suite - Docker Compose Environment Configuration
# =============================================================================
# Copy this file to .env or source it before running docker-compose
# =============================================================================

# -----------------------------------------------------------------------------
# Container Images
# -----------------------------------------------------------------------------
export POSTGRES_IMAGE="europe-docker.pkg.dev/jenkins-189019/igrant-customers/igrant-api/postgres:2025.1.1"
export KEYCLOAK_IMAGE="europe-docker.pkg.dev/jenkins-189019/igrant-customers/igrant-api/keycloak:12.0.4-debian-10-r1"
export MONGO_IMAGE="europe-docker.pkg.dev/jenkins-189019/igrant-customers/igrant-api/mongodb:7.0-debian-12"
export NATS_IMAGE="nats:2.10.14-alpine"
export API_IMAGE="europe-docker.pkg.dev/jenkins-189019/igrant-customers/igrant-api/api:2026.1.1"
export VAULT_FACADE_IMAGE="europe-docker.pkg.dev/jenkins-189019/igrant-customers/igrant-api/vault-facade:2026.1.1"
export OWS_IMAGE="europe-docker.pkg.dev/jenkins-189019/igrant-customers/igrant-api/ows:2026.1.5"
export DASHBOARD_IMAGE="europe-docker.pkg.dev/jenkins-189019/igrant-customers/igrant-api/dashboard:2026.1.1"

# -----------------------------------------------------------------------------
# PostgreSQL Configuration
# -----------------------------------------------------------------------------
export POSTGRES_CONTAINER_NAME="postgres"
export POSTGRES_USERNAME="dbadmin"
export POSTGRES_PASSWORD="dbadmin"
export POSTGRES_DATABASE="kcdb"
export POSTGRES_PORT="5432"
export POSTGRES_VOLUME_NAME="postgres-data"

# -----------------------------------------------------------------------------
# Keycloak Configuration
# -----------------------------------------------------------------------------
export KEYCLOAK_CONTAINER_NAME="keycloak"
export KEYCLOAK_ADMIN_USERNAME="kcadmin"
export KEYCLOAK_ADMIN_PASSWORD="kcadmin"
export KEYCLOAK_PORT="8082"

# -----------------------------------------------------------------------------
# MongoDB Configuration
# -----------------------------------------------------------------------------
export MONGO_CONTAINER_NAME="mongo"
export MONGO_USERNAME="dbadmin"
export MONGO_PASSWORD="dbadmin"
export MONGO_DATABASE="owsdb"
export MONGO_PORT="27017"
export MONGO_VOLUME_NAME="mongo-data"

# -----------------------------------------------------------------------------
# NATS Configuration
# -----------------------------------------------------------------------------
export NATS_CONTAINER_NAME="nats"
export NATS_PORT="4222"
export NATS_MONITOR_PORT="8222"
export NATS_VOLUME_NAME="nats-data"

# -----------------------------------------------------------------------------
# Vault Facade Configuration
# -----------------------------------------------------------------------------
export VAULT_FACADE_CONTAINER_NAME="vault-facade"
export VAULT_FACADE_PORT="8081"
export VAULT_FACADE_APP_MODE="mongo"

# -----------------------------------------------------------------------------
# API Configuration
# -----------------------------------------------------------------------------
export API_CONTAINER_NAME="api"
export API_PORT="8080"
export API_SECRET_KEY="your-api-secret-key"
export IAM_REALM="igrant-users"
export IAM_CLIENT_ID="igrant-ios-app"
export NATS_TIMEOUT="5"

# -----------------------------------------------------------------------------
# Webhook Configuration
# -----------------------------------------------------------------------------
export WEBHOOK_CONTAINER_NAME="webhook"
export WEBHOOK_PORT="8085"

# -----------------------------------------------------------------------------
# Organisation Wallet Configuration
# -----------------------------------------------------------------------------
export OWS_CONTAINER_NAME="organisation-wallet"
export OWS_PORT="8090"
export OWS_DATABASE="walletdb"

# -----------------------------------------------------------------------------
# Enterprise Dashboard Configuration
# -----------------------------------------------------------------------------
export DASHBOARD_CONTAINER_NAME="enterprise-dashboard"
export DASHBOARD_PORT="3000"

# -----------------------------------------------------------------------------
# Public URLs (Update these for your deployment)
# -----------------------------------------------------------------------------
export API_PUBLIC_URL="http://localhost:8080"
export KEYCLOAK_PUBLIC_URL="http://localhost:8082"
export OWS_PUBLIC_URL="http://localhost:8090"
export DASHBOARD_PUBLIC_URL="http://localhost:3000"
