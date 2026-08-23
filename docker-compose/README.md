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
- [Exposing Services Externally](#exposing-services-externally)
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
| Organisation Wallet Service | Core wallet service (routes) | 8090 |
| Organisation Wallet Config | Core wallet service (config/setup) | 8091 |
| OIDC Facade | OIDC extension service | 6000, 7000 |
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
| `VAULT_FACADE_APP_MODE` | Vault mode (`mongo` or `vault`) | `mongo` |
| `OIDC_FACADE_DATABASE` | OIDC Facade database name | `oidcfacadedb` |

> **Note:** Change default passwords before using in any non-local environment.

### Configuration Files

The API and Enterprise Dashboard services use JSON configuration files mounted as volumes, matching the same format used in Kubernetes ConfigMaps:

| File | Mount Path | Description |
|------|-----------|-------------|
| `config/api/config-production.json` | `/opt/l3-igrant/api/config` | API and Webhook configuration |
| `config/enterprise-dashboard/config.json` | `/usr/share/nginx/html/config` | Dashboard configuration |

Edit these files directly to customise service configuration (database, IAM, NATS, OIDC, etc.).

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
| Organisation Wallet Config | http://localhost:8091 |
| OIDC Facade Service | http://localhost:6000 |
| OIDC Facade Config | http://localhost:7000 |
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

## Exposing Services Externally

For features like mobile wallet testing, OIDC flows, or webhook callbacks, some services need to be reachable from outside your local machine. You can use a tunneling tool to expose them.

### Which services need external URLs?

| Service | Port | Used by |
|---------|------|---------|
| **API** | 8080 | Dashboard `baseUrl`, API config `Iam.APIBaseUrl`, `SSIAriesCloudAgentDeployment.BackendAPIBaseURL`, OIDC Facade `BASE_SERVICE_URL`/`PROXY_PREFIX` |
| **Keycloak** | 8082 | API config `Iam.url`, Keycloak `KEYCLOAK_FRONTEND_URL` |
| **Organisation Wallet** | 8090 | API config `OpenIdDeployment.OpenIdServiceEndpoint`, wallet `DOMAIN` |
| **Dashboard** | 3000 | API config `Dashboard.url` |

### Using ngrok

```bash
# Expose API
ngrok http 8080

# Expose Keycloak
ngrok http 8082

# Expose Organisation Wallet
ngrok http 8090

# Expose Dashboard
ngrok http 3000
```

### Using Cloudflare Tunnel

```bash
# Expose API
cloudflared tunnel --url http://localhost:8080

# Expose Keycloak
cloudflared tunnel --url http://localhost:8082

# Expose Organisation Wallet
cloudflared tunnel --url http://localhost:8090

# Expose Dashboard
cloudflared tunnel --url http://localhost:3000
```

### Using Tailscale Funnel

```bash
# Expose API
tailscale funnel 8080

# Expose Keycloak
tailscale funnel 8082

# Expose Organisation Wallet
tailscale funnel 8090

# Expose Dashboard
tailscale funnel 3000
```

### Updating configuration with tunnel URLs

After obtaining your tunnel URLs, update these locations:

1. **`env.sh`** (or `.env`) - update the public URLs:

```bash
export API_PUBLIC_URL="https://your-api-tunnel.ngrok.io"
export KEYCLOAK_PUBLIC_URL="https://your-keycloak-tunnel.ngrok.io"
export OWS_PUBLIC_URL="https://your-wallet-tunnel.ngrok.io"
export DASHBOARD_PUBLIC_URL="https://your-dashboard-tunnel.ngrok.io"
```

2. **`config/api/config-production.json`** - update the external-facing URLs:

```json
{
  "Dashboard": {
    "url": "https://your-dashboard-tunnel.ngrok.io"
  },
  "Iam": {
    "url": "https://your-keycloak-tunnel.ngrok.io/auth",
    "APIBaseUrl": "https://your-api-tunnel.ngrok.io"
  },
  "SSIAriesCloudAgentDeployment": {
    "BackendAPIBaseURL": "https://your-api-tunnel.ngrok.io"
  },
  "OpenIdDeployment": {
    "OpenIdServiceEndpoint": "https://your-wallet-tunnel.ngrok.io"
  }
}
```

3. **`config/enterprise-dashboard/config.json`** - update the API base URL:

```json
{
  "baseUrl": "https://your-api-tunnel.ngrok.io"
}
```

4. Restart services to pick up the changes:

```bash
make restart
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

Copyright (c) 2025-2035 iGrant Technologies AB (iGrant.io), Sweden

Licensed under the Apache 2.0 License.
