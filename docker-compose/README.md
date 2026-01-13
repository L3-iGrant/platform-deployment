# Organisation Wallet Suite - Docker Compose

This directory contains Docker Compose configuration for running the Organisation Wallet Suite locally for development and testing purposes.

## Table of Contents

- [Prerequisites](#prerequisites)
- [Quick Start](#quick-start)
- [Services](#services)
- [Configuration](#configuration)
- [Usage](#usage)
- [Accessing Services](#accessing-services)
- [Onboarding Organisations](#onboarding-organisations)
- [Common Commands](#common-commands)
- [Troubleshooting](#troubleshooting)

## Prerequisites

- [Docker](https://docs.docker.com/get-docker/) (v20.10+)
- [Docker Compose](https://docs.docker.com/compose/install/) (v2.0+)
- Access to the container registry (see [Container Registry Access](#container-registry-access))

### Container Registry Access

The container images are hosted on Google Artifact Registry. To pull the images:

1. Contact support@igrant.io to get access credentials (`key.json` file)
2. Authenticate with the registry:

```bash
cat key.json | docker login -u _json_key --password-stdin https://europe-docker.pkg.dev
```

## Quick Start

```bash
# 1. Navigate to the docker-compose directory
cd docker-compose

# 2. (Optional) Customize environment variables
cp env.sh .env
# Edit .env as needed

# 3. Start all services
make start

# 4. Check service status
make status

# 5. View logs
make logs
```

## Services

| Service | Description | Default Port |
|---------|-------------|--------------|
| PostgreSQL | Database for Keycloak | 5432 |
| Keycloak | Identity and Access Management | 8082 |
| MongoDB | Primary database for API and wallet services | 27017 |
| NATS | Message broker with JetStream | 4222, 8222 |
| Vault Facade | Secrets management (MongoDB mode) | 8081 |
| API | Backend API service | 8080 |
| Webhook | Webhook handler service | 8085 |
| Organisation Wallet Service | Core wallet service | 8090 |
| Enterprise Dashboard | Web administration interface | 3000 |

## Configuration

### Environment Variables

All configuration is managed through environment variables. You can either:

1. **Source the env.sh file** (recommended for development):
   ```bash
   source env.sh
   ```

2. **Create a .env file**:
   ```bash
   cp env.sh .env
   # Edit .env with your values
   ```

### Key Configuration Options

| Variable | Description | Default |
|----------|-------------|---------|
| `POSTGRES_USERNAME` | PostgreSQL username | `dbadmin` |
| `POSTGRES_PASSWORD` | PostgreSQL password | `dbadmin` |
| `KEYCLOAK_ADMIN_USERNAME` | Keycloak admin username | `kcadmin` |
| `KEYCLOAK_ADMIN_PASSWORD` | Keycloak admin password | `kcadmin` |
| `MONGO_USERNAME` | MongoDB username | `dbadmin` |
| `MONGO_PASSWORD` | MongoDB password | `dbadmin` |
| `API_SECRET_KEY` | API secret key for JWT | `your-api-secret-key` |
| `VAULT_FACADE_APP_MODE` | Vault mode (`mongo` or `vault`) | `mongo` |

> **Note:** Change default passwords before using in any non-local environment.

## Usage

### Using Make Commands

```bash
# Start all services
make start

# Stop all services
make stop

# Restart all services
make restart

# Stop and remove containers
make down

# View logs (all services)
make logs

# Check status
make status

# Pull latest images
make pull
```

### Individual Service Commands

```bash
# Start/stop individual services
make postgres-start
make postgres-stop
make keycloak-start
make api-start
make ows-start
make dashboard-start

# View logs for specific service
make api-logs
make mongo-logs
make keycloak-logs
```

### Database Access

```bash
# Connect to PostgreSQL
make postgres-shell

# Connect to MongoDB
make mongo-shell
```

### Cleanup

```bash
# Remove containers and volumes (WARNING: destroys data)
make clean

# Remove project images
make clean-images

# Prune unused Docker resources
make prune
```

## Accessing Services

Once the services are running, you can access them at:

| Service | URL |
|---------|-----|
| API | http://localhost:8080 |
| Keycloak Admin Console | http://localhost:8082 |
| Organisation Wallet Service | http://localhost:8090 |
| Enterprise Dashboard | http://localhost:3000 |
| Vault Facade | http://localhost:8081 |
| NATS Monitoring | http://localhost:8222 |

### Default Credentials

| Service | Username | Password |
|---------|----------|----------|
| Keycloak Admin | `kcadmin` | `kcadmin` |
| PostgreSQL | `dbadmin` | `dbadmin` |
| MongoDB | `dbadmin` | `dbadmin` |

## Onboarding Organisations

After starting the services, you need to initialize a wallet provider organisation and tenant organisations using the setup script.

### Running the Setup Script

1. Access the Organisation Wallet service container:

```bash
docker compose exec organisation-wallet /bin/bash
```

2. Navigate to the scripts folder and run the setup script:

```bash
cd scripts
uv run setup_organisations.py --config sample_config.yaml
```

### Sample Configuration

Create a `sample_config.yaml` file:

```yaml
# Organisation type to create/use
organisationType: "Technology"

# List of organisations to set up
organisations:
  # Wallet Provider Organisation
  - admin:
      email: "walletprovider@example.com"
      name: "Wallet Provider"
      password: "<your-password>"
      phone: "+1234567890"

    organisation:
      name: "Wallet Provider Organisation"
      location: "Sweden"
      description: "Wallet provider organisation description."
      policyUrl: "https://example.com/privacy.html"

    isWalletProvider: true
    vaultType: "igrantioVault"

    features:
      gettingStarted: true
      dataAgreements: false
      managedData: false
      digitalWalletAries: false
      digitalWalletOid4vc: true
      manageUsers: false
      privacyDashboard: false
      account: true
      supportEvents: true

    credentialDefinitions:
      - label: "Wallet Unit Attestation"
        expirationInDays: 30
        supportRevocation: true
        display:
          name: "Wallet Unit Attestation"
          description: "Attests the security context of a wallet unit"
          backgroundColor: "#1E3A5F"
          textColor: "#FFFFFF"
        credentialFormat: "dc+sd-jwt"
        vct: "WalletUnitAttestation"
        version: "draft_13"
        claims:
          type: "object"
          properties:
            attested_security_context:
              type: "string"
              limitDisclosure: false
          additionalProperties: true
          required:
            - "attested_security_context"
        credentialBindingMethods:
          - "did:key"

  # Tenant Organisation
  - admin:
      email: "admin@tenant.com"
      name: "Tenant Admin"
      password: "<your-password>"
      phone: "+1234567891"

    organisation:
      name: "Tenant Organisation"
      location: "Berlin"
      description: "Tenant organisation description."
      policyUrl: "https://tenant.com/policy.html"

    isWalletProvider: false
    createWalletUnit: true
    vaultType: "igrantioVault"
```

## Common Commands

```bash
# View all available commands
make help

# Start fresh (remove everything and start again)
make clean && make start

# Update to latest images
make pull && make restart

# Debug a specific service
docker compose logs -f api

# Execute command in a container
docker compose exec api sh

# Scale a service (if needed)
docker compose up -d --scale api=2
```

## Troubleshooting

### Services not starting

1. Check if ports are already in use:
   ```bash
   lsof -i :8080  # Check if port 8080 is in use
   ```

2. Check Docker logs:
   ```bash
   make logs
   ```

3. Ensure Docker has enough resources (memory, disk space)

### Database connection issues

1. Verify database services are healthy:
   ```bash
   make status
   ```

2. Check database logs:
   ```bash
   make postgres-logs
   make mongo-logs
   ```

### Container registry authentication issues

Ensure you're logged in to the registry:
```bash
cat key.json | docker login -u _json_key --password-stdin https://europe-docker.pkg.dev
```

### Reset everything

To completely reset the environment:
```bash
make down
docker volume prune -f
make start
```

## License

Copyright (c) 2025-2035 LCubed AB (iGrant.io), Sweden

Licensed under the Apache 2.0 License.
