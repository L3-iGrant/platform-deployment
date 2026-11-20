# Upgrade

How to upgrade an installation to a new release of the chart, and the values that changed in each release.

[Back to the contents](../README.md#contents)

## The steps

1. Read the section of each release after the release of your installation (below).
2. Run `scripts/upgrade-values.py` on each values file of your installation (each `-f` of your `helm` commands). It needs Python 3.9 or later and PyYAML. It writes the new values file, and on the terminal a report:

   ```bash
   python3 ./platform-deployment/scripts/upgrade-values.py my-site.yaml > my-site.new.yaml
   ```

   The report lists each change, and each action for you (`ACTION`), for example a Secret to make. The exit code is 1 when the report has an action. The new file has no comments: compare it with your old file, then use the new file.
3. Render the release with the new files and compare the result with the installed release, for example with `helm template` and `kubectl diff`, or with the helm-diff plugin.
4. Run `helm upgrade` with the same files.

## When a values file has an old value

The render (`helm template`, `helm install`, `helm upgrade`, `helm lint`) stops when a values file has a value that changed. One message names all old values of your files, each with its new value or what to do, for example:

```text
Error: execution error at (platform/templates/zz-first/renamed-values.yaml:8:4): 2 values of your values files changed after release 2026.11.7 (docs/upgrade.md, section "From 2026.11.7"):
- api.keyStorage.tokenSigning.activeKid: use keys.apiTokenSigning.activeKid
- gateway.internalToken.issuer: remove it (the chart writes the constant igrant-gateway)
Run scripts/upgrade-values.py <your values file> to write the new file, or change the values by hand.
```

The chart never reads an old value in place of the new value. The message stays for two releases after the change. After that, the chart refuses the old value as an unknown value, with a general message of the schema.

<!-- The sections below: tests/upgrade_page.py --write (from files/renamed-values.yaml). -->

## From 2026.11.7

The values that changed after release 2026.11.7. `scripts/upgrade-values.py` does each change of these tables, except the actions in the report.

### The keys block

All key ids, key Secrets and public JWKS are in one block, `keys`, and `scripts/make-keys.sh` writes it (see [Keys](keys.md)). The public JWKS of all services can come from one ConfigMap of yours. The lifetime and the clock skew of the signed NATS messages and of the internal token, and the issuer and audiences of the internal token, are constants.

| Old value | New value, or what to do |
| --- | --- |
| `api.keyStorage.tokenSigning.activeKid` | `keys.apiTokenSigning.activeKid` |
| `api.keyStorage.tokenSigning.existingSecret` | `keys.apiTokenSigning.existingSecret` |
| `api.keyStorage.tokenSigning.key` | `keys.apiTokenSigning.key` |
| `api.keyStorage.tokenHash.existingSecret` | `keys.apiTokenHash.existingSecret` |
| `api.keyStorage.tokenHash.key` | `keys.apiTokenHash.key` |
| `api.keyStorage.dbWrapping.existingSecret` | `keys.apiDatabaseWrapping.existingSecret` |
| `api.keyStorage.dbWrapping.key` | `keys.apiDatabaseWrapping.key` |
| `api.existingSecret` | `keys.apiHmacKey.existingSecret` |
| `api.apiSecretKey` | Remove it: a plain secret in a values file is not permitted; the chart keeps the key of its Secret `<fullname>-api` at an upgrade. For a key of your own, make a Secret and set `keys.apiHmacKey.existingSecret` |
| `api.serviceEnvelope.activeKid` | `keys.serviceEnvelope.api.activeKid` |
| `api.serviceEnvelope.signingKey.existingSecret` | `keys.serviceEnvelope.api.existingSecret` |
| `api.serviceEnvelope.signingKey.key` | `keys.serviceEnvelope.api.key` |
| `api.serviceEnvelope.lifetimeSeconds` | Remove it: a constant of the protocol: the chart writes 60 for all services |
| `api.serviceEnvelope.clockSkewSeconds` | Remove it: a constant of the protocol: the chart writes 60 for all services |
| `organisationWallet.serviceEnvelope.activeKid` | `keys.serviceEnvelope.organisationWallet.activeKid` |
| `organisationWallet.serviceEnvelope.signingKey.existingSecret` | `keys.serviceEnvelope.organisationWallet.existingSecret` |
| `organisationWallet.serviceEnvelope.signingKey.key` | `keys.serviceEnvelope.organisationWallet.key` |
| `organisationWallet.serviceEnvelope.lifetimeSeconds` | Remove it: a constant of the protocol: the chart writes 60 for all services |
| `organisationWallet.serviceEnvelope.clockSkewSeconds` | Remove it: a constant of the protocol: the chart writes 60 for all services |
| `organisationWallet.internalAuth.clockSkewSeconds` | Remove it: a constant of the protocol: the chart writes 60 |
| `gateway.internalToken.activeKid` | `keys.gatewayInternalToken.activeKid` |
| `gateway.internalToken.signingKey.existingSecret` | `keys.gatewayInternalToken.existingSecret` |
| `gateway.internalToken.signingKey.key` | `keys.gatewayInternalToken.key` |
| `gateway.internalToken.issuer` | Remove it: the chart writes the constant igrant-gateway |
| `gateway.internalToken.audiences` | Remove it: the chart writes the constants igrant-api-core and wallet-config |
| `gateway.publicKeys.gatewayJwks` | `keys.publicJwks.gatewayInternalToken` |
| `gateway.publicKeys.tokenVerificationJwks` | `keys.publicJwks.apiTokenVerification` |
| `gateway.publicKeys.gatewayJwksKey` | Remove it: the key in the ConfigMap is always gateway-jwks.json |
| `gateway.publicKeys.tokenVerificationJwksKey` | Remove it: the key in the ConfigMap is always token-verification-jwks.json |
| `gateway.publicKeys.existingConfigMap` | `keys.publicJwks.existingConfigMap` (one ConfigMap with gateway-jwks.json, token-verification-jwks.json, igrant-api.json and eudi-wallet.json) |
| `gateway.publicKeys.existingTokenVerificationConfigMap` | `keys.publicJwks.existingConfigMap` (one ConfigMap with gateway-jwks.json, token-verification-jwks.json, igrant-api.json and eudi-wallet.json) |
| `serviceKeys.existingConfigMap` | `keys.publicJwks.existingConfigMap` (one ConfigMap with gateway-jwks.json, token-verification-jwks.json, igrant-api.json and eudi-wallet.json) |
| `serviceKeys.publicJwks.igrant-api` | `keys.serviceEnvelope.api.publicJwks` |
| `serviceKeys.publicJwks.eudi-wallet` | `keys.serviceEnvelope.organisationWallet.publicJwks` |

### E-mail and SMS of the api

A secret is never a value: each secret is a reference to a Secret, `{existingSecret, key}`. A plain password, account SID or auth token in a values file stops the render: make a Secret first. The sender address of the e-mails is `api.smtp.from`.

| Old value | New value, or what to do |
| --- | --- |
| `api.smtp.password` (a text) | Make a Secret with the SMTP password and set `api.smtp.password.existingSecret` (and `api.smtp.password.key`; the default key is smtp-password) |
| `api.smtp.existingSecret` | `api.smtp.password.existingSecret` |
| `api.smtp.passwordKey` | `api.smtp.password.key` |
| `api.smtp.adminEmail` | `api.smtp.from` |
| `api.twilio.accountSid` (a text) | Make a Secret with the account SID and set `api.twilio.accountSid.existingSecret` (and .key; the default key is twilio-account-sid) |
| `api.twilio.authToken` (a text) | Make a Secret with the auth token and set `api.twilio.authToken.existingSecret` (and .key; the default key is twilio-auth-token) |
| `api.twilio.existingSecret` | `api.twilio.accountSid.existingSecret` and `api.twilio.authToken.existingSecret` |
| `api.twilio.accountSidKey` | `api.twilio.accountSid.key` |
| `api.twilio.authTokenKey` | `api.twilio.authToken.key` |

### Database

One admin block for both modes (`database.admin`; the bundled server has the user `postgres`), one Secret reference for each database password, and the CA of an external server in `database.external.ca`. A plain password in a values file stops the render. At an upgrade, the chart keeps the passwords of its Secret `<fullname>-postgres`. The read-only users are in `database.readAccess` (see [Read access](read-access.md)).

| Old value | New value, or what to do |
| --- | --- |
| `database.databases.api.password` (a text) | Remove it: a plain password in a values file is not permitted; the chart keeps the password of its Secret `<fullname>-postgres` at an upgrade. For a password of your own, make a Secret and set `database.databases.api.password.existingSecret` |
| `database.databases.oidc.password` (a text) | Remove it: a plain password in a values file is not permitted; the chart keeps the password of its Secret `<fullname>-postgres` at an upgrade. For a password of your own, make a Secret and set `database.databases.oidc.password.existingSecret` |
| `database.databases.wallet.password` (a text) | Remove it: a plain password in a values file is not permitted; the chart keeps the password of its Secret `<fullname>-postgres` at an upgrade. For a password of your own, make a Secret and set `database.databases.wallet.password.existingSecret` |
| `database.auth.adminPassword` | Remove it: a plain password in a values file is not permitted; the chart keeps the password of its Secret `<fullname>-postgres` at an upgrade. For a password of your own, make a Secret and set `database.admin.password.existingSecret` |
| `database.auth.existingSecret` | `database.databases.api.password.existingSecret` and `database.databases.oidc.password.existingSecret` and `database.databases.wallet.password.existingSecret` and `database.admin.password.existingSecret` (the key of each database is its name; for the bundled server, the admin password has the key POSTGRES_PASSWORD) |
| `database.external.admin.user` | `database.admin.username` |
| `database.external.admin.passwordSecret` | `database.admin.password.existingSecret` |
| `database.external.admin.passwordKey` | `database.admin.password.key` |
| `database.tls.caSecret` | `database.external.ca.existingSecret` |
| `database.tls.caKey` | `database.external.ca.key` |
| `readAccess.api.wallet.username` | `database.readAccess.api.wallet.username` |
| `readAccess.api.wallet.passwordSecret` | `database.readAccess.api.wallet.password.existingSecret` |
| `readAccess.api.wallet.passwordKey` | `database.readAccess.api.wallet.password.key` |
| `readAccess.api.wallet.host` | `database.readAccess.api.wallet.host` |
| `readAccess.api.wallet.port` | `database.readAccess.api.wallet.port` |
| `readAccess.api.wallet.name` | `database.readAccess.api.wallet.name` |
| `readAccess.wallet.api.username` | `database.readAccess.wallet.api.username` |
| `readAccess.wallet.api.passwordSecret` | `database.readAccess.wallet.api.password.existingSecret` |
| `readAccess.wallet.api.passwordKey` | `database.readAccess.wallet.api.password.key` |
| `readAccess.wallet.api.host` | `database.readAccess.wallet.api.host` |
| `readAccess.wallet.api.port` | `database.readAccess.wallet.api.port` |
| `readAccess.wallet.api.name` | `database.readAccess.wallet.api.name` |
| `readAccess.jobs.enabled` | `database.readAccess.jobs.enabled` |
| `readAccess.jobs.api.adminUser` | `database.readAccess.jobs.api.adminUser` |
| `readAccess.jobs.api.adminPasswordSecret` | `database.readAccess.jobs.api.adminPasswordSecret` |
| `readAccess.jobs.api.adminPasswordKey` | `database.readAccess.jobs.api.adminPasswordKey` |
| `readAccess.jobs.wallet.adminUser` | `database.readAccess.jobs.wallet.adminUser` |
| `readAccess.jobs.wallet.adminPasswordSecret` | `database.readAccess.jobs.wallet.adminPasswordSecret` |
| `readAccess.jobs.wallet.adminPasswordKey` | `database.readAccess.jobs.wallet.adminPasswordKey` |
| `readAccess.jobs.ttlSecondsAfterFinished` | `database.readAccess.jobs.ttlSecondsAfterFinished` |

### NATS

NATS has `mode: bundled | external`, as the database, OpenBao and Redis. The CA of an external NATS is `nats.external.ca`. The users are `nats.users.<process>`, with the seed as a Secret reference; the user of the webhook handler is `webhook`. `scripts/make-keys.sh` writes the new block.

| Old value | New value, or what to do |
| --- | --- |
| `nats.enabled` (true or false) | `nats.mode` (`true`: `bundled`, `false`: `external`) |
| `nats.tlsCa.existingSecret` | `nats.external.ca.existingSecret` |
| `nats.tlsCa.key` | `nats.external.ca.key` |
| `nats.auth.users.api.nkey` | `nats.users.api.nkey` |
| `nats.auth.users.api.seedSecret` | `nats.users.api.seed.existingSecret` |
| `nats.auth.users.api.seedKey` | `nats.users.api.seed.key` |
| `nats.auth.users.apiWebhook.nkey` | `nats.users.webhook.nkey` |
| `nats.auth.users.apiWebhook.seedSecret` | `nats.users.webhook.seed.existingSecret` |
| `nats.auth.users.apiWebhook.seedKey` | `nats.users.webhook.seed.key` |
| `nats.auth.users.walletConfig.nkey` | `nats.users.walletConfig.nkey` |
| `nats.auth.users.walletConfig.seedSecret` | `nats.users.walletConfig.seed.existingSecret` |
| `nats.auth.users.walletConfig.seedKey` | `nats.users.walletConfig.seed.key` |
| `nats.auth.users.walletService.nkey` | `nats.users.walletService.nkey` |
| `nats.auth.users.walletService.seedSecret` | `nats.users.walletService.seed.existingSecret` |
| `nats.auth.users.walletService.seedKey` | `nats.users.walletService.seed.key` |
| `nats.auth.users.walletWorker.nkey` | `nats.users.walletWorker.nkey` |
| `nats.auth.users.walletWorker.seedSecret` | `nats.users.walletWorker.seed.existingSecret` |
| `nats.auth.users.walletWorker.seedKey` | `nats.users.walletWorker.seed.key` |

### OpenBao, Redis and the audit bucket

The same Secret reference `{existingSecret, key}` for the password of the OpenBao user of the wallet, for each Redis user, for the CA of an external OpenBao or Redis (`external.ca`), and for the two parts of the access key of the audit bucket.

| Old value | New value, or what to do |
| --- | --- |
| `openbao.wallet.existingSecret` | `openbao.wallet.password.existingSecret` |
| `openbao.wallet.passwordKey` | `openbao.wallet.password.key` |
| `openbao.external.caSecret` | `openbao.external.ca.existingSecret` |
| `openbao.external.caKey` | `openbao.external.ca.key` |
| `redis.users.walletService.passwordSecret` | `redis.users.walletService.password.existingSecret` |
| `redis.users.walletService.passwordKey` | `redis.users.walletService.password.key` |
| `redis.users.walletConfig.passwordSecret` | `redis.users.walletConfig.password.existingSecret` |
| `redis.users.walletConfig.passwordKey` | `redis.users.walletConfig.password.key` |
| `redis.users.walletWorker.passwordSecret` | `redis.users.walletWorker.password.existingSecret` |
| `redis.users.walletWorker.passwordKey` | `redis.users.walletWorker.password.key` |
| `redis.users.walletClock.passwordSecret` | `redis.users.walletClock.password.existingSecret` |
| `redis.users.walletClock.passwordKey` | `redis.users.walletClock.password.key` |
| `redis.users.gateway.passwordSecret` | `redis.users.gateway.password.existingSecret` |
| `redis.users.gateway.passwordKey` | `redis.users.gateway.password.key` |
| `redis.external.caSecret` | `redis.external.ca.existingSecret` |
| `redis.external.caKey` | `redis.external.ca.key` |
| `organisationWallet.audit.bucket.accessKey.existingSecret` | `organisationWallet.audit.bucket.accessKeyId.existingSecret` and `organisationWallet.audit.bucket.secretAccessKey.existingSecret` |
| `organisationWallet.audit.bucket.accessKey.idKey` | `organisationWallet.audit.bucket.accessKeyId.key` |
| `organisationWallet.audit.bucket.accessKey.secretKey` | `organisationWallet.audit.bucket.secretAccessKey.key` |

### The platform operator Job

The Job that makes the platform operator organisation and its first platform admin is `api.jobs.provisionPlatformOperator` (the words of the glossary), with the groups `organisation` and `firstAdmin`, and the first password as a Secret reference (see [Install](install.md#step-7-the-platform-operator-organisation-and-the-first-platform-admin)).

| Old value | New value, or what to do |
| --- | --- |
| `api.jobs.bootstrapPlatform.enabled` | `api.jobs.provisionPlatformOperator.enabled` |
| `api.jobs.bootstrapPlatform.organisationName` | `api.jobs.provisionPlatformOperator.organisation.name` |
| `api.jobs.bootstrapPlatform.type` | `api.jobs.provisionPlatformOperator.organisation.type` |
| `api.jobs.bootstrapPlatform.location` | `api.jobs.provisionPlatformOperator.organisation.location` |
| `api.jobs.bootstrapPlatform.policyUrl` | `api.jobs.provisionPlatformOperator.organisation.policyUrl` |
| `api.jobs.bootstrapPlatform.adminEmail` | `api.jobs.provisionPlatformOperator.firstAdmin.email` |
| `api.jobs.bootstrapPlatform.adminName` | `api.jobs.provisionPlatformOperator.firstAdmin.name` |
| `api.jobs.bootstrapPlatform.passwordSecret` | `api.jobs.provisionPlatformOperator.firstAdmin.password.existingSecret` |
| `api.jobs.bootstrapPlatform.passwordKey` | `api.jobs.provisionPlatformOperator.firstAdmin.password.key` |

### Values that an operator seldom changes

Each component has a group `advanced` for the values that an operator seldom changes (change them only with iGrant.io support). In this release, the extra configuration keys go there.

| Old value | New value, or what to do |
| --- | --- |
| `api.extraConfig` | `api.advanced.extraConfig` |
| `gateway.extraConfig` | `gateway.advanced.extraConfig` |
| `organisationWallet.extraConfig` | `organisationWallet.advanced.extraConfig` |

### Values that the chart knows

A constant of a protocol, a fact of an image or a value that the chart can calculate is not a value. The chart calculates the grace period of the pods from their stop times (`terminationGracePeriodSeconds`), and writes the public URLs of the dashboard file and of the api from the host names. The database of all components is always PostgreSQL, so `database.engine` is not a value.

| Old value | New value, or what to do |
| --- | --- |
| `api.server.terminationGracePeriodSeconds` | Remove it: the chart calculates it: `api.server.preStopSeconds` + drainSeconds + gracefulShutdownSeconds + 5 |
| `gateway.terminationGracePeriodSeconds` | Remove it: the chart calculates it: `gateway.preStopSeconds` + drainSeconds + gracefulShutdownSeconds + 5 |
| `organisationWallet.server.terminationGracePeriodSeconds` | Remove it: the chart calculates it: `organisationWallet.server.preStopSeconds` + gracefulShutdownSeconds + backgroundShutdownSeconds + 5 |
| `enterpriseDashboard.terminationGracePeriodSeconds` | Remove it: the chart calculates it: `enterpriseDashboard.preStopSeconds` + 20 |
| `gateway.listenPort` | Remove it: the port of the gateway process is the constant 8070 |
| `gateway.upstreams.core.url` | Remove it: the gateway always sends the requests of the api core to the api of this release |
| `api.iam.idpAlias` | Remove it: the chart writes the constant login-with-eudi-wallet. An installation that has another value since its first login sets Iam.IdPAlias in `api.advanced.extraConfig` |
| `api.dashboardUrl` | Remove it: the chart writes the public URL of `enterpriseDashboard.host` |
| `enterpriseDashboard.configuration.baseUrl` | Remove it: the chart writes the public URL of `api.host` |
| `enterpriseDashboard.configuration.walletUrl` | Remove it: the chart writes the public URL of `organisationWallet.host` |
| `enterpriseDashboard.configuration.appVersion` | Remove it: the chart writes the image tag of the dashboard |
| `database.engine` | Remove it: the database of all components is always PostgreSQL |

### Log level

One value `global.logLevel` with one vocabulary for all components: `debug`, `info`, `warn` or `error` (OpenBao also `trace`). The log level of each component is empty by default (`global.logLevel`) and can override it. The chart writes the words of each program, for example `INFO` for the wallet.

| Old value | New value, or what to do |
| --- | --- |
| `organisationWallet.logLevel` (a text) | The same value, with the new words (`DEBUG`: `debug`, `INFO`: `info`, `WARNING`: `warn`, `ERROR`: `error`, `CRITICAL`: `error`, `warning`: `warn`, `critical`: `error`) (the words of all components: debug, info, warn, error) |

### Installation limits

The limits of the installation are in `installation.limits`, next to the optional features, as numbers with the real default 100 (was an empty text for the default of the service).

| Old value | New value, or what to do |
| --- | --- |
| `api.limits.maxOrganisations` | `installation.limits.maxOrganisations` (a number from 1 to 100; empty is now the default 100) |
| `organisationWallet.walletUnit.organisationWalletUnitsMax` | `installation.limits.maxOrganisationWalletUnits` (a number from 1 to 100; empty is now the default 100) |

### Monitoring

One block `monitoring` for the ServiceMonitors of all components, the PrometheusRule of the wallet, their labels, and the network policy of the scrape. One switch turns on the monitoring of the platform; the Valkey exporters still need `redis.metrics.enabled`. The default interval is 30s for all ServiceMonitors (the wallet had 15s).

| Old value | New value, or what to do |
| --- | --- |
| `organisationWallet.serviceMonitor.enabled` | `monitoring.serviceMonitor.enabled` |
| `organisationWallet.serviceMonitor.interval` | `monitoring.serviceMonitor.interval` |
| `organisationWallet.serviceMonitor.labels` | `monitoring.labels` |
| `organisationWallet.prometheusRule.enabled` | `monitoring.prometheusRule.enabled` |
| `organisationWallet.prometheusRule.labels` | `monitoring.labels` |
| `redis.metrics.serviceMonitor.enabled` | `monitoring.serviceMonitor.enabled` |
| `redis.metrics.serviceMonitor.interval` | `monitoring.serviceMonitor.interval` |
| `redis.metrics.serviceMonitor.labels` | `monitoring.labels` |
| `networkPolicy.monitoring.enabled` | `monitoring.networkPolicy.enabled` |
| `networkPolicy.monitoring.namespaceSelector` | `monitoring.networkPolicy.namespaceSelector` |
| `networkPolicy.monitoring.podSelector` | `monitoring.networkPolicy.podSelector` |

### Outbound calls

One block `outboundHttp` for the SSRF guards of the api, the gateway and the wallet: `ssrfProtection.enabled` (was a key in the extra configuration of each service, with the opposite meaning in the api) and the private hosts that the wallet may call (`allowedPrivate`). See [The SSRF guards](security-context.md#the-ssrf-guards).

| Old value | New value, or what to do |
| --- | --- |
| `organisationWallet.ssrf.allowedPrivate` | `outboundHttp.allowedPrivate` |
| `api.extraConfig.OutboundHttp.ssrfProtectionDisabled` | `outboundHttp.ssrfProtection.enabled` (one switch for the api and the wallet: false turns the guards off) |
| `organisationWallet.extraConfig.ssrf_protection.enabled` | `outboundHttp.ssrfProtection.enabled` (one switch for the api and the wallet: false turns the guards off) |
| `organisationWallet.extraConfig.ssrf_protection.allowed_private` | `outboundHttp.allowedPrivate` |

### Worker groups

`organisationWallet.workers.groups` is a map with the group name as key (was a list). A value of yours changes one group and keeps the others (Helm merges maps but replaces lists); `null` removes a default group. The grace period of a group is `shutdownTimeoutSeconds` + 30 (the chart calculates it; see [Workers and clock](workers.md)).

| Old value | New value, or what to do |
| --- | --- |
| `organisationWallet.workers.groups` (a list) | A map with the group name as key now, for example {main: {queues: [...], replicas: 2, ...}}; without terminationGracePeriodSeconds (the chart calculates it) |

### Client address

Each public host has its own client address rule, in its exposure block: `api.exposure.clientAddress` (the gateway, the api and the webhook handler) and `organisationWallet.exposure.clientAddress` (the service pods of the wallet), because the hosts can be behind different proxies, for example a CDN only in front of the api host. The wallet reads the client address with the same rules as the gateway now: it no longer trusts `X-Forwarded-For` from a list of proxy networks. Behind ingress-nginx or the Envoy Gateway policy of the chart, set `header: X-Real-IP` for both hosts (the exposure profiles do it). The trusted proxies of a CDN go to the api host; give them to the wallet host only when the CDN is also in front of it (see [Exposure](exposure.md)). This release needs the wallet image of the same release.

| Old value | New value, or what to do |
| --- | --- |
| `clientAddress.header` | `api.exposure.clientAddress.header` and `organisationWallet.exposure.clientAddress.header` |
| `clientAddress.trustedProxies` | `api.exposure.clientAddress.trustedProxies` (also `organisationWallet.exposure.clientAddress.trustedProxies` only when the same proxies are in front of the wallet host) |
| `clientAddress.trustedProxyHeader` | `api.exposure.clientAddress.trustedProxyHeader` (also `organisationWallet.exposure.clientAddress.trustedProxyHeader` only when the same proxies are in front of the wallet host) |
| `organisationWallet.forwardedAllowIps` | Remove it: the wallet reads the client address with the rules of the gateway now: set `organisationWallet.exposure.clientAddress`, for example header X-Real-IP behind ingress-nginx or the Envoy Gateway policy of the chart |
