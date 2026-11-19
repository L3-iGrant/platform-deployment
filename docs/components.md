# Components

What the chart installs, how your values files describe an installation, and which services an installation has.

[Back to the contents](../README.md#contents)

| Component | What it does | Host |
| --- | --- | --- |
| Gateway | The single entry point of the API. It checks every request (API keys, logins, roles) and sends it to the right service. | The API host |
| API | Organisations, admins, credential definitions, webhooks and the OpenID provider. | Through the gateway |
| Webhook handler | Sends the webhook events of your organisations. | None |
| Consent management | Data agreements and consent records. | Through the gateway |
| Organisation wallet | Issues, holds and verifies credentials (OpenID4VCI, OpenID4VP) and acts as the wallet provider. One image runs in several roles: service (public routes), config (configuration routes), the workers (background work, in groups of queues) and the clock (sends scheduled work to the queues). See [Workers and clock](workers.md). | The wallet host |
| Enterprise dashboard | The web interface for organisation admins. | The dashboard host |
| Database | One PostgreSQL server for all components, or your own server. | None |
| NATS | The messages between the services. | None |
| OpenBao | Keeps the wallet's signing keys. | None |
| Valkey | The wallet's work queue, single-use values and shared caches: three pods, each with a data server and a Sentinel, or your own Valkey or Redis. Never a record. | None |

You describe your installation in a few values files: your site, the database, the OpenBao seal, the exposure and, if you need them, your own Valkey or Redis and the network policies. The `profiles/` folder has a ready file for each option, `profiles/minimal.yaml` gives a small installation for tests and development, `profiles/size-extra-small.yaml` an extra small production installation (up to about 10,000 wallets, with the redundancy of the defaults) and `profiles/gke.yaml` the settings for a node pool of its own on Google Kubernetes Engine.

## The services of the installation

An installation has consent management, the organisation wallet, or both. Each service is either installed or not installed:

| Values | The service is |
| --- | --- |
| `consent.enabled: true` (`profiles/consent.yaml`) | Installed: this release runs consent |
| `consent.enabled: false` and `gateway.upstreams.consent.url` | Installed: the consent service of another release |
| `consent.enabled: false` (the default) and no `gateway.upstreams.consent.url` | Not installed |
| `organisationWallet.enabled: true` (the default) | Installed: this release runs the organisation wallet |
| `organisationWallet.enabled: false` and `gateway.upstreams.walletConfig.url` | Installed: the organisation wallet of another release |
| `organisationWallet.enabled: false` and no `gateway.upstreams.walletConfig.url` | Not installed |

The chart writes the list of services into the api file and the gateway file (`Installation.services`). You cannot set this list: the chart takes it from the values in the table. With all services, the files have no `Installation.services` key. At least one service must be installed, or the render stops.

When a service is not installed:

- The api file and the gateway file get `Installation.services` with the other service, for example `[wallet]`.
- The gateway answers `404` with `errorKey` `service_not_installed` on every route of the service, public routes too. The dashboard shows no area for the service. Organisations get no webhook event types and no API key scopes of the service.
- The gateway file has no upstream for the service. No process of the release reads the service's views or trusts its NATS messages. So you do not need its public keys (`serviceKeys.publicJwks.<service>`), its NATS users (`nats.auth.users.*`) or the read-only users of its database (`readAccess.*.<service>`).

Without consent:

- The organisation wallet reads only the api's views (no `readAccess.wallet.consent`).
- The privacy dashboard is not available: the render stops when `privacyDashboard.enabled` is `true` (see [Privacy dashboard](privacy-dashboard.md)).

Without the organisation wallet:

- The chart runs no OpenBao, no wallet pods and no wallet Jobs, and NATS and Valkey have no wallet users. Valkey stays for the gateway.
- The api and consent read no wallet views (no `readAccess.api.wallet` and `readAccess.consent.wallet`).
- `organisationWallet.host` is not required. The api file has no `OpenIdDeployment`, and the dashboard has no `walletUrl`.

For example, to add consent, add `profiles/consent.yaml`, or put this in `my-site.yaml`:

```yaml
consent:
  enabled: true
```

Do not set `Installation` in `api.extraConfig` or `gateway.extraConfig`: the render stops when it names other services than the chart. A release without the api (`api.enabled: false`) has no gateway, so it cannot see which services the installation has: it keeps the reads and trusts of all services. To add or remove a service later, see [Add or remove a service](#add-or-remove-a-service).


## Optional features

An optional feature is a part of a service that an installation can leave out. Each optional feature is off when it is not in `installation.optionalFeatures`, and the default is the empty list:

| Value | The optional feature |
| --- | --- |
| `protocol1` | Protocol 1 of the individual wallet provider: the protocol of the wallet apps that do not sign their requests. Protocol 2 signs each request. A new installation does not need protocol 1. It needs the organisation wallet. |

The chart writes the same list into the api file and the gateway file (`Installation.optionalFeatures`) and into each file of the organisation wallet (`installation.optional_features`). You cannot set it in `api.extraConfig`, `gateway.extraConfig` or `organisationWallet.extraConfig`. When an optional feature is off, its routes do not exist, the wallet refuses its settings, and the dashboard does not show it.

## Add or remove a service

An installation can run without consent or without the organisation wallet (see [The services of the installation](#the-services-of-the-installation)). To remove or add a service later, change your values files and run `helm upgrade` with all your values files (the files of [install step 4](install.md#step-4-install)):

### Remove a service

1. In your values files, set `consent.enabled: false` (or `organisationWallet.enabled: false`), and remove `gateway.upstreams.consent.url` (or `gateway.upstreams.walletConfig.url`). Without consent, also set `privacyDashboard.enabled: false`.
2. Run `helm upgrade` with all your values files.

Helm removes the pods, Jobs, Services and ConfigMaps of the service. The service's data stays: the chart deletes no database, no database user and no Secret with `helm.sh/resource-policy: keep` (for example the passwords in `<release>-postgres`). Without the wallet, the volumes of the bundled OpenBao also stay, with the wallet keys in them. The organisations' data stays too:

- The stored features of the service stay on the organisation record, but have no effect: the dashboard shows no area for the service.
- A webhook keeps its event types of the service, but gets no events of the service.
- An API key keeps its scopes of the service, but every route of the service answers `404` (`service_not_installed`).

### Add a service later

1. In your values files, set `consent.enabled: true` (or `organisationWallet.enabled: true`), or set the URL of the service in another release.
2. Run `helm upgrade` with all your values files.

The stored features, webhook subscriptions and API keys of the service apply again. A service that was installed before finds its data in its database. With the bundled OpenBao, the OpenBao pods start with their earlier volumes: unseal each pod (install step 5, item 2), and do not initialise OpenBao again.

Consent and the organisation wallet get the api's events from the stream `API_EVENTS` (consent: organisation changes and deletions; the wallet: organisation and sandbox changes and deletions). The stream keeps an event for 8 days, and no tool sends an older event again.

- A service that you add for the first time has a new database: it misses nothing, and you do nothing.
- A service that you removed and add again misses the events older than 8 days:
  - Consent, organisation suspensions and resumptions: no action. Consent reads each organisation from the api again when its local copy expires (after at most 15 minutes), and gets the current state.
  - Consent, organisation deletions: consent keeps the consent data of each organisation that a platform admin deleted while consent was not installed.
  - The wallet: the wallet keeps the wallets of each organisation and sandbox that a platform admin deleted while the wallet was not installed, and the api sent no wallet commands in that time (for example the suspension of an organisation).

  The platform operator's organisations list shows each deleted organisation with the status `deleting`, without a date. The action log of the platform operator organisation has the entry `organisation_deletion_started` with the date, but only for `api.actionLogRetentionDays` (default 30 days). So keep your own record of each organisation that you delete while a service is not installed. After the `helm upgrade`, send this record to iGrant.io support to purge the data of these organisations in the service.
