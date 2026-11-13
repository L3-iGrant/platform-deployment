# Upgrade

This page upgrades an installation to a new release of the platform.

[Back to the contents](../README.md#contents)

1. Set `global.imageTag` in `my-site.yaml` to the release tag of the new version (from iGrant.io). The chart and the images of one release belong together: a new chart with the images of an older release can stop the pods (for example, the wallet refuses a configuration key that it does not know). Then read the `values.yaml` of the new chart version and adapt your files where necessary. A release that was installed from the chart `organisationwallet` also sets `nameOverride: organisationwallet` (see [The chart name platform](#the-chart-name-platform)).
2. Check the render with the new chart (`helm template`, as in install step 3).
3. Upgrade:

   ```bash
   helm upgrade ows ./platform-deployment -n ows \
     -f ./ows-keys/values-keys.yaml -f my-site.yaml \
     -f my-database.yaml -f my-openbao.yaml -f my-exposure.yaml \
     --wait --timeout 15m
   ```

   Before the pods change, the hooks of the release run in this order:

   1. The init hook (`ows-db-init`) creates the database and the owner user of each enabled component that does not have them yet, and sets the passwords of the owner users, with the admin user of the database server.
   2. The roles hook of the wallet (`ows-wallet-database-roles`) creates the database roles of the wallet, sets their passwords and gives their grants, with the admin user of the database server.
   3. The migration hooks (`ows-api-migrate`, `ows-consent-migrate`, `ows-wallet-migrate`) update the database schemas. The wallet hook connects as the migrator role of the wallet; after the grants, it makes the partitions of the audit log and drops the months that are older than its retention (see [Audit log](audit-log.md#partitions)).
   4. The read access hooks of the wallet (`ows-wallet-read-access-api`, `ows-wallet-read-access-consent`) update the read-only users with which the api and consent read the wallet database.

   Valkey is not a hook: it changes with the other resources. Its pods restart one at a time; before the primary stops, a Sentinel moves the primary to a replica (see [Redis](redis.md#bundled-valkey)). The first upgrade to a release with Valkey creates the Valkey pods and their volumes; the wallet pods then get their `redis` section.

   When a hook fails, the upgrade stops and the old pods stay. Read the log of its Job, for example `kubectl -n ows logs job/ows-wallet-migrate`. After the upgrade, the hook `ows-consent-migrate-after` completes the data of consent: it needs `--wait`. The new wallet pods start their work only when the database schema is at the head of their release: they wait up to 600 seconds, then stop, and Kubernetes starts them again. See [Database](database.md#hooks-of-the-databases).

   An upgrade can turn a component on, for example `organisationWallet.enabled: true`: the hooks create its passwords, its database and its users before its migration hook runs. With `database.auth.existingSecret`, first add the password of the new database to your Secret (the key is the database name, for example `igrant_wallet`).

   The exit code of the wallet migration hook (`migrate-database`):

   | Exit code | Meaning | Action |
   | --- | --- | --- |
   | 0 | The schema is at the head of the release, with all grants | None |
   | 1 | A revision failed | The log names the revision and the error. Correct the cause, or contact iGrant.io with the log, then run the upgrade again. |
   | 2 | A configuration or connection error | Check the database values and the database roles of the wallet (the roles hook ran before), then run the upgrade again. |
   | 3 | The grant step failed: the schema is at the head, but the grants are not complete | Run the upgrade again: the hook gives the missing grants. |
   | 4 | The partition step of the audit log failed: the schema is at the head with all grants, but a partition is missing or a drop failed | Run the upgrade again: the hook completes the partitions. |

4. Bundled OpenBao: the OpenBao pods do not restart on their own (update strategy `OnDelete`), because a restarted pod stays sealed. Check whether the upgrade changed the OpenBao pods (for example a new release tag or a new OpenBao configuration):

   ```bash
   kubectl -n ows get statefulset ows-openbao -o go-template='{{or .status.updatedReplicas 0}}/{{.status.replicas}}{{"\n"}}'
   ```

   `3/3` means no change: go to the check below. Otherwise, restart and unseal the pods one at a time: first the two standby pods, then the active pod (`bao status` shows `HA Mode`: `standby` or `active`). For each pod:

   ```bash
   kubectl -n ows exec ows-openbao-2 -- bao status | grep 'HA Mode'   # standby: restart this pod first
   kubectl -n ows delete pod ows-openbao-2
   kubectl -n ows wait --for=jsonpath='{.status.phase}'=Running pod/ows-openbao-2 --timeout=5m
   kubectl -n ows exec -it ows-openbao-2 -- bao operator unseal   # 3 times, 3 different unseal keys
   ```

   Check: `kubectl -n ows exec ows-openbao-2 -- bao status` shows `Sealed false`. Continue with the next pod only when this check passes. After the third pod, the `updatedReplicas` command shows `3/3`.

5. Bundled OpenBao: run `bootstrap.sh` again (install step 5, item 3). It changes only what the new version needs, for example new Transit paths in the wallet policy. External OpenBao: compare your policy with [External OpenBao](openbao.md#external-openbao).

Check: `helm -n ows status ows` shows `STATUS: deployed`, and `kubectl -n ows get pods` shows all pods `Running` and `READY`.

## Rollback

From this chart version, the database Secret `<release>-postgres`, the read access Secret `<release>-read-access` and the init Job `<release>-db-init` are Helm hooks (see [Database](database.md#hooks-of-the-databases)). In the revisions of earlier chart versions, they are resources of the release. A rollback to such a revision is not supported. Helm stops with an error:

- `helm rollback` stops with `no Secret with the name "ows-postgres" found`: the Secret is in the cluster, but not in the manifest of the current revision. Before it stops, Helm has already applied the network policies, the disruption budgets and the service accounts of the earlier revision.
- `helm upgrade` with an earlier chart version stops with `invalid ownership metadata`: the Secret in the cluster has no owner data of the release.

To see if a revision is of this kind: `helm -n ows get manifest ows --revision <revision> | grep 'name: ows-postgres$'` shows a line.

A rollback also does not take the database schemas back. The migration hooks changed them, and the wallet pods of an earlier release wait for the schema head of their own release, then stop.

The supported ways back:

- Run the upgrade of step 3 with this chart version and your earlier values files, for example to turn a component off again.
- To go back to an earlier release of the platform, install that release again as its release notes say.

### Back to a chart version before this one

- Use `helm rollback` to the last revision that you deployed with that chart version (`helm -n ows history ows`). A rollback runs no pre-upgrade hook, and it removes the network policies of this chart. Do not run `helm upgrade` with the older chart while the network policies of this chart are on: the Jobs and hooks of the older chart use `restartPolicy: Never`, the first connection of each new pod fails in the delay of the network policy controller (some seconds), and the upgrade stops at a pre-upgrade hook (for example `ows-api-migrate`: `BackoffLimitExceeded`).
- After a failed upgrade, first roll back to the last deployed revision (the revision before the failed one), not to an older one. Helm takes the manifest of the failed revision as the base of its patch. When the objects in the cluster have a preStop hook of another kind than that manifest (the sleep action of this chart, the exec hook of an older chart), the patch puts both kinds in the hook, and Kubernetes refuses it: `lifecycle.preStop.sleep: Forbidden: may not specify more than 1 handler type`.
- A failed upgrade from an older chart to this chart, and then `helm rollback` to the older revision, works: the manifest of the failed revision has the sleep action, and the older revision the exec hook. Tested on k3s with the chart before this one: an upgrade that failed after the objects were in the cluster (the preStop hooks with the sleep action, 23 network policies), and an upgrade that failed at a pre-upgrade hook. Each `helm rollback` to the last deployed revision gave the release `deployed`, the exec hooks of the older chart (one handler each) and no network policy.

## The type of the audit bucket

The audit bucket of the wallet has a type (`organisationWallet.audit.bucket.type`, see [Audit log](audit-log.md#audit-bucket)). The default is `s3`: an S3 store with Object Lock and a default retention in compliance mode, with the values `endpoint`, `region` and `accessKey`. An installation whose bucket is a Google Cloud Storage bucket (the values `name`, `project` and `credentials` of the earlier releases) sets `type: gcs` before the upgrade: without it, the render stops with "organisationWallet.audit.bucket.endpoint is required with type s3". An installation without a bucket changes nothing.

## The PDF files of the wallet in the database

From the release that keeps the PDF files of the wallet in its database
(the files that a verifier uploads and the signed PDFs of the QES
presentations), the wallet has no file store: the values
`organisationWallet.storage.*` are gone. Remove the block `storage` of
`organisationWallet` from your values files before step 2: the schema of
the chart refuses it (`Additional property storage is not allowed`). The
Secret of the service account of the bucket is no longer mounted.

The wallet does not read the bucket: the files in it stay there. The PDF
files now have the backups and the replication of the wallet database.
The wallet keeps a signed PDF 30 days after the signature, only to give
it to the relying party, which keeps its own copy.

## The workers and the clock of the wallet

From the release that runs the background work of the wallet on the queues of Valkey, the chart runs the worker groups and the clock (see [Workers and clock](workers.md)). Before step 2:

1. The NATS user of the workers. `scripts/make-keys.sh` of this chart version makes it for a new installation. For an installation that exists, make the key pair with the api image and add it:

   ```bash
   docker run --rm --platform linux/amd64 --user "$(id -u):$(id -g)" -v "$PWD:/out" -w /out --entrypoint /app/bin/igrant-api \
     <registry>/api:<release tag> keys generate-nats-seed --file nats-wallet-worker.seed   # prints the public nkey
   kubectl -n ows create secret generic ows-nats-wallet-worker --from-file=seed=./nats-wallet-worker.seed
   ```

   Add `walletWorker: {nkey: <the public nkey>, seedSecret: ows-nats-wallet-worker}` to `nats.auth.users` in `values-keys.yaml`, then delete the seed file. Without it, the render stops with "set nkey and seedSecret for nats.auth.users.walletWorker". With an external NATS, add the user of the ConfigMap `<release>-nats-authorization` to your server.
2. Your own Valkey or Redis (`redis.mode: external`): create the ACL users `wallet-worker` and `wallet-clock` with the rights of the other wallet users (see [Redis](redis.md#acl-users)), and their password Secrets (`redis.users.walletWorker.passwordSecret`, `redis.users.walletClock.passwordSecret`). The bundled Valkey gets the two users from the chart: its pods restart one at a time with the new ACL file.
3. Network policies: the egress profile `auditBucket` belongs to the role `wallet-worker` now. If your values give it to `wallet-scheduler` (`networkPolicy.egress.roles.wallet-scheduler`), move it to `wallet-worker`: else the render stops with "the egress profile \"auditBucket\" is not allowed for the network role \"wallet-scheduler\"".
4. Stop the scheduler before the upgrade: the migration hook removes the jobs that the workers now run, and the scheduler of the earlier release must not run them while the hook runs.

   ```bash
   kubectl -n ows scale deployment/ows-wallet-scheduler --replicas=0
   ```

   A chart version with the scheduler gives it its replica again; from the release without the scheduler, see [The removal of the scheduler](#the-removal-of-the-scheduler).

The roles hook makes the new database role `<prefix>_clock` (a new key `clock` of the Secret `<release>-wallet-database-roles`, with a random value). With an audit bucket, the workers write the anchor copies and the exports: the scheduler no longer mounts the credentials of the bucket.

Check after step 3: the Deployments `ows-wallet-worker-main`, `ows-wallet-worker-maintenance` and `ows-wallet-clock` are ready, and exactly one clock leads (see [Workers and clock](workers.md#check)).

## The export index of the audit log

From this chart version (with the wallet image of organisation-wallet-suite#731), the hook Job `<release>-wallet-export-index` runs `audit partitions index` after each install and upgrade (post-install and post-upgrade, after the migration hook; see [Audit log](audit-log.md#the-export-index)). The migration hook (pre-upgrade) does not build this index, so it stays short.

Helm waits for a hook Job until it ends, at most `--timeout` (default 5 minutes). On a normal release the step ends in seconds. On the FIRST upgrade to this version, a database with large months that are not exported yet (the current month and the month before) needs one build of the index for each such partition: for a month of 200 GB, from about half an hour to some hours (each build has a statement timeout of 6 hours). For that upgrade:

1. Find the size of the partitions of the audit events in the wallet database: `SELECT inhrelid::regclass, pg_size_pretty(pg_total_relation_size(inhrelid)) FROM pg_inherits JOIN pg_class p ON p.oid = inhparent WHERE p.relname = 'audit_event' ORDER BY pg_total_relation_size(inhrelid) DESC;`. Only the months that are not exported yet need the build.
2. With large partitions, give `helm upgrade` a long timeout and `--wait`, for example `--wait --timeout 8h`. With `--wait`, the hook starts after the new pods are ready, so the build does not wait for the long transactions of old pods (an export of the earlier release). The new pods run as soon as the rollout ends; only the end of the command waits for the Job.
3. If Helm stops at its timeout, `helm upgrade` reports `post-upgrade hooks failed` and the release is `failed`, but all objects of the release are in place, and the Job runs on until it ends. Watch it with `kubectl -n ows logs -f job/ows-wallet-export-index`: it ends with `audit partitions index: built the export index of N partitions`. The next `helm upgrade` is normal. Do not start the next upgrade while the Job runs: the hook of the next upgrade deletes the Job, and PostgreSQL completes the build in progress, but the build holds the lock of the step until it ends. The new run does not wait for the lock: it exits 1 (`another run builds the export indexes now`), the Job fails after its retries (in about 1 to 2 minutes), and that release is `failed` too. After the build ends, run `helm upgrade` again.

**Do not use `--atomic` (Helm 4: `--rollback-on-failure`) for this upgrade**, unless its `--timeout` is above the sum of the index builds. With `--atomic`, a post-upgrade hook that runs longer than the timeout fails the upgrade (`post-upgrade hooks failed`), and Helm then rolls the release back to the earlier manifests and images. The migration hook has already moved the schema, so the wallet pods of the earlier release stop (see [Rollback](#rollback)).

While a month waits for its index, its export waits too: the worker logs a warning for each such month, and the gauge `ows_audit_export_index_waiting_partitions{scope}` is above 0 (the alert `AuditExportIndexWaiting` after 8 hours). For the details of the first run, see the wallet documentation, [The export index](https://github.com/L3-iGrant/organisation-wallet-suite/blob/main/docs/get-started/operations/audit-log.md#the-export-index).

## The TLS of NATS

From the release with the TLS of NATS, the bundled NATS uses TLS for the clients and mutual TLS for the routes (see [NATS users](nats-users.md#tls)). The upgrade restarts the NATS pods one at a time. A server with TLS does not accept a route without TLS: until the third server has restarted, the cluster can lose its majority, and JetStream does not answer for some minutes. The processes connect again with TLS. The outbox of each service sends the events again; an API call that sends a NATS command in that time gets an error. Do this upgrade in a maintenance window.

The service and config pods of the wallet get a memory limit of 1 GiB (`organisationWallet.service.resources`, `.config.resources`).

## NATS 2.14

From this chart version, the bundled NATS is 2.14.10 (before: 2.12.3): the 2.12 line gets no more fixes. The upgrade restarts the NATS pods one at a time; the JetStream store stays (2.14 reads the store of 2.12). A rollback of the chart takes NATS back to the version of the earlier release: NATS supports a downgrade of its store only to 2.11.9 or later. The rollback from 2.14.10 to 2.12.3 and the roll forward were tested with all streams, consumers and messages (`tests/nats-store.sh --earlier-image`). Do not set a tag of 2.15 or later (see [NATS users](nats-users.md#the-version-of-nats)).

## The internet profiles of the network policies

From this chart version, with `networkPolicy.enabled`, the egress profiles `internet` and `internet-any-port` allow the public IPv6 addresses too (`::/0`). Consent and the wallet roles have `internet-any-port` now (before: `internet`, ports 443 and 80), as the api and the webhook handler have: a URL of an organisation, a customer or another vendor can have any port. The wallet roles also have `platform` (the public hosts of this platform). The `except` lists exclude the private, shared and link-local IPv4 ranges, the unique local, link-local and multicast IPv6 ranges, and the NAT64 images of the IPv4 ranges that are never public (see [Network policies](network-policies.md#ipv6-and-nat64)). If your values give `networkPolicy.egress.profiles.internet`, `.internet-any-port` or `networkPolicy.egress.roles`, your lists replace the lists of the chart: compare them with `values.yaml` of this version. The api and the webhook handler do not have the profile `platform`: for a webhook receiver behind the ingress controller of this cluster, see [Network policies](network-policies.md#receivers-behind-the-ingress-controller-of-this-cluster).

## The SSRF guards

From this chart version, the notes of `helm install` and `helm upgrade` warn when a values file turns an SSRF guard off: `api.extraConfig.OutboundHttp.ssrfProtectionDisabled: true` (the api core and the webhook handler), `consent.extraConfig.OutboundHttp.ssrfProtectionDisabled: true` (consent) or `organisationWallet.extraConfig.ssrf_protection.enabled: false` (the wallet). Such a role then calls private, loopback, link-local and cloud metadata addresses for the URLs of organisations, customers and other vendors. Remove the key, and allow only the private hosts that you need (see [Security settings of the containers](security-context.md#the-ssrf-guards); the wallet: `organisationWallet.ssrf.allowedPrivate`).

## The TLS of the database

The bundled PostgreSQL always serves TLS from this release, also with `database.tls.enabled: false`. A release before it served TLS only with `database.tls.enabled: true`. To turn the TLS of the components on for a bundled server that runs without TLS:

1. Upgrade to this release with your values (`database.tls.enabled: false`). The upgrade makes the Secret `<release>-postgres-tls` and restarts the server with TLS.
2. Upgrade again with `database.tls.enabled: true`. The hooks and the pods connect with TLS and verify the server with its CA.

Do not do the two steps in one upgrade: the hooks of that upgrade connect with TLS to the server of the earlier release, which does not serve TLS yet, and they stop.

## The removal of the scheduler

From the release without the scheduler, the workers run all the background work of the wallet, and the clock sends the cron actors (see [Workers and clock](workers.md)). The image has no `start-scheduler`. The migration hook runs the revision `b04698aed63e`: it drops the job store table `public.apscheduler_jobs` with its grants. The clock file has only the log level, the database, Valkey and its health port.

1. Remove the values of the scheduler from your values files, else the render stops: `organisationWallet.scheduler`, `nats.auth.users.walletScheduler`, `redis.users.walletScheduler`, and `networkPolicy.egress.roles.wallet-scheduler`.
2. Stop the scheduler before the upgrade: the migration hook drops its table.

   ```bash
   kubectl -n ows scale deployment/ows-wallet-scheduler --replicas=0
   ```

3. Upgrade (step 3 above). Helm deletes the Deployment `<release>-wallet-scheduler` and the key `scheduler.yaml` of the ConfigMap `<release>-wallet`. The NATS user `wallet-scheduler` leaves the configuration of the bundled NATS, and the Valkey user `wallet-scheduler` leaves the ACL files of the bundled Valkey (the Valkey pods restart one at a time).
4. Delete the Secret of the NATS seed of the scheduler (`kubectl -n ows delete secret ows-nats-wallet-scheduler`, the name of your `seedSecret`). With an external NATS, remove the user `wallet-scheduler` from your server. With your own Valkey or Redis, remove the ACL user `wallet-scheduler` and its password Secret.

Check: no pod `ows-wallet-scheduler`, the workers and the clocks are ready, and exactly one clock leads (see [Workers and clock](workers.md#check)).

A rollback to a release with the scheduler needs the job store table again: the downgrade of the migration to `287d66228c5a` with the image of this release, then the earlier release (see [Rollback](#rollback)).

## The size of the bundled database server

From the release with the connection budget, the bundled PostgreSQL has `max_connections` 250 and the memory 2048Mi (requests and limits of `database.resources`), so that the pools of the default values fit (see [Database](database.md#connection-budget)). The upgrade restarts the server once: the components lose their connections for some seconds and connect again. If your values set `database.postgresql.parameters.max_connections` or `database.resources`, check them with the rule: the render stops when the pools of your release need more.

From the release with the health connections, the api core, the webhook handler, the gateway and consent each open one more connection to the database for each pod, outside their pools (a check every 2 seconds). The connection budget counts it: with the default values the pools need 227 connections (15 free). A values file with more replicas or larger pools and a `max_connections` near the earlier sum can now stop the render: then raise `max_connections` and `database.resources` together (see [Database](database.md#connection-budget)).

## The Play Integrity keys of the wallet

From the release that checks the Play Integrity token of an Android
wallet unit locally (the workers and Redis plan, T2), the wallet no longer
calls Google with a service account. It decrypts and verifies the token of
a classic Play Integrity request with the response encryption keys of the
app in the Play Console. The value `organisationWallet.walletUnit.playIntegrity.key`
(the service account JSON) is gone: the schema of the chart refuses it
(`Additional property key is not allowed`), and the service account is no
longer mounted.

With the production checks on (`organisationWallet.walletUnit.productionChecksEnabled`),
before step 2:

1. In the Play Console of the app (Play Integrity API, "Response
   encryption"), choose "Manage and download my response encryption keys",
   and turn on the device attributes of the integrity verdict.
2. Put the decryption key and the verification key (the base64 text of
   each) in a Secret, with the keys `decryption-key` and
   `verification-key` (or set `decryptionKeyKey` and `verificationKeyKey`).
3. Set `playIntegrity.existingSecret` and
   `organisationWallet.walletUnit.androidSigningCertificateDigests` (the
   SHA-256 of the app signing key certificate, from "App signing" in the
   Play Console). Without the digest the render stops. The key
   attestations and the registration of an Android wallet unit check the
   same digests.

The apps of the same release make classic Play Integrity requests. An
installation with the production checks off changes nothing.

## The App IDs of the iOS wallet apps

From the release with `organisationWallet.walletUnit.appAttest.appIds`,
the App ID of the iOS wallet app is a value of the chart, not a constant of
the image. The default is the App ID of the iGrant.io Data Wallet app
(`Y9726WB7V8.io.iGrant.DataWallet`), so an installation with this app
changes nothing.

An installation with another iOS app sets the App ID of that app
(`<Team ID>.<bundle id>`), or the App IDs of all its iOS apps. The service
pods accept the App Attest objects of each App ID of the list. A wallet unit
does not keep the App ID of its registration: when you remove an App ID,
the wallet units of that app get no new WIA and no key attestation. With
the production checks on, an empty list stops the render.

## The chart name platform

The name of the chart is `platform`. Earlier releases of the chart had the name `organisationwallet`. From a Helm repository, the chart is `<repository>/platform`; earlier it was `<repository>/organisationwallet`.

The chart puts the value of `nameOverride`, else its name, in the label `app.kubernetes.io/name`. This label is in the selectors of the Deployments and the StatefulSets, and Kubernetes does not let an upgrade change a selector. Without `nameOverride`, the upgrade of a release that was installed from the chart `organisationwallet` stops with `field is immutable`.

Before step 2, add this line to `my-site.yaml`, and keep it for all later upgrades of the release:

```yaml
nameOverride: organisationwallet
```

Check after step 2: the render shows the old label, for example `helm template ... | grep -m 1 'app.kubernetes.io/name'` shows `app.kubernetes.io/name: organisationwallet`.

A new installation does not set `nameOverride`: its label is `platform`. The label `helm.sh/chart` has the new chart name in all installations (`platform-<version>`); it is not in a selector.

## The webhook events and the cache clears of the wallet

From the release with one kind of webhook event for the issuer, the verifier and the holder, the wallet publishes its webhook events on `ows.*.evt.webhook_event`, and the webhook handler reads them with the durable consumer `api-webhook-event` (see [NATS users](nats-users.md#streams-consumers-and-buckets)). The service and config pods of the wallet also send and get the clears of their process caches on `ows.cache.cleared` (core NATS). The chart gives the NATS users of the wallet roles, the API core and the webhook handler the new rights. With an external NATS, before step 3, give your server the users of the new release (the render of step 2 has them in the ConfigMap `<release>-nats-authorization`): without them, the API core and the webhook handler do not start, the wallet cannot publish its webhook events, and the service and config pods of the wallet are not ready.

At their start, the API core and the webhook handler delete the consumers of earlier releases: `api-webhook-issue-credential`, `api-webhook-credential`, `api-webhook-present-proof` and `api-webhook-presentation`. An event of the earlier release that waits in one of these consumers at that time gives no webhook.

The webhook handler sends the command `ows.cmd.*.issuance.revoke` to revoke the earlier Authenticator credential of an admin. The command of the earlier releases, `ows.cmd.*.credential_history.set_revocation_status`, is not in the wallet of this release, and the NATS user `apiWebhook` gets only the new subject. With an external NATS, give your server this user of the new release before step 3, with the other users: without it, NATS refuses the revocation, and the earlier Authenticator credential stays valid.

The webhook handler reads each event from the view `wallet_read_v1_webhook_event` of the wallet database, and the API core and the webhook handler are ready only when this view exists. The migration hook of the wallet makes the view, and the read access hook gives the read-only user of the api the right to read it, before the pods change. Upgrade the api and the wallet together, with one `global.imageTag`.

## The queued revocations and the statistics of the issuer

From the release that queues the revocations of the issuer status lists and counts the issuances in counters:

- The migration hook adds the revocation queue (`issuer.status_list_change`), the issuance counters (`issuer.issuance_counter`, `issuer.issuance_counter_change`) and the end of the grant of each open issuance (`expires_at`). It gives the status `expired` to the open issuances whose grant ended, without a webhook event. The grant step gives the rights of the new tables (the data scope `issuer`).
- The pods of the new release queue each revocation, and only the workers of the new release write the queued revocations into the status lists (see [Workers and clock](workers.md#status-list-writes)). During the rollout, the pods of the earlier release write the lists at once. Step 3 changes the Deployments of the servers and of the workers together: do not scale the worker groups or the clock to 0. Check after step 3: `max(ows_status_list_change_age_seconds)` stays at 60 or below.
- About 10 minutes after the migration, a worker counts all issuances once for the statistics of the issuer (a durable job of `issuance_counter.reconcile`, queue `maintenance`); the same actor runs each night. Until this first count ends, the statistics count only the issuances that had a step after the upgrade.
- The scopes `issuer` and `authorisation_server` of the audit log get 8 sub-chains for each organisation (see [Audit log](audit-log.md#settings)): each credential request writes an event of the scope `issuer`, and each token request an event of the scope `authorisation_server`. During the rollout, the pods of the earlier release append to one chain: this is safe.

Add the alerts of the issuer to your monitoring (see [Workers and clock](workers.md#probes-and-metrics)).

## The tables of the issuances

From the release that keeps each issuance in tables by its life cycle (the issuance, its claims, its protocol session, its evidence, each issued credential and its token):

- The migration hook adds the tables `issuer.issuance`, `issuer.issuance_claims`, `issuer.issuance_session`, `issuer.issuance_evidence`, `issuer.issued_credential_token` and `issuer.credential_definition_version`, and columns and 4 indexes of `issuer.issued_credential`. The grant step gives the rights of the new tables (the data scope `issuer`). The indexes are made in the migration transaction: until the migration commits, the pods of the earlier release cannot write `issuer.issued_credential`, and their credential requests wait. On a large installation, measure the time of the migration on a copy of the database, and do the upgrade at a time with few issuances.
- The migration adds the extension `pg_trgm` of PostgreSQL, for the search of the issuances by a part of the holder name. The bundled server and the server of Compose have it. An external server must allow it: see [External PostgreSQL](database.md#external-postgresql).
- The rows of `issuer.credential_issuance` stay. About 10 minutes after the migration, the workers start to copy them into the new tables (`issuance.backfill`, queue `maintenance`), and each day at 04:10 UTC the reconcile copies the rows that are still missing. A new pod that reads an issuance that is not copied yet copies it at once. Check after step 3: `issuance-backfill status` shows the progress, and the copy is complete when `progress.applied` is `true` and `counts.missing` and `counts.changed` are `0` (see [Workers and clock](workers.md#the-copy-of-the-issuances)). Add the alert on the warning of the reconcile to your log system.
- During step 3, the pods of the earlier release and of the new release run together for a short time. A pod of the earlier release writes only `issuer.credential_issuance`, and the new pods copy its changes again at their next read. A pod of the earlier release does not see an issuance that a new pod started: a wallet request that it gets for such an issuance fails with "not found". Do step 3 at a time with few issuances.
- The retention purge deletes the token of an issued credential 30 days after the issue (`organisationWallet.retention.issuedCredentialTokenDays`, see [Audit log](audit-log.md#retention-purge)). The copy copies only the tokens that are younger.
- The read view of the issuances for the api keeps its name and its columns: no action.
- A later release drops `issuer.credential_issuance`. Its migration stops (exit code 1) while the copy is not complete. Before you upgrade to that release, run this release until `issuance-backfill status` shows the copy complete. Do not go from an earlier release to that release in one upgrade: the copy needs the workers of this release.

## The platform operator

From the release with the platform operator, an installation has one platform operator organisation. Its platform admins add, suspend and delete the other organisations in the dashboard, and they set the features of each organisation (see [Install](install.md#after-the-installation-the-other-organisations-and-admins)). Only the command line gives an organisation the platform operator mark and gives the first platform admin right.

An installation that exists has no platform operator organisation after the upgrade. The organisations and their admins work as before, but the functions of a platform admin stay hidden in the dashboard until you do the steps of this section. Do not use the Job `api.jobs.bootstrapPlatform` for an installation that exists: it is for a new installation. With an e-mail address that no admin has, it makes a new organisation with the platform operator mark, and then no organisation that exists can get the mark.

Removed in this release of the API:

| Removed | Use |
| --- | --- |
| The command `igrant-api iam set-organisation-login` | A platform admin suspends and resumes an organisation in the dashboard (`PUT /v4/onboard/platform/operator/organisation/{organisationId}/status`). Change each script that calls the command. |
| The route `POST /v4/onboard/platform/organisation` and the API key scope `organisation:create` | A platform admin adds an organisation in the dashboard (`POST /v4/onboard/platform/operator/organisation`). No API key can make an organisation. |
| The member `isWalletProvider` in the body of `PUT /v4/config/ows/wallet/deployment` | No route sets the wallet provider flag after the deployment of a wallet: see item 2 below. |

### Before the upgrade

Do these items with the earlier release, before step 2.

1. Choose the organisation that becomes the platform operator. The platform operator is always the wallet provider organisation of the installation:

   - when one organisation is the wallet provider, only this organisation can be the platform operator;
   - when no organisation is the wallet provider, choose an organisation with no wallet, or do item 2 for the organisation that you choose.

   The command `platform set-operator` refuses an organisation whose wallet is deployed and is not the wallet provider, and each organisation when a different organisation is the wallet provider. To read the id of an organisation and the state of its wallet, use an API key of the organisation with the scopes `onboard` and `config`:

   ```bash
   curl -s https://api.example.org/v4/onboard/platform/organisation -H "Authorization: ApiKey $API_KEY"
   curl -s https://api.example.org/v4/config/ows/wallet/deployment -H "Authorization: ApiKey $API_KEY"
   ```

   A release without the `/v4` routes has them at `GET /v2/onboard/organisation` and `GET /v2/config/digital-wallet/openid`. The first answer has the `id` of the organisation. The second answer has `statusStr` (`Deployed` for a deployed wallet) and `isWalletProvider`. An organisation with `"isWalletProvider": true`, or with a wallet that is not deployed, needs no more work before the upgrade.

2. Only for an organisation whose wallet is deployed and is not the wallet provider (and no other organisation is the wallet provider): make its wallet the wallet provider with the earlier release. The new release has no route and no command for this. An admin of that organisation, or an API key of it with the scope `config`, sends this request one time to the API of the earlier release:

   ```bash
   curl -s -X PUT https://api.example.org/v4/config/ows/wallet/deployment \
     -H "Authorization: ApiKey $API_KEY" -H 'Content-Type: application/json' \
     -d '{"isWalletProvider": true}'
   ```

   A release without the routes `/v4/config/ows/...` has the same route at `PUT /v2/config/digital-wallet/openid`. A build of the API that has the command `platform set-operator` and still sets the flag in this route (it refuses the member `isWalletProvider`) takes the body `{}` for the organisation with the platform operator mark.

   Check: the answer, and `GET` of the same path, show `"isWalletProvider": true`. An answer `Wallet provider already exists` usually means that a different organisation is the wallet provider: that organisation is the only one that can be the platform operator.

   If you did not do this item before the upgrade, the organisation cannot become the platform operator in the new release. Contact iGrant.io.

3. External NATS (`nats.enabled: false`): give your server the users of the new release before step 3 (the render of step 2 has them in the ConfigMap `<release>-nats-authorization`). The user `api` gets the right to publish `api.v1.evt.organisation.deleted`. Without it, the API cannot publish the deletion of an organisation, and consent and the wallet keep the data of a deleted organisation. The bundled NATS gets the users from the chart.

4. Decide the first value of the feature gate: see [The feature gate](#the-feature-gate).

### The order of the services

A release that changes the messages between the services has a release order: consent, then the wallet, then the API and the gateway. The API is the last one because it sends the new messages.

What the chart does:

- The migration hooks run before a pod changes, in the order of step 3: the API (also the tables of the gateway, which are in the API database), consent (`0005_organisation_purges`) and the wallet.
- Then Helm changes all Deployments in one step. The chart cannot start the new pods of consent before the new pods of the wallet, or the new pods of the wallet before the new pods of the API.

What this means for the time of the rollout, while pods of two releases run together:

- A pod of the earlier consent release refuses the answer of a new API pod to its read of an organisation (the answer has the new member `suspended`). Such a request of consent fails until the consent pods of the new release are ready.
- A suspension or a deletion of an organisation does not reach a pod of the earlier consent release or of the earlier wallet release. In the first upgrade to this release this cannot occur: no platform admin exists until you do [After the upgrade](#after-the-upgrade).

What you must do:

1. Do the upgrade in a maintenance window, with `--wait` (step 3).
2. Continue only when all pods of consent, the wallet, the API and the gateway are of the new release and ready: `kubectl -n ows get pods` shows no pod of the earlier ReplicaSets, and `kubectl -n ows rollout status deployment/ows-consent` (also `ows-wallet-config`, `ows-wallet-service`, `ows-api`, `ows-api-webhook`, `ows-gateway`) shows `successfully rolled out`.
3. Do [After the upgrade](#after-the-upgrade) only then. In later upgrades, do not suspend, resume or delete an organisation while a rollout runs.

A rollback of the images after a platform admin suspended or deleted an organisation is not supported: the earlier releases do not know these states (see [Rollback](#rollback)).

### After the upgrade

1. Give the organisation the platform operator mark, and give one of its admins the platform admin right. The Job `api.jobs.platformOperator` runs `igrant-api platform set-operator`, then `igrant-api platform grant-admin`. Write these values to a file `platform-operator.yaml` and run the `helm upgrade` of step 3 with this file:

   ```yaml
   api:
     jobs:
       platformOperator:
         enabled: true
         organisationId: 6731f0c2a1b2c3d4e5f60789
         adminEmail: admin@example.org
   ```

   Check: `kubectl -n ows get jobs` shows `ows-api-platform-operator-<revision>` as `Complete`. The logs show the result of each command:

   ```bash
   kubectl -n ows logs job/ows-api-platform-operator-<revision> -c set-operator   # {"organisationId":"...","changed":true}
   kubectl -n ows logs job/ows-api-platform-operator-<revision> -c command        # {"adminId":"...","email":"...","changed":true}
   ```

   When `set-operator` refuses the organisation, the Job is `Failed`, no admin gets the right, and the log of `set-operator` has the cause. The two commands change nothing when the result exists, so a second run is safe.

   You can run the same commands in an api pod, without the Job:

   ```bash
   kubectl -n ows exec deploy/ows-api -c api -- /app/bin/igrant-api platform set-operator --organisation-id 6731f0c2a1b2c3d4e5f60789 --config=/etc/igrant-api/config.yaml
   kubectl -n ows exec deploy/ows-api -c api -- /app/bin/igrant-api platform grant-admin --email admin@example.org --config=/etc/igrant-api/config.yaml
   ```

2. Check the result. The command reads only, and it prints no secret:

   ```bash
   kubectl -n ows exec deploy/ows-api -c api -- /app/bin/igrant-api platform status --config=/etc/igrant-api/config.yaml
   ```

   The JSON line of the output has `operatorOrganisationId` with the id of your organisation, and the admin in `platformAdmins`. A line `WARNING: the wallet of the organisation is deployed and is not the wallet provider` in the log of `set-operator` means that the installation has no wallet provider: contact iGrant.io.

3. Run `helm upgrade` again without `platform-operator.yaml`: this turns the Job off.

4. The admin logs in to the dashboard. The gateway and the API read the platform operator and the platform admins again within 60 seconds. A platform admin needs a password of 15 characters or more: an admin with a shorter password sets a new password at this login. Each other new password needs 12 characters or more: the API checks a password only when it is set, so a shorter password that exists still works. The Job `api.jobs.registerAdmin` fails when the password of a new admin has less than 12 characters. Each new password also needs at least one special character, for example `!`, `#` or `%` (a space does not count). This rule applies only when a password is set or changed: the accounts of today continue to log in, with no forced change. The Jobs `api.jobs.bootstrapPlatform` and `api.jobs.registerAdmin` fail when the password of a new admin has no special character, so make sure that the Secret of such a Job has one.

5. An organisation that you stopped with `iam set-organisation-login` before the upgrade stays suspended in the API, but consent and the wallet do not know it. A platform admin sends the suspend request for it one time in the dashboard: the request sends the state to the two services.

Rules that an operator must know:

- An installation has one platform operator organisation. No command moves or removes the mark.
- `platform revoke-admin --email <e-mail>` removes the right of an admin. It refuses the last platform admin unless you add `--allow-last`. After the first platform admin exists, a platform admin gives and removes the right in the dashboard.
- The wallet login of the admins (`api.adminAuth.walletLogin.organisationId`): with an empty value, the platform operator organisation is the organisation of the wallet login, when it is the wallet provider and its OIDC extension is on. An installation that sets the value keeps its organisation.
- The API keeps the actions on the accounts of the admins for 365 days (`AccountActions.RetentionDays` in `api.extraConfig` sets another time).
- The deletion of an organisation cannot be undone. No background job repeats a failed step of the API: a platform admin sends the request again until no step is left (see [Install](install.md#after-the-installation-the-other-organisations-and-admins)).

## The feature gate

From the release with the feature gate, the gateway refuses a route of a product feature that is off for the organisation of the credential: `403` with `errorKey` `feature_disabled`. The value is `gateway.features.enforce`, and its default is `true`, the default of the gateway. An organisation cannot set its own features: a platform admin sets them in the dashboard.

The platform has four product features: `issuerVerifier`, `walletUnit`, `consentManagement` and `dataDisclosureAgreements` (see [The four feature switches](#the-four-feature-switches)). The migration hook of the API turns `dataDisclosureAgreements` on for each organisation that exists, and it gives each organisation its four features. An organisation that uses the routes of a feature that is off for it (for example with an API key) gets `403` from the first request after the upgrade.

To check the features before the gate is on:

1. Upgrade with the gate off:

   ```yaml
   gateway:
     features:
       enforce: false
   ```

2. List the features that are off, as the owner user of the API database (`igrant_api`):

   ```sql
   SELECT "id", "doc" ->> 'name' AS "name", "feature"
   FROM "organizations",
     unnest(ARRAY['issuerverifier', 'walletunit', 'consentmanagement', 'datadisclosureagreements']) AS "feature"
   WHERE ("doc" -> 'configuredfeatures' -> "feature") IS DISTINCT FROM 'true'::jsonb
   ORDER BY "name", "feature";
   ```

   The query lists the 4 product features. A key that is not in the record reads as off.

3. For each row, decide with the organisation. A platform admin turns a feature on in the dashboard (row menu "Manage Features"): this needs the platform operator (see [After the upgrade](#after-the-upgrade)).
4. Remove the value (or set `enforce: true`) and run the upgrade again. The gateway pods restart with the gate on. To see the refusals, search the log of the gateway pods for `route of a disabled feature refused`.

Use `enforce: false` also for an emergency: the gateway then refuses no route for a feature, and the features only show and hide the areas of the dashboard. A gateway image of an earlier release does not know the key `Features` and does not start with it: use the chart and the images of one release.

## The four feature switches

From the release with the four feature switches, an organisation has four product features. They are the switches of the panel "Manage Features" of a platform admin:

| Switch | Key | What follows the switch | New organisation |
| --- | --- | --- | --- |
| Issuer & Verifier | `issuerVerifier` | The issuer, the verifier, the extensions, the files of the verifier, and the sandbox organisations | On |
| Wallet Unit (Holder) | `walletUnit` | The wallet unit of the organisation, and the sandbox organisations | Off |
| Consent Management | `consentManagement` | The users, the user requests, the privacy dashboard, the data agreements and the personal data | Off |
| Data Marketplace | `dataDisclosureAgreements` | The data disclosure agreements and the data space, with the data agreements | Off |

Getting Started, Account (the team, the data verifier users and the API keys), Webhooks and Activity Logs have no switch. They are always available, and a platform admin cannot turn them off for an organisation. The release before had 13 features, also for these functions.

What changes with the upgrade:

- **A new organisation has only Issuer & Verifier on.** Before, a new organisation also had the wallet unit, the consent management, the data agreements and the privacy dashboard on. A platform admin turns the other areas on for each organisation that needs them (see the steps below). Change each script that makes organisations and expects the old defaults.
- **The platform operator organisation has the four on.** The Job `bootstrapPlatform` makes it with them, the Job `api.jobs.platformOperator` (`igrant-api platform set-operator`) turns them on when it gives the mark, and the migration turns them on for the platform operator organisation that exists.
- **The organisations that exist keep what they can use.** The migration hook of the API (`0029_four_product_features`) changes the stored features of each organisation:

  | Before the migration | After the migration |
  | --- | --- |
  | Consent management, data agreements, personal data or privacy dashboard on | Consent Management is on. |
  | Issuer and verifier, wallet unit, data marketplace | They keep their values. |
  | A sandbox organisation that is not deleted, and the issuer and verifier and the wallet unit off | Issuer & Verifier is on, because the routes of the sandbox organisations now need one of the two. |
  | The platform operator organisation | The four are on. |
  | An organisation record with no features | The four are off. |
  | The 9 other keys (`gettingstarted`, `dataagreements`, `manageddata`, `privacydashboard`, `account`, `actionlogs`, `webhooks`, `files`, `sandbox`) | Removed from the record. |

  A second run of the migration changes no record.
- **The routes of the sandbox organisations** are available when Issuer & Verifier or Wallet Unit (Holder) is on. With the two off, they answer `403` `feature_disabled`.
- **The API takes the 4 keys and the preview `apiKeyScopesUi` only.** A request with one of the 9 removed keys gets `400` with a text that names the key. Change each client that sets features with the old keys.

Before the upgrade:

1. The gateway of the release before reads 13 features, and a key that is not in the record reads as off there. The migration hook runs before the pods change. Thus, until the new gateway pods run, the earlier gateway pods refuse the routes of Account, Webhooks, Activity Logs, the data agreements and the privacy dashboard for each organisation (`403` `feature_disabled`). To prevent this, turn the gate off with the chart of the release that you have, then upgrade with the gate off, then turn it on:

   ```yaml
   gateway:
     features:
       enforce: false
   ```

   Or do the upgrade in a maintenance window. A release from before the feature gate does not refuse a route for a feature: this step is not necessary for it.
2. List the organisations with a sandbox organisation and no wallet area, as the owner user of the API database (`igrant_api`). The migration turns Issuer & Verifier on for them:

   ```sql
   SELECT "o"."organisation" AS "id", "o"."name"
   FROM "organizations",
     LATERAL (SELECT "id" AS "organisation", "doc" ->> 'name' AS "name", "doc" -> 'configuredfeatures' AS "features") AS "o"
   WHERE ("o"."features" -> 'issuerverifier') IS DISTINCT FROM 'true'::jsonb
     AND ("o"."features" -> 'walletunit') IS DISTINCT FROM 'true'::jsonb
     AND EXISTS (
       SELECT 1 FROM "subwallets" AS "s"
       WHERE "s"."doc" ->> 'organisationid' = "o"."organisation"
         AND ("s"."doc" -> 'isdeleted') IS DISTINCT FROM 'true'::jsonb)
   ORDER BY "o"."name";
   ```

   To keep the area off for such an organisation, a platform admin turns Issuer & Verifier off for it after the upgrade. Its sandbox organisations stay in the database.

After the upgrade:

1. List the features of each organisation:

   ```sql
   SELECT "id", "doc" ->> 'name' AS "name", "f"."features"
   FROM "organizations",
     LATERAL (SELECT "doc" -> 'configuredfeatures' AS "features") AS "f"
   ORDER BY "name";
   ```

2. To turn an area on for an organisation, a platform admin logs in to the dashboard, opens the list of the organisations in the group "Wallet Provider (Orgs)", opens the row menu of the organisation, selects "Manage Features", and sets the switch. The change applies in each gateway pod within one minute. The same change with the API, with the access token of a platform admin:

   ```bash
   curl -X PUT https://api.example.org/v4/onboard/platform/operator/organisation/<organisationId>/features \
     -H "Authorization: Bearer <access token>" -H "Content-Type: application/json" \
     -d '{"walletUnit": true, "consentManagement": true}'
   ```

3. When you turned the gate off in step 1 before the upgrade, remove the value (or set `enforce: true`) and run the upgrade again.

A rollback of the images to the release before needs the 9 keys again: with the records of this release, the earlier gateway refuses the routes of Account, Webhooks and Activity Logs. Apply the down file `0029_four_product_features.down.sql` of the API and set the version of `schema_migrations` back to 28, in one transaction, before the earlier images start; or set `gateway.features.enforce: false` for the earlier release. The down file cannot restore the values from before the upgrade (see [Rollback](#rollback)).

## The limits of the installation

From the release with the input limits, the platform has a limit of the organisations of the installation and a limit of the organisation wallet units of the wallet provider. The default of each limit is 100. A limit refuses only a new organisation: the organisations and the organisation wallets that exist stay and work as before.

| Value | Configuration key | Range | At the limit |
| --- | --- | --- | --- |
| `api.limits.maxOrganisations` | `Limits.maxOrganisations` of the api and webhook files | 1 to 100 | The api refuses the create of one more organisation: `409` `organisation_limit_reached` |
| `organisationWallet.walletUnit.organisationWalletUnitsMax` | `wallet_unit.organisation_wallet_units_max` of the service, config and worker files | 1 to 100 | The wallet refuses the organisation wallet of one more organisation: `409` `organisation_wallet_unit.limit_reached` |

The two values are empty by default. With an empty value, the chart writes no key, and the api or the wallet uses its default (100). Set a value only with the images of the release with the input limits: an api or a wallet of an earlier release does not know the key and does not start with it.

The largest value of each limit is 100. You can set a smaller value, never a larger one: the chart refuses a value above 100. An installation with more than 100 organisations, or more than 100 organisation wallets, keeps them all after the upgrade, but it cannot make a new organisation.

To set a smaller limit, put the values in your values file (for example `my-site.yaml`) with the new `global.imageTag`, and run one upgrade:

```yaml
api:
  limits:
    maxOrganisations: 50
organisationWallet:
  walletUnit:
    organisationWalletUnitsMax: 50
```

Do not set a value below the number of organisations that exist: the organisations stay, but no new organisation can be made. To change a value later, change your values file and run the upgrade again: the api, webhook, wallet service, config and worker pods restart with the new configuration file.

To go back to an earlier release (see [Rollback](#rollback)), first remove the two values from your values files: the chart of an earlier release does not know them, and its images refuse the keys.

## The services of the installation

From the release with the installation services, an installation can be without consent or without the organisation wallet (see [Components](components.md#the-services-of-the-installation)). An installation that exists keeps all services: with all services, the chart writes the same configuration files as before, and you change nothing.

### Remove a service

1. In your values files, set `consent.enabled: false` (or `organisationWallet.enabled: false`), and remove `gateway.upstreams.consent.url` (or `gateway.upstreams.walletConfig.url`). Without consent, also set `privacyDashboard.enabled: false`.
2. Set `global.imageTag` to the release tag of this release or a later one: the api and the gateway of an earlier release do not start with the key `Installation`.
3. Run the upgrade (step 3 of the procedure at the top of this page).

Helm removes the pods, the Jobs, the Services and the ConfigMaps of the service. The data of the service stays: the chart deletes no database, no database user and no Secret with `helm.sh/resource-policy: keep` (for example the passwords in `<release>-postgres`). Without the wallet, the volumes of the bundled OpenBao also stay, with the keys of the wallet in them. The data of the organisations stays too:

- The stored features of the service stay on the organisation record, but they are not effective: the dashboard shows no area of the service.
- A webhook keeps its event types of the service, but gets no event of the service.
- An API key keeps its scopes of the service, but each route of the service answers `404` (`service_not_installed`).

### Add a service later

1. In your values files, set `consent.enabled: true` (or `organisationWallet.enabled: true`), or set the URL of the service of another release.
2. Run the upgrade.

The stored features, the stored webhook subscriptions and the stored API keys of the service apply again. A service that was installed before finds its data in its database. With the bundled OpenBao, the OpenBao pods start with their earlier volumes: unseal each pod (install step 5, item 2), and do not initialise OpenBao again.

Consent and the organisation wallet get the events of the api from the stream `API_EVENTS` (consent: the changes and the deletions of organisations; the wallet: the changes and the deletions of organisations and sandboxes). The stream keeps an event for 8 days. No tool sends an older event again.

- A service that you add for the first time has a new database: it misses nothing, and you do nothing.
- A service that you removed and add again does not get the events that are older than 8 days:
  - Consent, the suspensions and resumptions of organisations: no action. Consent reads each organisation from the api again when its local copy expires (after at most 15 minutes), and the answer of the api has the state of today.
  - Consent, the deletions of organisations: consent keeps the consent data of each organisation that a platform admin deleted while consent was not installed.
  - The wallet: the wallet keeps the wallets of each organisation and sandbox that a platform admin deleted while the wallet was not installed, and the api sent no wallet command in that time (for example the suspension of an organisation).

  The organisations list of the platform operator shows each deleted organisation with the status `deleting`, without the date. The action log of the platform operator organisation has the entry `organisation_deletion_started` with the date, but only for `api.actionLogRetentionDays` (default 30 days). Thus, keep a record of each organisation that you delete while a service is not installed. After the upgrade, contact iGrant.io support with this record to purge the data of these organisations in the service.

## The webhook event types

From the release with the installation services, the api no longer reads `Webhooks.events`. The effective features of each organisation select the webhook event types: an organisation with Consent Management gets all 9 consent event types, also `consent.auto_expiry`. An organisation whose Consent Management is off gets no `consent.*` and no `data.*` webhook events.

The chart no longer has `api.webhooks.events` in `values.yaml` and does not write `Webhooks.events` into the api file. A values file that still sets `api.webhooks.events` renders: the chart does not use the value, and the notes of the release tell you to remove it. Remove the value from your values files. A later release refuses it.

## The non-root containers

From the release with the hardened images, each container of the chart runs as a non-root user with a read-only root file system, no capability and the seccomp profile `RuntimeDefault` (see [Security settings of the containers](security-context.md)). The images of the api, the wallet and the dashboard of this release run as a non-root user, and the chart gives each pod the user, `fsGroup`, the sysctl of port 80 and the `emptyDir` volumes of its writable paths.

The chart and the images of this release belong together. Set `global.imageTag` and upgrade the chart in one step. Do not mix them:

| Combination | Result |
| --- | --- |
| This chart with the images of an earlier release | The dashboard does not start: its earlier image runs nginx as root and writes to its root file system (`mkdir() "/var/cache/nginx/client_temp" failed (30: Read-only file system)`). The api and the wallet of an earlier release run as the user 65532: the hooks of earlier chart versions run them so already. |
| An earlier chart version (or your values without the new settings) with the images of this release | The api and the wallet pods do not start: the user 65532 cannot read the Secret files (mode `0440`) without `fsGroup`. The api, the webhook handler and the dashboard cannot open port 80 without the sysctl `net.ipv4.ip_unprivileged_port_start=0`. |

Before step 2:

1. Your values files: when you set `podSecurityContext` or `containerSecurityContext` of `api`, `organisationWallet`, `enterpriseDashboard`, `nats` or `database`, Helm merges your keys into the new defaults. Remove a key that sets the user 0 or adds a capability. `global.podSecurityContext` and `global.containerSecurityContext` apply to each pod and container under the default of the component: a key that the component also sets (for example `runAsUser`) does not apply to it, and the notes of the release name such keys (see [Security settings of the containers](security-context.md#change-the-settings)). On OpenShift, set `runAsUser`, `runAsGroup` and `fsGroup` of each component to `null`.
2. Log files: the chart writes no log file. Remove `Log.file` from `api.extraConfig`, `gateway.extraConfig` and `consent.extraConfig`, and `log_file` from `organisationWallet.extraConfig`: else the render stops with "the chart writes no log file in Kubernetes". The processes log to stdout and stderr (the container log).
3. Uploads above 32 MiB: when you raised `gateway.proxy.maxBodyBytes.file` or `.default` above 32 MiB, set `api.tmp.sizeLimit` to at least that size and raise the memory limits of the api and of the webhook handler by the same size (see [Security settings of the containers](security-context.md#the-tmp-folder-of-the-api)). Else the render stops.
4. A policy engine of your cluster (for example Kyverno or Gatekeeper) that refuses sysctls: allow `net.ipv4.ip_unprivileged_port_start` for the pods of the api, the webhook handler, consent and the dashboard. Kubernetes allows it without a kubelet setting (a safe sysctl).
5. The workers: the `/tmp` of each worker pod is an `emptyDir` in memory of 64Mi, as in the other wallet pods. The monthly audit export of the wallet image of this release writes no local file. Remove `organisationWallet.workers.tmp` and the `tmp` of each worker group from your values files: else the render stops with "Additional property tmp is not allowed". This chart needs the wallet image of the same release (the streamed audit export): with an earlier wallet image, an export of a large month fills the `/tmp` of 64Mi and fails.
6. Kubernetes 1.30 or later: the pods stop with the sleep action of the preStop hooks (the images have no shell and no `sleep` program). Helm refuses the chart on an older cluster (`kubeVersion`).
7. Your own stop settings: each HTTP pod now sleeps `preStopSeconds` (10 s) before its stop signal, and the render stops when `terminationGracePeriodSeconds` does not cover the sleep and the stop of the server (see [Security settings of the containers](security-context.md#the-stop-of-a-pod)). The defaults are 40 s for the api, the gateway and consent. A values file that sets `terminationGracePeriodSeconds` to 35 gets the message of the budget: raise it.
8. Your own TLS certificates: the wallet of this release (Python 3.13) checks each TLS certificate strictly (RFC 5280). It refuses a server certificate without an authority key identifier, and a CA without a subject key identifier, the key usage `keyCertSign` or critical basic constraints. The certificates that the chart makes have them. Check each certificate that you give: the CA of an external PostgreSQL (`database.tls.caSecret`), your NATS certificate or the CA of an external NATS (`nats.tls.existingSecret`, `nats.tlsCa`), your Valkey certificate or the CA of an external Valkey or Redis, the CA of an external OpenBao:

   ```bash
   openssl verify -x509_strict -purpose sslserver -CAfile ca.crt server.crt   # "server.crt: OK"
   ```

   A certificate that fails needs a new certificate from its CA with the extensions `subjectKeyIdentifier = hash` and `authorityKeyIdentifier = keyid` (and a CA with `basicConstraints = critical, CA:true` and `keyUsage = critical, keyCertSign, cRLSign`).

During step 3:

- The bundled PostgreSQL restarts as the user `postgres` (999) with its data volume. The files of the data folder belong to this user already (the earlier image changed to it at the start).
- The bundled NATS pods restart one at a time as the user 65532. The NATS StatefulSet in the cluster runs NATS as root, so the chart gives `fsGroupChangePolicy: Always` for this rollout (the notes say so): at the first start, the kubelet gives the group 65532 (`fsGroup`) and the group rights to each file of the JetStream store, which root wrote. A large store takes more time to start (see [Security settings of the containers](security-context.md#the-jetstream-store)). Then the init container `store-check` checks that NATS can read and write each file of the store.
- The next upgrade after this one gives `fsGroupChangePolicy: OnRootMismatch` again (the value of `nats.podSecurityContext`): one more rolling restart of NATS. Later starts do not change the files.

Check after step 3: all pods are `Running` and `READY`, and `kubectl -n ows get pod ows-nats-0 -o jsonpath='{.spec.securityContext.runAsUser}'` shows `65532`.

Docker Compose: each service now runs with a read-only root file system. The configuration files of the components are files of `docker-compose/generated/`: `make configs` writes them from the templates of `compose.configs.yaml` with the values of `.env` (Python 3.8 or later on the host). Upgrade with `make secrets` and `make up`, not `docker compose up`: `make up` writes the files, sets `HOST_UID` and `HOST_GID` for `openbao-init`, and removes the containers of the earlier services `api-read-access` and `wallet-read-access` (`--remove-orphans`; the api image and the wallet image have no shell, so they are now four services, `api-read-access-wallet`, `api-read-access-consent`, `wallet-read-access-api` and `wallet-read-access-consent`: change your scripts and your monitoring that name the earlier services). NATS runs as the user 65532: at the first start, `nats-data-owner` gives each file of the volume `nats-data` with another owner (root, or the user 1000) to 65532; later starts write nothing. OpenBao (100:1000) and Valkey (999:1000) run as the users of their images, the owners of their volumes: their data does not change (see the [Compose README](../docker-compose/README.md#change-to-the-release-with-the-non-root-services)).

### A rollback to a release before the non-root containers

When you go back to an earlier release (see [Rollback](#rollback)), use its chart and its images together. NATS of the earlier release runs as root and can use the store: the files keep the group 65532. Each file that it writes has the mode 0600 and the owner root, so NATS of this release cannot read it, and the kubelet does not change it again by itself (the top folder of the volume has the group already).

The roll forward to this release:

- With `helm upgrade` (step 3): the chart finds the NATS StatefulSet of the earlier release in the cluster and gives `fsGroupChangePolicy: Always` for this rollout, as at the first upgrade. Nothing more to do.
- With another path, for example `helm rollback` to a revision of this release, or a tool that renders the chart without a cluster: the init container `store-check` stops each NATS pod whose store has such a file, with the message "cannot read and write this entry of the JetStream store". No stream is lost: the files stay as they are, and with 3 servers the other two keep the JetStream cluster. Then do one upgrade with the repair, and one more without it:

  ```bash
  helm upgrade ows ./platform-deployment -n ows <your values files> \
    --set nats.podSecurityContext.fsGroupChangePolicy=Always --wait --timeout 30m
  helm upgrade ows ./platform-deployment -n ows <your values files> --wait --timeout 15m
  ```

  The first upgrade changes each file of the store at each start of a NATS pod; the second gives `OnRootMismatch` again.
