# NATS users

This page explains the NATS users of the processes, and what an external NATS server needs.

[Back to the contents](../README.md#contents)

Every process connects to NATS with its own nkey user, with only the subjects that it needs. The server has no user without credentials.

| User (`nats.auth.users.<user>`) | Process |
| --- | --- |
| `api` | the API core and its operator Jobs |
| `apiWebhook` | the webhook handler |
| `consent` | consent management |
| `walletConfig`, `walletService`, `walletScheduler` | the three roles of the wallet |

The values hold only the public nkey (`nkey`, it starts with `U`) and the name of the Secret with the seed (`seedSecret`). With an external NATS (`nats.enabled: false`), the chart writes the users and `max_payload` in the ConfigMap `<release>-nats-authorization`: add them to the configuration of your server (global account). Your server needs JetStream and NATS 2.10 or later. Set `nats.jetstreamReplicas` to its cluster size.
