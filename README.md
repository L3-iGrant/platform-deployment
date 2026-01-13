<h1 align="center">
    Organisation Wallet Suite by iGrant.io
</h1>

<p align="center">
    <a href="/../../commits/" title="Last Commit"><img src="https://img.shields.io/github/last-commit/l3-iGrant/helmcharts?style=flat"></a>
    <a href="/../../issues" title="Open Issues"><img src="https://img.shields.io/github/issues/l3-iGrant/helmcharts?style=flat"></a>
    <a href="./LICENSE" title="License"><img src="https://img.shields.io/badge/License-Apache%202.0-yellowgreen?style=flat"></a>
    <a href="https://artifacthub.io/packages/search?repo=organisationwallet" title="Artifacthub"><img src="https://img.shields.io/endpoint?url=https://artifacthub.io/badge/repository/organisationwallet"></a>
</p>

<p align="center">
The Helm chart for Organisation Wallet Suite by iGrant.io enables the issuer, holder, and verifier of verifiable credentials within the eIDAS 2.0 framework. It incorporates the latest amendments, the EU Architectural Reference Framework (ARF), and Implementing Acts (IA).
</p>

---

## Table of Contents

- [Table of Contents](#table-of-contents)
- [About](#about)
- [Requirements](#requirements)
- [Quick Start](#quick-start)
  - [Add Helm Repository](#add-helm-repository)
  - [Install Chart](#install-chart)
  - [Uninstall Chart](#uninstall-chart)
- [Configuration](#configuration)
  - [Global Configuration](#global-configuration)
  - [PostgreSQL](#postgresql)
  - [Keycloak](#keycloak)
  - [MongoDB](#mongodb)
  - [NATS](#nats)
  - [API](#api)
  - [Vault Facade](#vault-facade)
  - [Organisation Wallet Service](#organisation-wallet-service)
  - [Enterprise Dashboard](#enterprise-dashboard)
- [Secrets Management](#secrets-management)
  - [MongoDB-based Vault (Recommended for Development)](#mongodb-based-vault-recommended-for-development)
  - [HashiCorp Vault (Optional - Production)](#hashicorp-vault-optional---production)
    - [Prerequisites](#prerequisites)
    - [Initialize and Unseal Vault](#initialize-and-unseal-vault)
    - [Configure Vault Facade for HashiCorp Vault](#configure-vault-facade-for-hashicorp-vault)
- [Onboarding Organisations](#onboarding-organisations)
  - [Running the Setup Script](#running-the-setup-script)
  - [Sample Configuration](#sample-configuration)
  - [Configuration Options](#configuration-options)
- [Contributing](#contributing)
- [License](#license)

---

## About

This repository hosts Helm charts for deploying the Organisation Wallet Suite by iGrant.io on Kubernetes. The Organisation Wallet Suite enables organizations to issue, hold, and verify credentials in compliance with the European Digital Identity framework.

## Requirements

| Requirement | Version      |
| ----------- | ------------ |
| Kubernetes  | `>=1.20.0-0` |
| Helm        | `>=3.0.0`    |

## Quick Start

### Add Helm Repository

```bash
helm repo add organisationwallet https://l3-iGrant.github.io/helmcharts/stable/
helm repo update
```

### Install Chart

```bash
helm install [RELEASE_NAME] organisationwallet/organisationwallet --version 2026.1.3
```

To install with a custom values file:

```bash
helm install [RELEASE_NAME] organisationwallet/organisationwallet --version 2026.1.3 --values values.yaml
```

### Uninstall Chart

```bash
helm uninstall [RELEASE_NAME]
```

This removes all Kubernetes components associated with the chart and deletes the release.

---

## Configuration

To view all configurable options:

```bash
helm show values organisationwallet/organisationwallet
```

### Global Configuration

| Parameter                   | Description                          | Default      |
| --------------------------- | ------------------------------------ | ------------ |
| `namespace`                 | Kubernetes namespace                 | `ig`         |
| `prefix`                    | Prefix for Kubernetes object names   | `""`         |
| `resources`                 | Resource constraints for pods        | `{}`         |
| `securityContext.runAsUser` | User ID to run containers            | `0`          |
| `storageClassName`          | Storage class for persistent volumes | `local-path` |

```yaml
namespace: ig
prefix:
resources: {}
securityContext:
  runAsUser: 0
storageClassName: local-path
```

### PostgreSQL

PostgreSQL is used as the database backend for Keycloak.

| Parameter           | Description                  | Default                                                                              |
| ------------------- | ---------------------------- | ------------------------------------------------------------------------------------ |
| `postgres.enabled`  | Enable PostgreSQL deployment | `true`                                                                               |
| `postgres.image`    | Container image              | `europe-docker.pkg.dev/jenkins-189019/igrant-customers/igrant-api/postgres:2025.1.1` |
| `postgres.username` | Database username            | `dbadmin`                                                                            |
| `postgres.password` | Database password            | `<your-password>`                                                                    |
| `postgres.database` | Database name                | `kcdb`                                                                               |

```yaml
postgres:
  enabled: true
  image: europe-docker.pkg.dev/jenkins-189019/igrant-customers/igrant-api/postgres:2025.1.1
  username: dbadmin
  password: <your-password>
  database: kcdb
```

### Keycloak

Keycloak provides identity and access management.

| Parameter                  | Description                | Default                                                                                         |
| -------------------------- | -------------------------- | ----------------------------------------------------------------------------------------------- |
| `keycloak.enabled`         | Enable Keycloak deployment | `true`                                                                                          |
| `keycloak.image`           | Container image            | `europe-docker.pkg.dev/jenkins-189019/igrant-customers/igrant-api/keycloak:12.0.4-debian-10-r1` |
| `keycloak.adminUsername`   | Admin username             | `kcadmin`                                                                                       |
| `keycloak.adminPassword`   | Admin password             | `<your-password>`                                                                               |
| `keycloak.dbUsername`      | Database username          | `dbadmin`                                                                                       |
| `keycloak.dbPassword`      | Database password          | `<your-password>`                                                                               |
| `keycloak.dbName`          | Database name              | `kcdb`                                                                                          |
| `keycloak.frontendUrl`     | Frontend URL               | `https://keycloak.example.com`                                                                  |
| `keycloak.ingress.enabled` | Enable ingress             | `true`                                                                                          |

```yaml
keycloak:
  enabled: true
  image: europe-docker.pkg.dev/jenkins-189019/igrant-customers/igrant-api/keycloak:12.0.4-debian-10-r1
  adminUsername: kcadmin
  adminPassword: <your-password>
  dbUsername: dbadmin
  dbPassword: <your-password>
  dbName: kcdb
  frontendUrl: https://keycloak.example.com
  ingress:
    enabled: true
    annotations:
      kubernetes.io/ingress.allow-http: "false"
      kubernetes.io/ingress.class: nginx
      nginx.ingress.kubernetes.io/enable-cors: "true"
      nginx.ingress.kubernetes.io/proxy-buffer-size: 128k
      cert-manager.io/cluster-issuer: "letsencrypt-prod"
      kubernetes.io/tls-acme: "true"
      nginx.ingress.kubernetes.io/proxy-set-headers: |
        X-Forwarded-Proto https
        X-Forwarded-Port 443
    hosts:
      - host: keycloak.example.com
        paths:
          - path: /
            pathType: Prefix
    tls:
      - hosts:
          - keycloak.example.com
        secretName: keycloak-tls
```

### MongoDB

MongoDB is used as the primary database for the Organisation Wallet Suite.

| Parameter        | Description               | Default                                                                                  |
| ---------------- | ------------------------- | ---------------------------------------------------------------------------------------- |
| `mongo.enabled`  | Enable MongoDB deployment | `true`                                                                                   |
| `mongo.image`    | Container image           | `europe-docker.pkg.dev/jenkins-189019/igrant-customers/igrant-api/mongodb:7.0-debian-12` |
| `mongo.username` | Database username         | `dbadmin`                                                                                |
| `mongo.password` | Database password         | `<your-password>`                                                                        |
| `mongo.database` | Database name             | `owsdb`                                                                                  |

```yaml
mongo:
  enabled: true
  image: europe-docker.pkg.dev/jenkins-189019/igrant-customers/igrant-api/mongodb:7.0-debian-12
  username: dbadmin
  password: <your-password>
  database: owsdb
```

### NATS

NATS provides messaging and event streaming capabilities.

| Parameter      | Description            | Default               |
| -------------- | ---------------------- | --------------------- |
| `nats.enabled` | Enable NATS deployment | `true`                |
| `nats.image`   | Container image        | `nats:2.10.14-alpine` |

```yaml
nats:
  enabled: true
  image: nats:2.10.14-alpine
```

### API

The API service provides the backend for the Organisation Wallet Suite.

| Parameter                        | Description             | Default                                                                         |
| -------------------------------- | ----------------------- | ------------------------------------------------------------------------------- |
| `api.enabled`                    | Enable API deployment   | `true`                                                                          |
| `api.imagePullSecret`            | Image pull secret name  | `""`                                                                            |
| `api.image`                      | Container image         | `europe-docker.pkg.dev/jenkins-189019/igrant-customers/igrant-api/api:2026.1.1` |
| `api.ingress.enabled`            | Enable ingress          | `true`                                                                          |
| `api.configuration.ApiSecretKey` | API secret key for JWT  | `<your-secret>`                                                                 |
| `api.configuration.Iam.url`      | Keycloak URL            | `""`                                                                            |
| `api.configuration.Iam.realm`    | Keycloak realm          | `igrant-users`                                                                  |
| `api.configuration.Iam.ClientId` | Keycloak client ID      | `igrant-ios-app`                                                                |
| `api.configuration.Nats.url`     | NATS server URL         | `""`                                                                            |
| `api.configuration.Nats.timeout` | NATS connection timeout | `5`                                                                             |

```yaml
api:
  enabled: true
  imagePullSecret:
  image: europe-docker.pkg.dev/jenkins-189019/igrant-customers/igrant-api/api:2026.1.1
  ingress:
    enabled: true
    annotations:
      kubernetes.io/ingress.allow-http: "false"
      kubernetes.io/ingress.class: nginx
      nginx.ingress.kubernetes.io/enable-cors: "true"
      nginx.ingress.kubernetes.io/proxy-buffer-size: 128k
      cert-manager.io/cluster-issuer: "letsencrypt-prod"
      kubernetes.io/tls-acme: "true"
    hosts:
      - host: api.example.com
        paths:
          - path: /
            pathType: Prefix
    tls:
      - hosts:
          - api.example.com
        secretName: api-tls
  configuration:
    database:
      host:
    ApiSecretKey: <your-secret>
    Iam:
      url: https://keycloak.example.com/auth
      realm: igrant-users
      ClientId: igrant-ios-app
    Nats:
      url:
      timeout: 5
```

### Vault Facade

The Vault Facade provides a unified interface for secrets management. It supports two modes:
- **mongo** (Recommended for development): Uses MongoDB for storing secrets
- **vault**: Uses HashiCorp Vault for production-grade secrets management

| Parameter                     | Description                               | Default                                                                                  |
| ----------------------------- | ----------------------------------------- | ---------------------------------------------------------------------------------------- |
| `vaultFacade.enabled`         | Enable Vault Facade deployment            | `true`                                                                                   |
| `vaultFacade.imagePullSecret` | Image pull secret name                    | `""`                                                                                     |
| `vaultFacade.image`           | Container image                           | `europe-docker.pkg.dev/jenkins-189019/igrant-customers/igrant-api/vault-facade:2026.1.1` |
| `vaultFacade.appMode`         | Application mode (`mongo` or `vault`)     | `mongo`                                                                                  |
| `vaultFacade.vault.addr`      | Vault server address (when appMode=vault) | `""`                                                                                     |
| `vaultFacade.vault.user`      | Vault username (when appMode=vault)       | `""`                                                                                     |
| `vaultFacade.vault.password`  | Vault password (when appMode=vault)       | `""`                                                                                     |

```yaml
vaultFacade:
  enabled: true
  imagePullSecret:
  image: europe-docker.pkg.dev/jenkins-189019/igrant-customers/igrant-api/vault-facade:2026.1.1
  appMode: mongo
  vault:
    addr:
    user:
    password:
```

### Organisation Wallet Service

The core Organisation Wallet service.

| Parameter                                    | Description                           | Default                                                                         |
| -------------------------------------------- | ------------------------------------- | ------------------------------------------------------------------------------- |
| `organisationWallet.enabled`                 | Enable Organisation Wallet deployment | `true`                                                                          |
| `organisationWallet.imagePullSecret`         | Image pull secret name                | `""`                                                                            |
| `organisationWallet.image`                   | Container image                       | `europe-docker.pkg.dev/jenkins-189019/igrant-customers/igrant-api/ows:2026.1.5` |
| `organisationWallet.dbName`                  | Database name                         | `walletdb`                                                                      |
| `organisationWallet.service.ingress.enabled` | Enable ingress                        | `true`                                                                          |

```yaml
organisationWallet:
  enabled: true
  imagePullSecret:
  image: europe-docker.pkg.dev/jenkins-189019/igrant-customers/igrant-api/ows:2026.1.5
  dbName: walletdb
  service:
    ingress:
      enabled: true
      annotations:
        kubernetes.io/ingress.allow-http: "false"
        kubernetes.io/ingress.class: nginx
        nginx.ingress.kubernetes.io/enable-cors: "true"
        nginx.ingress.kubernetes.io/proxy-buffer-size: 128k
        cert-manager.io/cluster-issuer: "letsencrypt-prod"
        kubernetes.io/tls-acme: "true"
      hosts:
        - host: wallet.example.com
          paths:
            - path: /
              pathType: Prefix
      tls:
        - hosts:
            - wallet.example.com
          secretName: wallet-tls
```

### Enterprise Dashboard

The web-based administration dashboard.

| Parameter                             | Description                            | Default                                                                               |
| ------------------------------------- | -------------------------------------- | ------------------------------------------------------------------------------------- |
| `enterpriseDashboard.enabled`         | Enable Enterprise Dashboard deployment | `true`                                                                                |
| `enterpriseDashboard.imagePullSecret` | Image pull secret name                 | `""`                                                                                  |
| `enterpriseDashboard.image`           | Container image                        | `europe-docker.pkg.dev/jenkins-189019/igrant-customers/igrant-api/dashboard:2026.1.1` |
| `enterpriseDashboard.ingress.enabled` | Enable ingress                         | `true`                                                                                |

```yaml
enterpriseDashboard:
  enabled: true
  imagePullSecret:
  image: europe-docker.pkg.dev/jenkins-189019/igrant-customers/igrant-api/dashboard:2026.1.1
  ingress:
    enabled: true
    annotations:
      kubernetes.io/ingress.allow-http: "false"
      kubernetes.io/ingress.class: nginx
      nginx.ingress.kubernetes.io/enable-cors: "true"
      nginx.ingress.kubernetes.io/proxy-buffer-size: 128k
      cert-manager.io/cluster-issuer: "letsencrypt-prod"
      kubernetes.io/tls-acme: "true"
    hosts:
      - host: dashboard.example.com
        paths:
          - path: /
            pathType: Prefix
    tls:
      - hosts:
          - dashboard.example.com
        secretName: dashboard-tls
```

---

## Secrets Management

The Organisation Wallet Suite supports two modes for secrets management via the Vault Facade service.

### MongoDB-based Vault (Recommended for Development)

For development and testing environments, the MongoDB-based vault is recommended. This mode stores secrets directly in MongoDB, simplifying the deployment without requiring external dependencies.

To enable MongoDB-based vault:

```yaml
vaultFacade:
  enabled: true
  image: europe-docker.pkg.dev/jenkins-189019/igrant-customers/igrant-api/vault-facade:2026.1.1
  appMode: mongo
```

This configuration uses the existing MongoDB deployment for secrets storage, making it ideal for:
- Local development environments
- Testing and staging deployments
- Quick proof-of-concept setups

### HashiCorp Vault (Optional - Production)

For production environments requiring enterprise-grade secrets management, HashiCorp Vault can be used as an optional backend.

#### Prerequisites

Install HashiCorp Vault using the official Helm chart:

```bash
# Add HashiCorp Helm repository
helm repo add hashicorp https://helm.releases.hashicorp.com
helm repo update

# Install Vault with HA and Raft storage
helm upgrade --install vault hashicorp/vault \
  --namespace vault \
  --create-namespace \
  -f vault-values.yaml
```

Create a `vault-values.yaml` file:

```yaml
server:
  affinity: ""
  ha:
    enabled: true
    raft:
      enabled: true
      setNodeId: true
      config: |
        ui = true
        cluster_name = "vault-integrated-storage"
        storage "raft" {
          path = "/vault/data/"
        }
        listener "tcp" {
          address = "[::]:8200"
          cluster_address = "[::]:8201"
          tls_disable = "true"
        }
        service_registration "kubernetes" {}
```

#### Initialize and Unseal Vault

```bash
# Initialize Vault (only needed once)
kubectl exec -n vault vault-0 -- vault operator init

# Store the unseal keys and root token securely
# Unseal Vault using the unseal keys
kubectl exec -n vault vault-0 -- vault operator unseal <unseal-key-1>
kubectl exec -n vault vault-0 -- vault operator unseal <unseal-key-2>
kubectl exec -n vault vault-0 -- vault operator unseal <unseal-key-3>
```

#### Configure Vault Facade for HashiCorp Vault

```yaml
vaultFacade:
  enabled: true
  image: europe-docker.pkg.dev/jenkins-189019/igrant-customers/igrant-api/vault-facade:2026.1.1
  appMode: vault
  vault:
    addr: http://vault.vault.svc.cluster.local:8200
    user: <vault-username>
    password: <vault-password>
```

For more information, see the [Vault Helm documentation](https://developer.hashicorp.com/vault/docs/platform/k8s/helm).

---

## Onboarding Organisations

After deploying the Organisation Wallet Suite, you need to initialize a wallet provider organisation and tenant organisations. This is done using the setup script included in the Organisation Wallet Config service.

### Running the Setup Script

1. Access the Organisation Wallet Config service container:

```bash
# For Kubernetes
kubectl exec -it <ows-config-pod-name> -n <namespace> -- /bin/bash

# For Docker Compose
docker compose exec organisation-wallet /bin/bash
```

2. Navigate to the scripts folder and run the setup script:

```bash
cd scripts
uv run setup_organisations.py --config sample_config.yaml
```

### Sample Configuration

Create a configuration file (e.g., `sample_config.yaml`) with the following structure:

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
      description: "Wallet provider organisation description. Contact our DPO at dpo@example.com for data-related queries."
      policyUrl: "https://example.com/privacy.html"

    # Enable this organisation as a wallet provider
    isWalletProvider: true

    # Vault type for key management
    vaultType: "igrantioVault"

    # Custom wallet features (optional)
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

    # Credential definitions to create
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
      description: "Tenant organisation description. Contact our DPO for data-related queries."
      policyUrl: "https://tenant.com/policy.html"

    isWalletProvider: false
    createWalletUnit: true
    vaultType: "igrantioVault"
```

### Configuration Options

| Field                      | Description                               | Required |
| -------------------------- | ----------------------------------------- | -------- |
| `organisationType`         | Type of organisation (e.g., "Technology") | Yes      |
| `admin.email`              | Admin user email                          | Yes      |
| `admin.name`               | Admin user name                           | Yes      |
| `admin.password`           | Admin user password                       | Yes      |
| `organisation.name`        | Organisation name                         | Yes      |
| `organisation.location`    | Organisation location                     | Yes      |
| `organisation.description` | Organisation description                  | Yes      |
| `organisation.policyUrl`   | Privacy policy URL                        | Yes      |
| `isWalletProvider`         | Set to `true` for wallet provider org     | Yes      |
| `createWalletUnit`         | Create wallet unit for tenant orgs        | No       |
| `vaultType`                | Vault type (`igrantioVault`)              | Yes      |
| `features`                 | Feature flags for the organisation        | No       |
| `credentialDefinitions`    | Credential definitions to create          | No       |

---

## Contributing

Feel free to improve the chart and send us a pull request. If you find any problems, please create an issue in this repository.

## License

Copyright (c) 2025-2035 LCubed AB (iGrant.io), Sweden

Licensed under the Apache 2.0 License. You may not use this file except in compliance with the License.

Unless required by applicable law or agreed to in writing, software distributed under the License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the [LICENSE](./LICENSE) file for the specific language governing permissions and limitations under the License.
