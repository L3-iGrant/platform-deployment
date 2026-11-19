# Components

What the chart installs, how your values files describe an installation, where the organisation wallet runs, and the optional features.

[Back to the contents](../README.md#contents)

| Component | What it does | Host |
| --- | --- | --- |
| Gateway | The single entry point of the API. It checks every request (API keys, logins, roles) and sends it to the right service. | The API host |
| API | Organisations, admins, credential definitions, webhooks and the OpenID provider. | Through the gateway |
| Webhook handler | Sends the webhook events of your organisations. | None |
| Organisation wallet | Issues, holds and verifies credentials (OpenID4VCI, OpenID4VP) and acts as the wallet provider. One image runs in several roles: service (public routes), config (configuration routes), the workers (background work, in groups of queues) and the clock (sends scheduled work to the queues). See [Workers and clock](workers.md). | The wallet host |
| Enterprise dashboard | The web interface for organisation admins. | The dashboard host |
| Database | One PostgreSQL server for all components, or your own server. | None |
| NATS | The messages between the services. | None |
| OpenBao | Keeps the wallet's signing keys. | None |
| Valkey | The wallet's work queue, single-use values and shared caches: three pods, each with a data server and a Sentinel, or your own Valkey or Redis. Never a record. | None |

You describe your installation in a few values files: your site, the database, the OpenBao seal, the exposure and, if you need them, your own Valkey or Redis and the network policies. The `profiles/` folder has a ready file for each option, `profiles/minimal.yaml` gives a small installation for tests and development, `profiles/size-extra-small.yaml` an extra small production installation (up to about 10,000 wallets, with the redundancy of the defaults) and `profiles/gke.yaml` the settings for a node pool of its own on Google Kubernetes Engine.

## The services of the installation

A release runs the gateway, the api, the webhook handler and the organisation wallet. The dashboard is a static web app: with `enterpriseDashboard.enabled: false`, the release does not run it, for example when you host it yourself.

The chart writes the services of the installation into the api file, the webhook file and the gateway file (`Installation.services`: `[wallet]`). You cannot set this list. Do not set `Installation` in `api.extraConfig` or `gateway.extraConfig`: the render stops when it names other services than the chart.

## Optional features

An optional feature is a part of a service that an installation can leave out. Each optional feature is off when it is not in `installation.optionalFeatures`, and the default is the empty list:

| Value | The optional feature |
| --- | --- |
| `protocol1` | Protocol 1 of the individual wallet provider: the protocol of the wallet apps that do not sign their requests. Protocol 2 signs each request. A new installation does not need protocol 1. |

The chart writes the same list into the api file and the gateway file (`Installation.optionalFeatures`) and into each file of the organisation wallet (`installation.optional_features`). You cannot set it in `api.extraConfig`, `gateway.extraConfig` or `organisationWallet.extraConfig`. When an optional feature is off, its routes do not exist, the wallet refuses its settings, and the dashboard does not show it.
