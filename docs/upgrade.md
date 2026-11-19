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
