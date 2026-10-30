# NATS users

This page explains the NATS users of the processes, and what an external NATS server needs.

[Back to the contents](../README.md#contents)

Every process connects to NATS with its own nkey user, with only the subjects that it needs. The server has no user without credentials.

| User (`nats.auth.users.<user>`) | Process |
| --- | --- |
| `api` | the API core and its operator Jobs |
| `apiWebhook` | the webhook handler |
| `consent` | consent management |
| `walletConfig`, `walletService`, `walletWorker`, `walletScheduler` | the roles of the wallet (`walletWorker`: all worker groups; the clock connects to no NATS, see [Workers and clock](workers.md)) |

The values hold only the public nkey (`nkey`, it starts with `U`) and the name of the Secret with the seed (`seedSecret`). With an external NATS (`nats.enabled: false`), the chart writes the users and `max_payload` in the ConfigMap `<release>-nats-authorization`: add them to the configuration of your server (global account). Your server needs JetStream and NATS 2.10 or later. Set `nats.jetstreamReplicas` to its cluster size.

## TLS

The bundled NATS always uses TLS. The clients (port 4222) verify the server with the CA of the chart: each process mounts it as `nats-ca.crt`. The routes between the servers (port 6222) use mutual TLS: a server accepts a route only from a server with a certificate of the same CA (`verify`), and the route checks the name of the server. The chart makes the CA and the certificate in the Secret `<release>-nats-tls` (10 years, kept across upgrades), or uses your Secret (`nats.tls.existingSecret`: `tls.crt`, `tls.key`, `ca.crt`; the names `<release>-nats.<namespace>.svc` and `*.<release>-nats-headless`, also with `.<namespace>.svc`; server and client use). The monitor port 8222 (the probes, and the scrape from `networkPolicy.monitoring`) has no TLS.

An external NATS with TLS: set `nats.tlsCa.existingSecret` to a Secret with the CA of your server. `nats.tlsCa` with the bundled NATS stops the render.

New certificates: delete the Secret `<release>-nats-tls`, run `helm upgrade`, then restart the NATS pods and the pods of the services.
