# Components

This page lists the components that the chart installs, and how your values files describe an installation.

[Back to the contents](../README.md#contents)

| Component | What it does | Public host |
| --- | --- | --- |
| Gateway | The single entry point of the API. It checks every request (API keys, logins, roles) and sends it to the right service. | The API host |
| API | Organisations, admins, credential definitions, webhooks and the OpenID provider. | Through the gateway |
| Webhook handler | Sends the webhook events of your organisations. | None |
| Consent management | Data agreements and consent records. | Through the gateway |
| Organisation wallet | Issues, holds and verifies credentials (OpenID4VCI, OpenID4VP) and acts as the wallet provider. It runs as three roles of one image: service (public routes), config (configuration routes) and scheduler (background tasks). | The wallet host |
| Enterprise dashboard | The web interface of the organisation admins. | The dashboard host |
| Database | One PostgreSQL or MariaDB server for all components, or your own server. | None |
| NATS | The messages between the services. | None |
| OpenBao | Keeps the signing keys of the wallet. | None |

You describe your installation with a few values files: your site, the database, the OpenBao seal, the exposure and, when you need them, the network policies. The `examples/` folder has a ready file for each option.
