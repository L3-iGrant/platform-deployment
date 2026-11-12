# Values reference

This page lists the main values of the chart and their defaults.

[Back to the contents](../README.md#contents)

The full list with comments is in [values.yaml](../values.yaml); [values.schema.json](../values.schema.json) checks the values (Helm refuses an unknown value or a wrong type). Each component also has `image`, `resources`, `podSecurityContext`, `containerSecurityContext`, `priorityClassName`, `nodeSelector`, `tolerations`, `affinity` and `imagePullSecrets`.

## Global and exposure

| Value | Description | Default |
| --- | --- | --- |
| `nameOverride` | The value of the label `app.kubernetes.io/name`, which is also in the selectors. A release that was installed from the chart `organisationwallet` sets `organisationwallet`: see [Upgrade](upgrade.md#the-chart-name-platform) | `""` (the chart name `platform`) |
| `global.imageRegistry` | Registry of the iGrant.io images | `europe-docker.pkg.dev/jenkins-189019/igrantio` |
| `global.imageTag` | The release tag of the iGrant.io images (`api`, `gateway`, `consent-management-backend`, `eudi-wallet`, `dashboard`, `openbao`). Set the tag of your release | `2026.10.x` (a placeholder) |
| `global.imagePullSecrets` | Image pull Secrets of all pods | `[igrant-registry-creds]` |
| `global.storageClass` | Storage class of all volumes (`""`: the default class, `"-"`: none) | `""` |
| `global.priorityClassName`, `.podSecurityContext`, `.containerSecurityContext`, `.nodeSelector`, `.tolerations`, `.affinity`, `.labels` | Settings of all pods and objects. `global.podSecurityContext` and `.containerSecurityContext` apply only to a component whose own value is empty | empty |
| `<component>.podSecurityContext`, `.containerSecurityContext` | The security settings of the pods and the containers of `database` (the bundled server and the init hook), `nats`, `redis`, `api`, `gateway`, `consent`, `openbao`, `organisationWallet` and `enterpriseDashboard`; the hooks and Jobs have `api.jobs.*`, `consent.jobs.*` and `organisationWallet.jobs.*`. Each default: a non-root user with a fixed UID and GID, `fsGroup` for the Secret files, `allowPrivilegeEscalation: false`, `readOnlyRootFilesystem: true`, `capabilities.drop: [ALL]`, seccomp `RuntimeDefault`, and for the api, consent and the dashboard (port 80) the sysctl `net.ipv4.ip_unprivileged_port_start=0`. Helm merges your keys into the default; `null` removes a key (see [Security settings of the containers](security-context.md)) | api, gateway, consent, wallet `65532`; dashboard `101`; PostgreSQL `999`; NATS `1000`; OpenBao `10001`; Valkey `999:1000` |
| `exposure.type` | `ingress`, `gatewayAPI` or `none` | `ingress` |
| `exposure.ingress.className`, `.annotations` | IngressClass and annotations of every Ingress | `""`, `{}` |
| `exposure.gatewayAPI.parentRefs`, `.annotations`, `.timeouts` | The Gateway, the annotations and the timeouts of every HTTPRoute | `[]`, `{}`, `{}` |
| `<component>.host` | Host of `api`, `organisationWallet`, `enterpriseDashboard` (required; on premise only the wallet host is public, see [Exposure](exposure.md#on-premise-installation)) | `""` |
| `<component>.exposure.*` | `type`, `className`, `annotations` (added), `path`, `pathType`, `tls.secretName`, `parentRefs`, `timeouts` of one host | empty |
| `clientAddress.header`, `.trustedProxies`, `.trustedProxyHeader` | The client address behind your proxies (rate limits, IP allow-lists) | empty |

## Database

| Value | Description | Default |
| --- | --- | --- |
| `database.engine` | `postgresql` (the only supported engine) | `postgresql` |
| `database.mode` | `bundled` or `external` | `bundled` |
| `database.databases.<component>.name`, `.password` | Database and owner user of `api`, `oidc`, `consent`, `wallet`. The wallet name is also the prefix of the database roles of the wallet (at most 43 characters, see [Database](database.md#database-roles-of-the-wallet)) | `igrant_<component>`, random |
| `database.auth.adminPassword`, `.existingSecret` | The admin password of the bundled server; an existing Secret with all passwords | random, `""` |
| `database.external.host`, `.port`, `.admin.*` | The external server and its admin user (the admin user is required with the organisation wallet) | `""` |
| `database.pools.<process>` | The pool of `api`, `webhook`, `oidc`, `gateway`, `consent` (`maxConns`/`minConns`) | `10/2`, `5/1`, `5/1`, `10/2`, `6/2` |
| `database.pooler.host`, `.port`, `.serverConnections` | A connection pooler in transaction mode for the organisation wallet, and its connections to the server (see [Database](database.md#connection-pooler)) | `""` (none), `6432`, `0` |
| `database.pools.apiReadAccess` | The reader of the wallet views of the api core and of the webhook handler | `5/1` |
| `database.pools.walletService`, `.walletConfig` | The pools of one process of the wallet service and config roles: `poolSize`, `maxOverflow`, `allocationPoolSize` (see [Database](database.md#connection-budget)) | `12`, `4`, `5`; `8`, `4`, `2` |
| `database.pools.walletWorker` | A worker process: one session connection for each thread of its group, `maxOverflow` more, and `allocationPoolSize` | `2`, `2` |
| `database.tls.enabled`, `.existingSecret`, `.caSecret`, `.caKey`, `.sslMode` | TLS to the server | `true` |
| `database.postgresql.image`, `.parameters` | The bundled PostgreSQL | `postgres:18.6` |
| `database.postgresql.logDdlAndConnections` | The bundled server logs each DDL statement, connection and disconnection (see [Database](database.md#logs-of-the-database-server)) | `true` |
| `database.persistence.size`, `.storageClass`, `database.resources` | The volume and the resources of the bundled server | `50Gi`, 250m/2048Mi (CPU limit 2) |

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

## Redis

| Value | Description | Default |
| --- | --- | --- |
| `redis.mode` | `bundled` (Valkey with Sentinel) or `external` (your Valkey or Redis; see [Redis](redis.md)) | `bundled` |
| `redis.masterName` | The name of the primary that the Sentinels monitor | `ows` |
| `redis.users.<process>.username`, `.passwordSecret`, `.passwordKey` | The ACL user of `walletService`, `walletConfig`, `walletWorker`, `walletClock` and `gateway`, and an existing Secret with its password (required for external) | `wallet-service`, ..., `gateway`; the Secret of the chart |
| `redis.client.connectTimeoutSeconds`, `.timeoutSeconds`, `.replicaWaitMilliseconds` | The timeouts of the wallet and its wait for a replica of a single-use value | `2`, `2`, `100` |
| `redis.external.sentinels` or `.address`, `.sentinelAuth`, `.caSecret`, `.caKey` | Your Valkey or Redis | `[]`, `""`, `true`, `""` |
| `redis.state.*`, `redis.cache.*` (`enabled`, `sentinels` or `address`, `masterName`, `sentinelAuth`, `caSecret`, `caKey`) | A separate group of your own Valkey or Redis for the single-use values or for the caches of the wallet (see [Redis](redis.md#separate-groups-for-the-single-use-values-and-the-caches)) | off |
| `redis.metrics.enabled`, `.image`, `.resources`, `.serviceMonitor.*` | The exporter of each Valkey pod and its ServiceMonitor (see [Redis](redis.md#metrics)) | off; `oliver006/redis_exporter:v1.94.0` (with its digest), 10m/32Mi (limit 128Mi) |
| `redis.image` | The Valkey image | `valkey/valkey:8.1.10-alpine` (with its digest) |
| `redis.replicas`, `.sentinel.quorum`, `.sentinel.downAfterMilliseconds`, `.sentinel.failoverTimeoutMilliseconds` | The pods (odd, 3 or more) and the Sentinels | `3`, `2`, `5000`, `60000` |
| `redis.maxmemory`, `.persistence.*`, `.resources`, `.sentinel.resources` | The memory for the data, the volume and the resources of each pod | `512mb`, `8Gi`, 100m/256Mi (limit 1Gi) |
| `redis.tls.existingSecret` | Your certificate of the bundled Valkey | `""`: the chart makes one |
| `redis.affinity` | For example a pod anti-affinity on the host name (see [Redis](redis.md#bundled-valkey)) | `{}` |

## API and gateway

| Value | Description | Default |
| --- | --- | --- |
| `api.replicas`, `api.webhook.replicas` | Replicas of the API core and the webhook handler | `1`, `1` |
| `api.keyStorage.*` | The key Secrets and the active key id (`scripts/make-keys.sh`) | see values |
| `api.serviceEnvelope.activeKid` | The key id of the NATS message key of the api | `""` |
| `api.smtp.*`, `api.twilio.*` | E-mail and SMS | empty |
| `api.adminAuth.walletLogin.organisationId` | The organisation whose OpenID provider the admins use for the wallet login. Empty: the platform operator organisation of the installation, when it is the wallet provider and its OIDC extension is on; without such an organisation, the admins have no wallet login | `""` |
| `api.jobs.bootstrapPlatform.enabled`, `.adminEmail`, `.adminName`, `.organisationName`, `.type`, `.location`, `.policyUrl` | A new installation: the Job that makes the platform operator organisation and its first platform admin (`igrant-api onboard bootstrap-platform`; it also makes the organisation type). All are required when enabled. See [Install](install.md#step-7-the-platform-operator-organisation-and-the-first-platform-admin) | off, `""` |
| `api.jobs.bootstrapPlatform.passwordSecret`, `.passwordKey` | The existing Secret and its key with the first password of the platform admin: 15 characters or more (the other accounts: 12) and at least one special character. The Job mounts it as a file. The chart and its schema cannot check a password in a Secret: the Job fails when the API refuses it. The admin sets a new password at the first login | `""`, `password` |
| `api.jobs.platformOperator.enabled`, `.organisationId`, `.adminEmail` | An installation that exists: the Job that gives an organisation the platform operator mark (`igrant-api platform set-operator`), then gives one of its admins the platform admin right (`igrant-api platform grant-admin`). The organisation must be the wallet provider or have no wallet. See [Upgrade](upgrade.md#the-platform-operator) | off, `""` |
| `api.jobs.registerAdmin`, `.createOrganisationType`, `.createOrganisation` | The Jobs of the earlier releases: an admin (a password of 12 characters or more, with at least one special character) and its organisation, without the platform operator mark. They stay for the values files that use them. The render stops when `bootstrapPlatform` is enabled with `registerAdmin` or `createOrganisation` | off |
| `api.limits.maxOrganisations` | The most organisations of the installation (`Limits.maxOrganisations` of the api and webhook files, 1 to 100). The create of one more organisation gets `409` `organisation_limit_reached`; the organisations that exist stay. Empty: the chart writes no key, and the api uses its default. Set a value only with the images of the release with the input limits (see [Upgrade](upgrade.md#the-limits-of-the-installation)) | `""` (the api uses 100) |
| `api.webhooks.deliveryRetentionDays` | Days that the api keeps the webhook delivery records. The effective features of each organisation select its webhook event types: the chart has no list of event types. `api.webhooks.events` is not used: the schema accepts it for one release, and the notes tell you to remove it (see [Upgrade](upgrade.md#the-webhook-event-types)) | `10` |
| `api.extraConfig` | More configuration keys of the api (no secrets). Not `Installation`: the chart writes it (see [Components](components.md#the-services-of-the-installation)) | `{}` |
| `gateway.replicas`, `.resources` | The gateway | `2`, 100m/128Mi |
| `gateway.internalToken.activeKid`, `gateway.publicKeys.*` | The gateway key and the public keys (`scripts/make-keys.sh`) | `""` |
| `gateway.features.enforce` | The feature gate (`Features.enforce` of the gateway file): `true`, the gateway refuses a route of a product feature that is off for the organisation of the credential (`403`, `feature_disabled`); `false`, it refuses no route for a feature (an emergency, or the first upgrade of an installation that exists: see [Upgrade](upgrade.md#the-feature-gate)) | `true` (the default of the gateway) |
| `gateway.upstreams.*`, `gateway.proxy.*` | The services behind the gateway and the connection limits. `gateway.upstreams.consent.url` and `.walletConfig.url`: the consent service and the wallet config role of another release (with `consent.enabled: false` or `organisationWallet.enabled: false`). Without the URL, a service that this release does not run is not installed (see [Components](components.md#the-services-of-the-installation)) | the Services of the chart |

## Consent, wallet and dashboard

| Value | Description | Default |
| --- | --- | --- |
| `consent.enabled` | Run consent management in this release. `false` with `gateway.upstreams.consent.url`: the consent service of another release. `false` without the URL: the installation has no consent (see [Components](components.md#the-services-of-the-installation)) | `true` |
| `consent.replicas` | Consent management | `2` |
| `consent.serviceEnvelope.activeKid` | The key id of the NATS message key of consent | `""` |
| `organisationWallet.enabled` | Run the organisation wallet in this release. `false` with `gateway.upstreams.walletConfig.url`: the wallet of another release. `false` without the URL: the installation has no wallet, and `organisationWallet.host` is not required (see [Components](components.md#the-services-of-the-installation)) | `true` |
| `organisationWallet.audit.retentionYears`, `.scopeRetentionYears` | The audit log of the wallet (see [Audit log](audit-log.md)) | `7`, `{}` |
| `organisationWallet.audit.bucket.*` | The write-once bucket of the audit anchors and exports (see [Audit log](audit-log.md#audit-bucket)) | no bucket |
| `organisationWallet.retention.*` | The retention purge of the wallet data (see [Audit log](audit-log.md#retention-purge)) | 30 days, sandboxes 7 days |
| `organisationWallet.forwardedAllowIps` | The proxies that the wallet trusts for the scheme and the client address | private ranges |
| `organisationWallet.server.nonceRequestsPerMinute` | The nonce requests of one client address (an IPv6 /64 network) in 60 s at the anonymous nonce routes of the wallet; more get 429 (see [Exposure](exposure.md)) | `300` |
| `organisationWallet.walletUnit.productionChecksEnabled` | The device checks of the wallet apps (App Attest and Play Integrity) | `false` |
| `organisationWallet.walletUnit.playIntegrity.existingSecret`, `.decryptionKeyKey`, `.verificationKeyKey` | The Secret with the decryption key and the verification key of the Play Console; only the service pods mount them | no Secret; `decryption-key`, `verification-key` |
| `organisationWallet.walletUnit.androidSigningCertificateDigests` | The SHA-256 of the app signing key certificate of the Android app: the Play Integrity check (required with the Secret), the device key of the registration and the key attestations | `[]` |
| `organisationWallet.walletUnit.playIntegrity.packageName`, `.minVersionCode` | The package and the lowest version code of the Android app | `io.igrant.mobileagent`, `0` |
| `organisationWallet.walletUnit.appAttest.appIds` | The App IDs (`<Team ID>.<bundle id>`) of the iOS wallet apps of the installation: the App Attest attestation of the registration of a wallet unit, its assertions and the App Attest objects of a key attestation must be for one of them. Only the service pods get them. At least one is required with the production checks | `[Y9726WB7V8.io.iGrant.DataWallet]` |
| `organisationWallet.walletUnit.trustAnchors.existingConfigMap` | A ConfigMap with the device roots of the wallet units (`google_hardware_attestation_root.pem`, `apple_app_attestation_root_ca.pem`); the service, config and worker pods mount it as `wallet_unit.trust_anchors_dir` | `""` (the roots of the image) |
| `organisationWallet.walletUnit.organisationWalletUnitsMax` | The most organisation wallet units of the wallet provider of the installation (`wallet_unit.organisation_wallet_units_max` of the service, config and worker files, 1 to 100). The create of one more organisation wallet (a new organisation) gets `409` `organisation_wallet_unit.limit_reached`; the units that exist stay. Empty: the chart writes no key, and the wallet uses its default. Set a value only with the images of the release with the input limits (see [Upgrade](upgrade.md#the-limits-of-the-installation)) | `""` (the wallet uses 100) |
| `organisationWallet.trustList.euLotlUrl` | The EU list of trusted lists: the wallet reads it (and the trusted list of the country of the provider) to show whether the key of a qualified trust service provider is qualified. Empty: no check | `https://ec.europa.eu/tools/lotl/eu-lotl.xml` |
| `organisationWallet.trustSources.refreshMaxIntervalSeconds`, `.refreshMinIntervalSeconds`, `.retryIntervalSeconds`, `.staleGraceSeconds`, `.manualRefreshMinIntervalSeconds` | The refresh of the list trust sources that the organisations add: the longest and the shortest time between two scheduled downloads of a list, the wait after a failed download, how long after its next update the last good copy of a list is still in use (after it, the checks of its roles give error), and the shortest time between two Refresh now of one source. The organisations have no interval setting | `86400`, `3600`, `900`, `259200`, `300` |
| `organisationWallet.serviceEnvelope.activeKid` | The key id of the NATS message key of the wallet | `""` |
| `organisationWallet.nats.commandReplySeconds` | How long the config role keeps the reply of a NATS command of the api for a retry (120 to 3600; the same for all config pods) | `300` |
| `organisationWallet.{service,config}.replicas` | Replicas of the service and config roles | `1` |
| `organisationWallet.workers.groups` | The worker groups: name, queues, replicas, processes, threads, `shutdownTimeoutSeconds`, `terminationGracePeriodSeconds`, resources, `tmp` (see [Workers and clock](workers.md)) | `main` (`realtime`, `attestation`, `status`, `kms`), `maintenance` |
| `organisationWallet.workers.tmp.sizeLimit`, `.volume.enabled`, `.volume.storageClass` | The `/tmp` folder of each worker pod, on disk: the monthly audit export writes one month of one data scope two times to it. An `emptyDir` of `sizeLimit`, or a generic ephemeral volume of that size. A group can override the keys with its own `tmp` (see [Workers and clock](workers.md#the-tmp-folder-of-the-workers)) | `10Gi`, `false`, `""` |
| `organisationWallet.statusList.writeIntervalSeconds` | The workers write the queued revocations of each issuer status list at most once in this time (0 to 50; 0: at each run of the actor, every 5 seconds). A revocation is in the published list within 60 seconds (see [Workers and clock](workers.md#status-list-writes)) | `30` |
| `organisationWallet.clock.replicas`, `.resources` | The clock (only the leader sends) | `2` |
| `organisationWallet.serviceMonitor.enabled`, `.interval`, `.labels` | A ServiceMonitor of `/metrics` of the servers (port 9190), the workers and the clock | off, `15s` |
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
| `nats.tls.existingSecret` | The certificate of the bundled NATS (TLS of the clients and mutual TLS of the routes, always on). Empty: the chart makes it (see [NATS users](nats-users.md#tls)) | `""` |
| `nats.tlsCa.*` | The CA of an external NATS with TLS | `""` |
| `nats.auth.users.<user>` | The NATS users (`scripts/make-keys.sh`) | `""` |
| `serviceKeys.publicJwks.*` | The public keys of the NATS messages (`scripts/make-keys.sh`) | `""` |
| `readAccess.*` | The read-only users (see [Read access](read-access.md)) | see values |
| `networkPolicy.*` | See [Network policies](network-policies.md) (`networkPolicy.externalRedis` for your Valkey or Redis) | off |
| `privacyDashboard.enabled`, `.namespace` | See [Privacy dashboard](privacy-dashboard.md). Needs consent: without consent, `true` stops the render | `false`, `""` |
