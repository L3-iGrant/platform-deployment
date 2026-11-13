# NATS users

This page explains the NATS users of the processes, and what an external NATS server needs.

[Back to the contents](../README.md#contents)

Every process connects to NATS with its own nkey user, with only the subjects that it needs. The server has no user without credentials.

| User (`nats.auth.users.<user>`) | Process |
| --- | --- |
| `api` | the API core and its operator Jobs |
| `apiWebhook` | the webhook handler |
| `consent` | consent management |
| `walletConfig`, `walletService`, `walletWorker` | the roles of the wallet (`walletWorker`: all worker groups; the clock connects to no NATS, see [Workers and clock](workers.md)) |

An installation without consent or without the organisation wallet has no user of that service: `nats.conf` does not have it, also when its values are set (see [Components](components.md#the-services-of-the-installation)).

The values hold only the public nkey (`nkey`, it starts with `U`) and the name of the Secret with the seed (`seedSecret`). With an external NATS (`nats.enabled: false`), the chart writes the users and `max_payload` in the ConfigMap `<release>-nats-authorization`: add them to the configuration of your server (global account). Your server needs JetStream and NATS 2.10 or later. Set `nats.jetstreamReplicas` to its cluster size.

## TLS

The bundled NATS always uses TLS. The clients (port 4222) verify the server with the CA of the chart: each process mounts it as `nats-ca.crt`. The routes between the servers (port 6222) use mutual TLS: a server accepts a route only from a server with a certificate of the same CA (`verify`), and the route checks the name of the server. The chart makes the CA and the certificate in the Secret `<release>-nats-tls` (10 years, kept across upgrades), or uses your Secret (`nats.tls.existingSecret`: `tls.crt`, `tls.key`, `ca.crt`; the names `<release>-nats.<namespace>.svc` and `*.<release>-nats-headless`, also with `.<namespace>.svc`; server and client use). With your own Secret, its CA must sign only the certificates of the NATS servers: each certificate of that CA can open a route. With `networkPolicy.enabled`, only the NATS pods reach the route port 6222. The monitor port 8222 (the probes, and the scrape from `networkPolicy.monitoring`) has no TLS.

## The version of NATS

The chart runs NATS 2.14 (`nats.image`, pinned by digest). The 2.12 line gets no more fixes. Do not use NATS 2.15 or later: 2.15 sends the JetStream acks on subjects of the format v2 by default, and the permissions of the users allow the acks only in the format v1 (`$JS.ACK.<stream>.<consumer>.>`), so the consumers of the services could not ack. The render stops for a tag of 2.15 or later. An external NATS (`nats.enabled: false`) must also be 2.14 or earlier (2.10 or later), or send the acks in the format v1.

An external NATS with TLS: set `nats.tlsCa.existingSecret` to a Secret with the CA of your server. `nats.tlsCa` with the bundled NATS stops the render.

New certificates: delete the Secret `<release>-nats-tls`, run `helm upgrade`, then restart the NATS pods and the pods of the services.

## Streams, consumers and buckets

The services make their JetStream streams, their durable consumers and their key-value buckets at their start, with the definitions of the contract of the api (`contract/v2/streams.json`). A NATS user can make and change only the streams, consumers and buckets of its process: no user can delete or purge a stream or the consumer of another service. Each stream keeps a message at most 8 days (`192h`), with a duplicate window of 2 minutes, and `nats.jetstreamReplicas` copies.

| Stream | Made by | Subjects | Retention |
| --- | --- | --- | --- |
| `API_EVENTS` | the API core, the webhook handler | `api.v1.evt.organisation.created`, `.organisation.updated`, `.organisation.deleted`, `.sandbox.updated`, `.sandbox.deleted`, `.extension.updated` | limits |
| `CONSENT_EVENTS` | consent | `consent.v1.evt.webhook.requested`, `consent.v1.evt.policy.updated` | limits |
| `OWS_MICROSERVICE` | the wallet roles, the API core, the webhook handler | `ows.*.webhook.*`, `ows.*.notification`, `ows.*.evt.push_requested`, `ows.*.evt.webhook_event` (the wallet); `ows.users.*.authentication.oidcpasswordless.verified`, `.accepted`, `ows.openidprovider.client.created`, `.client.deleted`, `.clients.deleted` (the api) | interest: a message stays until each consumer has it |

The durable consumers. The replicas of a process share each consumer (the deliver group is the name of the consumer). A consumer acknowledges each message. A failed message comes again after 30 seconds, then 1, 2, 5 and 10 minutes, at most 10 times; the last failure goes to the dead letters of the service. A message that is not acknowledged in 30 seconds comes again.

| Consumer | Stream | Subjects | Process |
| --- | --- | --- | --- |
| `consent-api-organisation` | `API_EVENTS` | `api.v1.evt.organisation.created`, `.updated`, `.deleted` | consent |
| `eudi-wallet-api-triggers` | `API_EVENTS` | `api.v1.evt.organisation.updated`, `.organisation.deleted`, `.sandbox.updated`, `.sandbox.deleted`, `.extension.updated` | the config role of the wallet |
| `api-consent-webhooks`, `api-consent-policy` | `CONSENT_EVENTS` | `consent.v1.evt.webhook.requested`, `consent.v1.evt.policy.updated` | the webhook handler |
| `consent-dda-present-proof`, `consent-dda-presentation` | `OWS_MICROSERVICE` | `ows.*.webhook.present_proof`, `ows.*.webhook.presentation` | consent (only with the organisation wallet: without it, the user `consent` has no rights of these consumers) |
| `api-webhook-event` | `OWS_MICROSERVICE` | `ows.*.evt.webhook_event` (the webhook events of the issuer, the verifier and the holder) | the webhook handler |
| `api-push-requested` | `OWS_MICROSERVICE` | `ows.*.evt.push_requested` | the webhook handler |
| `openidprovider-client-created`, `openidprovider-client-deleted`, `openidprovider-clients-deleted` | `OWS_MICROSERVICE` | `ows.openidprovider.client.created`, `.client.deleted`, `.clients.deleted` | the API core |

The API core publishes each event of `API_EVENTS` by its name: its NATS user has the publish right for each of the 6 subjects, and no wildcard. `api.v1.evt.organisation.deleted` is the deletion of an organisation by a platform admin: consent purges its data of the organisation, and the wallet deactivates the wallets of the organisation. The API core adds the subject to the stream at its start, and consent and the config role of the wallet add it to the filter of their consumers at their start. A consumer has no subject right of its own (it gets its messages on the inbox of its process), so only the user `api` changes. With an external NATS, see [Upgrade](upgrade.md#before-the-upgrade).

The services delete the durable consumers of their earlier releases at their start, before they update the stream: the API core and the webhook handler delete `api-wua-revocation`, `api-webhook-issue-credential`, `api-webhook-issuer-event`, `api-webhook-credential`, `api-webhook-present-proof` and `api-webhook-presentation`; the service and config roles of the wallet delete `credential-definition-worker` and `presentation-definition-worker`. The NATS users of these processes can only read and delete these consumers. Without this right, the API core and the webhook handler do not start.

Subscriptions without a JetStream consumer: the NATS commands of the api to the config role (`ows.cmd.*.>`, request and reply: the API core sends all commands, for example `ows.cmd.<wallet organisation id>.organisation.set_suspended` for the suspension of an organisation; the webhook handler sends only `ows.cmd.*.issuance.revoke`, the revocation of the earlier Authenticator credential of an admin); the server-sent event streams of each config pod (`ows.*.notification`, `ows.*.webhook.present_proof`: each config pod gets each event); the clears of the process caches of the wallet (`ows.cache.cleared`: the service and config pods send them, and each of these pods gets each clear; a pod that cannot subscribe to it is not ready; the workers send no clear, so a change that a worker commits reaches the caches of the service and config pods when their 60 seconds end, as does a lost clear); the passwordless waits of the API core.

| Key-value bucket | Made by | Holds |
| --- | --- | --- |
| `OWS_ENVELOPE_JTI` | the API core | the ids of the signed write requests (replay check) |
| `wallet-command-replay` | the config role of the wallet | the ids of the NATS commands (replay check) |
| `wallet-command-replies` | the config role of the wallet | the reply of each NATS command, for a retry of the api (`organisationWallet.nats.commandReplySeconds`, default 300 seconds) |

The workers and the clock of the wallet have no JetStream consumer: the background work of the wallet is on the queues of Valkey (see [Workers and clock](workers.md)). The outbox relay (an actor of the workers) publishes the events of the outbox of the wallet with the event id as the message id (`Nats-Msg-Id`), so the stream ignores a copy of an event within its duplicate window.

Watch the consumers on the monitor port of a NATS server (8222, `/jsz?consumers=true`): `num_pending` (the messages that wait) and `num_ack_pending`. When `consent-dda-present-proof` or `consent-dda-presentation` has more than 1000 messages that wait, consent is behind: the stream keeps the messages until consent has them.
