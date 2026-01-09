<h1 align="center">
    Organisation Wallet by iGrant.io Infrastructure
</h1>

<p align="center">
    <a href="/../../commits/" title="Last Commit"><img src="https://img.shields.io/github/last-commit/l3-iGrant/helmcharts?style=flat"></a>
    <a href="/../../issues" title="Open Issues"><img src="https://img.shields.io/github/issues/l3-iGrant/helmcharts?style=flat"></a>
    <a href="./LICENSE" title="License"><img src="https://img.shields.io/badge/License-Apache%202.0-yellowgreen?style=flat"></a>
    <a href="https://artifacthub.io/packages/search?repo=organisationwallet" title="Artifacthub"><img src="https://img.shields.io/endpoint?url=https://artifacthub.io/badge/repository/organisationwallet"></a>
</p>

<p align="center">
  <a href="#about">About</a> •
  <a href="#release-status">Release Status</a> •
  <a href="#external-dependencies">External Dependencies</a> •
  <a href="#configuration">Configuration</a> •
  <a href="#contributing">Contributing</a> •
  <a href="#licensing">Licensing</a>
</p>

## About

This repository hosts manifests for setting up infrastructure for Organisation Wallet by iGrant.io.

## Release Status

In-progress

## Requirements

Kubernetes: `>=1.20.0-0`

## External Dependencies

The following external services are required and should be installed separately before deploying the Organisation Wallet.

### NATS (with JetStream)

NATS is used for event streaming and messaging. Install using the official NATS Helm chart:

```bash
# Add NATS Helm repository
helm repo add nats https://nats-io.github.io/k8s/helm/charts/
helm repo update

# Install NATS with JetStream and clustering enabled
helm upgrade --install nats nats/nats \
  --set config.jetstream.enabled=true \
  --set config.cluster.enabled=true \
  --namespace nats \
  --create-namespace

# Install NACK (NATS Controllers for Kubernetes) for JetStream management
helm upgrade --install nack nats/nack \
  --set jetstream.nats.url=nats://nats.nats.svc.cluster.local:4222 \
  --namespace nats
```

For more information, see the [NACK documentation](https://github.com/nats-io/k8s/tree/main/helm/charts/nack).

### HashiCorp Vault

Vault is used for secrets management. Install using the official HashiCorp Helm chart:

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

Create a `vault-values.yaml` file with the following configuration:

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
  postStart:
    - "/bin/sh"
    - "-c"
    - |
      sleep 10
      vault operator unseal "$VAULT_UNSEAL_KEY"
  extraEnvironmentVars:
    VAULT_UNSEAL_KEY: <your-unseal-key>
```

After installation, initialize and unseal Vault:

```bash
# Initialize Vault (only needed once)
kubectl exec -n vault vault-0 -- vault operator init

# Store the unseal keys and root token securely
# Update VAULT_UNSEAL_KEY in vault-values.yaml with one of the unseal keys
```

For more information, see the [Vault Helm documentation](https://developer.hashicorp.com/vault/docs/platform/k8s/helm).

## Get Repo Info

```bash
helm repo add organisationwallet https://l3-iGrant.github.io/helmcharts/stable/
helm repo update
```

## Install Chart

**Important:** only helm3 is supported

```bash
helm install [RELEASE_NAME] organisationwallet/organisationwallet --version 2025.1.1
```

The command deploys Organisation Wallet by iGrant.io on the Kubernetes cluster in the default configuration.

See configuration below for customisation.

## Uninstall Chart

```bash
helm uninstall [RELEASE_NAME]
```

This removes all the Kubernetes components associated with the chart and deletes the release.

## Configuration

To see all configurable options with detailed comments, visit the chart's values.yaml, or run these configuration commands:

```bash
helm show values organisationwallet/organisationwallet
```
Example values file is provided [here](https://github.com/l3-iGrant/helmcharts/blob/main/example-values.yaml). You can install this file by running below command:
```bash
helm install [RELEASE_NAME] organisationwallet/organisationwallet --version 2025.1.1 --values example-values.yaml
```

#### Global configuration

```yaml
# Namespace for kubernetes cluster
namespace: organisationwallet
# Prefix for kubernetes object names
prefix:
# Resource constraints for a pod
resources: {}
# Security context for a pod
securityContext:
  runAsUser: 0
# Storage class name
storageClassName: standard
```

#### Postgres

```yaml
postgres:
  enabled: true
  # Container image
  image: bitnami/postgresql:14.10.0
  # Username
  username: bn_keycloak
  # Password
  password: bn_keycloak
  # Database name
  database: bitnami_keycloak
```


#### Keycloak

```yaml
keycloak:
  enabled: true
  # Container image
  image: docker.io/bitnami/keycloak:22.0.2-debian-11-r0
  # Username
  adminUsername: admin
  # Password
  adminPassword: admin
  # Database user password
  dbPassword: bn_keycloak
  # Database username
  dbUsername: bn_keycloak
  # Database name
  dbName: bitnami_keycloak
  # Ingress
  ingress:
    enabled: false
    # Annotations for the ingress
    annotations:
      # Default annotations if ingress is nginx ingress
      # Allow HTTP false
      kubernetes.io/ingress.allow-http: "false"
      # Ingress class as NGINX
      kubernetes.io/ingress.class: nginx
      # Enable CORS
      nginx.ingress.kubernetes.io/enable-cors: "true"
      # Proxy buffer size
      nginx.ingress.kubernetes.io/proxy-buffer-size: 128k
    # Hosts
    hosts:
      - host: test-keycloak.example.com
        paths:
          - path: /
            pathType: Prefix
    # TLS
    tls:
      - hosts:
          - test-keycloak.example.com
        secretName: tls-secret
```

#### MongoDB

```yaml
mongo:
  enabled: true
  # Container image
  image: bitnami/mongodb:7.0
  username: ed-user
  password: ed-password
  database: ed-db
```

#### API

```yaml
api:
  enabled: true
  # Container image
  imagePullSecret:
  image: igrantio/api:2025.1.1
  # Ingress
  ingress:
    enabled: false
    # Annotations for the ingress
    annotations:
      # Default annotations if ingress is nginx ingress
      # Allow HTTP false
      kubernetes.io/ingress.allow-http: "false"
      # Ingress class as NGINX
      kubernetes.io/ingress.class: nginx
      # Enable CORS
      nginx.ingress.kubernetes.io/enable-cors: "true"
      # Proxy buffer size
      nginx.ingress.kubernetes.io/proxy-buffer-size: 128k
    # Hosts
    hosts:
      - host: api.example.com
        paths:
          - path: /
            pathType: Prefix
          - path: /*
            pathType: Prefix
    # TLS
    tls:
      - hosts:
          - api.example.com
        secretName: tls-secret
  # Configuration
  configuration:
    # Database
    database:
      # Host name
      host:
    # API key secret to generate and verify API keys
    ApiSecretKey:
    # Keycloak
    Iam:
      # Keycloak URL accessible from the internet
      url:
      # Keycloak realm name
      realm:
      # Keycloak client id
      ClientId:
    # SMTP server
    Smtp:
      # SMTP username
      username:
      # SMTP password
      password:
      # SMTP host
      host:
      # SMTP port
      port: 587
      # From email
      adminEmail:
    # Webhook
    Webhooks:
      # Webhooks events enabled for subscription
      events:
        - consent.allowed
        - consent.disallowed
        - data.delete.initiated
        - data.download.initiated
        - data.update.initiated
        - data.delete.cancelled
        - data.download.cancelled
        - data.update.cancelled
    # Extensions
    Extensions:
      oidc:
        # OIDC facade config URL
        configUrl:
        # OIDC facade public URL
        publicUrl:
        # OIDC path base
        oidcPathBase: /v1/tenant/{organisationId}
        # API path base
        apiPathBase: /v3/service/extension/oidc/{organisationId}
    # NATS configuration
    Nats:
      # NATS server URL
      url: nats://nats.nats.svc.cluster.local:4222
      # Connection timeout in seconds
      timeout: 5
```

#### Enterprise Dashboard

```yaml
enterpriseDashboard:
  enabled: true
  # Container image
  imagePullSecret:
  image: igrantio/enterprise-dashboard:2025.1.1
  # Ingress
  ingress:
    enabled: false
    # Annotations for the ingress
    annotations:
      # Default annotations if ingress is nginx ingress
      # Allow HTTP false
      kubernetes.io/ingress.allow-http: "false"
      # Ingress class as NGINX
      kubernetes.io/ingress.class: nginx
      # Enable CORS
      nginx.ingress.kubernetes.io/enable-cors: "true"
      # Proxy buffer size
      nginx.ingress.kubernetes.io/proxy-buffer-size: 128k
    # Hosts
    hosts:
      - host: dashboard.example.com
        paths:
          - path: /
            pathType: Prefix
          - path: /*
            pathType: Prefix
    # TLS
    tls:
      - hosts:
          - dashboard.example.com
        secretName: tls-secret
  # Configuration
  configuration:
    # API server base URL
    baseUrl:
    # Enterprise dashboard version
    appVersion: 2025.1.1
    # Client id as mentioned in API server IAM configuration
    clientId:
```

#### Organisation Wallet

```yaml
organisationWallet:
  enabled: true
  # Container image
  imagePullSecret:
  image: igrantio/organisation-wallet:2025.1.1
  # Database name
  dbName: walletdb
  # Wallet provider base URL
  walletProviderUrl:
  # Secure vault base URL
  secureVaultUrl:
  # EBSI base URL
  ebsiBaseUrl: https://api-pilot.ebsi.eu
  # Enable wallet unit production checks
  walletUnitProductionChecksEnabled: "True"
  # NATS server URL
  natsServerUrl: nats://nats.nats.svc.cluster.local:4222
  service:
    # Ingress
    ingress:
      enabled: false
      # Annotations for the ingress
      annotations:
        # Default annotations if ingress is nginx ingress
        # Allow HTTP false
        kubernetes.io/ingress.allow-http: "false"
        # Ingress class as NGINX
        kubernetes.io/ingress.class: nginx
        # Enable CORS
        nginx.ingress.kubernetes.io/enable-cors: "true"
        # Proxy buffer size
        nginx.ingress.kubernetes.io/proxy-buffer-size: 128k
      # Hosts
      hosts:
        - host: wallet.example.com
          paths:
            - path: /
              pathType: Prefix
            - path: /*
              pathType: Prefix
      # TLS
      tls:
        - hosts:
            - wallet.example.com
          secretName: tls-secret
```

#### Vault Facade

The Vault Facade provides a simplified interface to HashiCorp Vault for secrets management.

```yaml
vaultFacade:
  enabled: false
  # Container image
  imagePullSecret:
  image: igrantio/vault-facade:2025.1.1
  # Vault server address
  vaultAddr:
  # Vault username
  vaultUser:
  # Vault password
  vaultPassword:
```

## Container Images Access

To access iGrant.io platform container images, please follow these steps:

1. Contact support@igrant.io to get permission to access the container registry. You will receive a `key.json` file.

2. Login to the container registry using the provided key:
```bash
cat key.json | docker login -u _json_key --password-stdin https://europe-docker.pkg.dev
```

Available container images:
- API: `europe-docker.pkg.dev/jenkins-189019/igrantio/api:2025.2.4-2`
- Organisation Wallet: `europe-docker.pkg.dev/jenkins-189019/igrantio/organisationwallet:2025.2.4`
- Secure Vault: `europe-docker.pkg.dev/jenkins-189019/igrantio/securevault:2025.2.4`

## Contributing

Feel free to improve the plugin and send us a pull request. If you find any problems, please create an issue in this repo.

## Licensing

Copyright (c) 2025-2035 LCubed AB (iGrant.io), Sweden

Licensed under the Apache 2.0 License, Version 2.0 (the "License"); you may not use this file except in compliance with the License.

Unless required by applicable law or agreed to in writing, software distributed under the License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the LICENSE for the specific language governing permissions and limitations under the License.