# Values reference

This page lists the main values of the chart and their defaults.

[Back to the contents](../README.md#contents)

The full list with comments is in [values.yaml](../values.yaml); [values.schema.json](../values.schema.json) checks the values (Helm refuses an unknown value or a wrong type). Each component also has `image`, `resources`, `podSecurityContext`, `containerSecurityContext`, `priorityClassName`, `nodeSelector`, `tolerations`, `affinity` and `imagePullSecrets`.

## Global and exposure

| Value | Description | Default |
| --- | --- | --- |
| `global.imageRegistry` | Registry of the iGrant.io images | `europe-docker.pkg.dev/jenkins-189019/igrantio` |
| `global.imageTag` | The release tag of the iGrant.io images (`api`, `gateway`, `consent-management-backend`, `eudi-wallet`, `dashboard`, `openbao`). Set the tag of your release | `2026.10.x` (a placeholder) |
| `global.imagePullSecrets` | Image pull Secrets of all pods | `[igrant-registry-creds]` |
| `global.storageClass` | Storage class of all volumes (`""`: the default class, `"-"`: none) | `""` |
| `global.priorityClassName`, `.podSecurityContext`, `.containerSecurityContext`, `.nodeSelector`, `.tolerations`, `.affinity`, `.labels` | Settings of all pods and objects | empty |
| `exposure.type` | `ingress`, `gatewayAPI` or `none` | `ingress` |
| `exposure.ingress.className`, `.annotations` | IngressClass and annotations of every Ingress | `""`, `{}` |
| `exposure.gatewayAPI.parentRefs`, `.annotations`, `.timeouts` | The Gateway, the annotations and the timeouts of every HTTPRoute | `[]`, `{}`, `{}` |
| `<component>.host` | Public host of `api`, `organisationWallet`, `enterpriseDashboard` (required) | `""` |
| `<component>.exposure.*` | `type`, `className`, `annotations` (added), `path`, `pathType`, `tls.secretName`, `parentRefs`, `timeouts` of one public service | empty |
| `clientAddress.header`, `.trustedProxies`, `.trustedProxyHeader` | The client address behind your proxies (rate limits, IP allow-lists) | empty |

## Database

| Value | Description | Default |
| --- | --- | --- |
| `database.engine` | `postgresql` or `mysql` | `postgresql` |
| `database.mode` | `bundled` or `external` | `bundled` |
| `database.databases.<component>.name`, `.password` | Database and owner user of `api`, `oidc`, `consent`, `wallet` | `igrant_<component>`, random |
| `database.auth.adminPassword`, `.existingSecret` | The admin password of the bundled server; an existing Secret with all passwords | random, `""` |
| `database.external.host`, `.port`, `.admin.*` | The external server and its admin user | `""` |
| `database.pools.<process>` | PostgreSQL only: the pool of `api`, `webhook`, `oidc`, `gateway`, `consent` | `10/2`, `5/1`, `5/1`, `10/2`, `6/2` |
| `database.tls.enabled`, `.existingSecret`, `.caSecret`, `.caKey`, `.sslMode` | TLS to the server | `true` |
| `database.postgresql.image`, `.parameters` | The bundled PostgreSQL | `postgres:18.6` |
| `database.mysql.image`, `.parameters` | The bundled MariaDB | `mariadb:13.0.2`, `max_connections: 1000` |
| `database.persistence.size`, `.storageClass`, `database.resources` | The volume and the resources of the bundled server | `50Gi`, 250m/1536Mi (CPU limit 2) |

## OpenBao

| Value | Description | Default |
| --- | --- | --- |
| `openbao.mode` | `bundled` or `external` | `bundled` |
| `openbao.transitMount` | Mount path of the Transit engine | `transit` |
| `openbao.wallet.user`, `.existingSecret`, `.passwordKey` | The login of the wallet (an existing Secret is required for external) | `wallet` |
| `openbao.external.address`, `.namespace`, `.caSecret`, `.caKey` | Your OpenBao | `""` |
| `openbao.seal` | `shamir` (an operator unseals each pod after each start) | `shamir` |
| `openbao.image` | The image (`openbao`, tag `global.imageTag`) | see values |
| `openbao.replicas`, `.persistence.*`, `.tls.existingSecret`, `.logLevel`, `.audit.stdout`, `.extraConfig`, `.extraEnv` | The bundled OpenBao | `3`, `10Gi` |
| `openbao.updateStrategy` | `OnDelete` or `RollingUpdate` (see [Upgrade](upgrade.md)) | `""`: `OnDelete` |

## API and gateway

| Value | Description | Default |
| --- | --- | --- |
| `api.replicas`, `api.webhook.replicas` | Replicas of the API core and the webhook handler | `1`, `1` |
| `api.keyStorage.*` | The key Secrets and the active key id (`scripts/make-keys.sh`) | see values |
| `api.serviceEnvelope.activeKid` | The key id of the NATS message key of the api | `""` |
| `api.smtp.*`, `api.twilio.*` | E-mail and SMS | empty |
| `api.adminAuth.walletLogin.organisationId` | The wallet provider organisation of the wallet login of the admins | `""` |
| `api.jobs.registerAdmin`, `.createOrganisationType`, `.createOrganisation` | The first admin and its organisation (install step 7) | off |
| `api.extraConfig` | More configuration keys of the api (no secrets) | `{}` |
| `gateway.replicas`, `.resources` | The gateway | `2`, 100m/128Mi |
| `gateway.internalToken.activeKid`, `gateway.publicKeys.*` | The gateway key and the public keys (`scripts/make-keys.sh`) | `""` |
| `gateway.upstreams.*`, `gateway.proxy.*` | The services behind the gateway and the connection limits | the Services of the chart |

## Consent, wallet and dashboard

| Value | Description | Default |
| --- | --- | --- |
| `consent.replicas` | Consent management | `2` |
| `consent.serviceEnvelope.activeKid` | The key id of the NATS message key of consent | `""` |
| `organisationWallet.storage.gcsBucket`, `.gcsProject`, `.credentials.*`, `.emulatorHost` | The file store of the wallet (bucket and project required) | `""` |
| `organisationWallet.forwardedAllowIps` | The proxies that the wallet trusts for the scheme and the client address | private ranges |
| `organisationWallet.walletUnit.productionChecksEnabled`, `.playIntegrity.*` | The checks of the wallet apps | `false` |
| `organisationWallet.trustList.*` | The trust list lookup service | the NXD Foundation service |
| `organisationWallet.serviceEnvelope.activeKid` | The key id of the NATS message key of the wallet | `""` |
| `organisationWallet.{service,config,scheduler}.replicas` | Replicas (keep the scheduler at 1) | `1` |
| `organisationWallet.keyStores.types`, `.providers.*`, `.allowPrivateAddresses` | The key store types and providers that admins may add (see [Key stores](key-stores.md)) | `[vault, csc, gcp-kms, aws-kms, azure-key-vault]` |
| `enterpriseDashboard.replicas`, `.configuration.*` | The dashboard | `1` |

## Key stores

| Value | Description | Default |
| --- | --- | --- |
| `organisationWallet.keyStores.testCa.enabled` | The built-in test CA: test certificates for development and testing, not on any trusted list (see [Key stores](key-stores.md)) | `true` |
| `organisationWallet.keyStores.testCa.leafValidityDays` | The validity in days (1 to 3650) of a test certificate when the request gives none; the largest validity of the preset caps it | `365` |

## Other

| Value | Description | Default |
| --- | --- | --- |
| `nats.enabled`, `.external.url` | The bundled NATS or yours | `true` |
| `nats.replicas`, `.reloader.enabled` | The bundled NATS | `3`, `true` |
| `nats.auth.users.<user>` | The NATS users (`scripts/make-keys.sh`) | `""` |
| `serviceKeys.publicJwks.*` | The public keys of the NATS messages (`scripts/make-keys.sh`) | `""` |
| `readAccess.*` | The read-only users (see [Read access](read-access.md)) | see values |
| `networkPolicy.*` | See [Network policies](network-policies.md) | off |
| `privacyDashboard.enabled`, `.namespace` | See [Privacy dashboard](privacy-dashboard.md) | `false`, `""` |
