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

You describe your installation in a few values files: your site, the database, the OpenBao seal, the exposure and, if you need them, your own Valkey or Redis and the network policies. The `profiles/` folder has a ready file for each option, and `profiles/minimal.yaml` gives a small installation for tests and development.

## The services of the installation

An installation has consent management, the organisation wallet, or both. Each service is either installed or not installed:

| Values | The service is |
| --- | --- |
| `consent.enabled: true` (the default) | Installed: this release runs consent |
| `consent.enabled: false` and `gateway.upstreams.consent.url` | Installed: the consent service of another release |
| `consent.enabled: false` and no `gateway.upstreams.consent.url` | Not installed |
| `organisationWallet.enabled: true` (the default) | Installed: this release runs the organisation wallet |
| `organisationWallet.enabled: false` and `gateway.upstreams.walletConfig.url` | Installed: the organisation wallet of another release |
| `organisationWallet.enabled: false` and no `gateway.upstreams.walletConfig.url` | Not installed |

The chart writes the list of services into the api file and the gateway file (`Installation.services`). You cannot set this list: the chart takes it from the values in the table. With all services, the files have no `Installation` key, as in earlier releases. At least one service must be installed, or the render stops.

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

For example, for an installation without consent, put this in `my-site.yaml`:

```yaml
consent:
  enabled: false
```

Do not set `Installation` in `api.extraConfig` or `gateway.extraConfig`: the render stops when it names other services than the chart. A release without the api (`api.enabled: false`) has no gateway, so it cannot see which services the installation has: it keeps the reads and trusts of all services. To add or remove a service later, see [Upgrade](upgrade.md#the-services-of-the-installation).
