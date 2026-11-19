# NATS users

The NATS users of the processes, and what an external NATS server needs.

[Back to the contents](../README.md#contents)

Every process connects to NATS with its own nkey user, which can use only the subjects that it needs. The server has no user without credentials.

| User (`nats.users.<user>`) | Process |
| --- | --- |
| `api` | the API core and its operator Jobs |
| `webhook` | the webhook handler |
| `walletConfig`, `walletService`, `walletWorker` | the wallet roles (`walletWorker`: all worker groups; the clock connects to no NATS, see [Workers and clock](workers.md)) |

The values hold only the public nkey (`nkey`, it starts with `U`) and the Secret with the seed (`seed.existingSecret`, key `seed.key`). With an external NATS (`nats.mode: external`), the chart writes the users and `max_payload` to the ConfigMap `<release>-nats-authorization`: add them to the configuration of your server (global account). Your server needs JetStream and NATS 2.10 or later. Set `nats.jetstreamReplicas` to its cluster size.

## TLS

The bundled NATS always uses TLS:

- The clients (port 4222) verify the server with the chart's CA: each process mounts it as `nats-ca.crt`.
- The routes between the servers (port 6222) use mutual TLS: a server accepts a route only from a server with a certificate of the same CA (`verify`), and the route checks the server name.

The chart creates the CA and the certificate in the Secret `<release>-nats-tls` (10 years, kept across upgrades), or uses your Secret (`nats.tls.existingSecret`: `tls.crt`, `tls.key`, `ca.crt`; the names `<release>-nats.<namespace>.svc` and `*.<release>-nats-headless`, also with `.<namespace>.svc`; server and client use). With your own Secret, its CA must sign only the certificates of the NATS servers: every certificate of that CA can open a route. With `networkPolicy.enabled`, only the NATS pods reach the route port 6222. The monitor port 8222 (the probes, and the scrape from `networkPolicy.monitoring`) has no TLS.

## The version of NATS

The chart runs NATS 2.14 (`nats.image`, pinned by digest). The 2.12 line gets no more fixes. Do not use NATS 2.15 or later: 2.15 sends the JetStream acks on subjects in format v2 by default, but the user permissions allow acks only in format v1 (`$JS.ACK.<stream>.<consumer>.>`), so the consumers of the services could not ack. The render stops for a tag of 2.15 or later. An external NATS (`nats.mode: external`) must also be 2.14 or earlier (2.10 or later), or send the acks in format v1.

For an external NATS with TLS, set `nats.external.ca.existingSecret` to a Secret with the CA of your server. `nats.external.ca` with the bundled NATS stops the render.

To renew the certificates: delete the Secret `<release>-nats-tls`, run `helm upgrade`, then restart the NATS pods and the pods of the services.

## Streams, consumers and buckets

The services create their JetStream streams, their durable consumers and their key-value buckets when they start, from the definitions in the api contract (`contract/v2/streams.json`). A NATS user can create and change only the streams, consumers and buckets of its own process: no user can delete or purge a stream, or the consumer of another service. Each stream keeps a message for at most 8 days (`192h`), with a duplicate window of 2 minutes, and `nats.jetstreamReplicas` copies.

| Stream | Made by | Subjects | Retention |
| --- | --- | --- | --- |
| `API_EVENTS` | the API core, the webhook handler | `api.v1.evt.organisation.created`, `.organisation.updated`, `.organisation.deleted`, `.sandbox.updated`, `.sandbox.deleted`, `.extension.updated` | limits |
| `OWS_MICROSERVICE` | the wallet roles, the API core, the webhook handler | `ows.*.webhook.*`, `ows.*.notification`, `ows.*.evt.push_requested`, `ows.*.evt.webhook_event` (the wallet); `ows.users.*.authentication.oidcpasswordless.verified`, `.accepted`, `ows.openidprovider.client.created`, `.client.deleted`, `.clients.deleted` (the api) | interest: a message stays until each consumer has it |

The durable consumers: the replicas of a process share each consumer (the deliver group is the consumer name). A consumer acknowledges each message. A failed message comes back after 30 seconds, then after 1, 2, 5 and 10 minutes, at most 10 times; the last failure goes to the dead letters of the service. A message that is not acknowledged within 30 seconds comes back.

| Consumer | Stream | Subjects | Process |
| --- | --- | --- | --- |
| `eudi-wallet-api-triggers` | `API_EVENTS` | `api.v1.evt.organisation.updated`, `.organisation.deleted`, `.sandbox.updated`, `.sandbox.deleted`, `.extension.updated` | the wallet's config role |
| `api-webhook-event` | `OWS_MICROSERVICE` | `ows.*.evt.webhook_event` (the webhook events of the issuer, the verifier and the holder) | the webhook handler |
| `api-push-requested` | `OWS_MICROSERVICE` | `ows.*.evt.push_requested` | the webhook handler |
| `openidprovider-client-created`, `openidprovider-client-deleted`, `openidprovider-clients-deleted` | `OWS_MICROSERVICE` | `ows.openidprovider.client.created`, `.client.deleted`, `.clients.deleted` | the API core |

The API core publishes each event of `API_EVENTS` by its name: its NATS user has the publish right for each of the 6 subjects, and no wildcard. `api.v1.evt.organisation.deleted` is the deletion of an organisation by a platform admin: the wallet deactivates the organisation's wallets. The API core adds the subject to the stream when it starts, and the wallet's config role adds it to the filters of its consumer when it starts. A consumer has no subject rights of its own (it gets its messages on the inbox of its process), so only the user `api` changes. An external NATS needs the users of the ConfigMap `<release>-nats-authorization` of each release.

Subscriptions without a JetStream consumer:

- the NATS commands of the api to the config role (`ows.cmd.*.>`, request and reply). The API core sends all commands, for example `ows.cmd.<wallet organisation id>.organisation.set_suspended` to suspend an organisation. The webhook handler sends only `ows.cmd.*.issuance.revoke`, the revocation of an admin's earlier Authenticator credential;
- the server-sent event streams of each config pod (`ows.*.notification`, `ows.*.webhook.present_proof`): each config pod gets each event;
- the clears of the wallet's process caches (`ows.cache.cleared`). The service and config pods send them, and each of these pods gets each clear; a pod that cannot subscribe to it is not ready. The workers send no clear, so a change that a worker commits reaches the caches of the service and config pods when their 60 seconds end, the same as a lost clear;
- the passwordless waits of the API core.

| Key-value bucket | Made by | Holds |
| --- | --- | --- |
| `OWS_ENVELOPE_JTI` | the API core | the ids of the signed write requests (replay check) |
| `wallet-command-replay` | the wallet's config role | the ids of the NATS commands (replay check) |
| `wallet-command-replies` | the wallet's config role | the reply of each NATS command, for a retry of the api (`organisationWallet.nats.commandReplySeconds`, default 300 seconds) |

The wallet's workers and clock have no JetStream consumer: the wallet's background work is on the Valkey queues (see [Workers and clock](workers.md)). The outbox relay (a worker actor) publishes the events of the wallet's outbox with the event id as the message id (`Nats-Msg-Id`), so the stream ignores a copy of an event within its duplicate window.

Watch the consumers on the monitor port of a NATS server (8222, `/jsz?consumers=true`): `num_pending` (the messages that wait) and `num_ack_pending`.
