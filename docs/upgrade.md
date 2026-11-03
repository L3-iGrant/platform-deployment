# Upgrade

This page upgrades an installation to a new release of the platform.

[Back to the contents](../README.md#contents)

1. Set `global.imageTag` in `my-site.yaml` to the release tag of the new version (from iGrant.io). The chart and the images of one release belong together: a new chart with the images of an older release can stop the pods (for example, the wallet refuses a configuration key that it does not know). Then read the `values.yaml` of the new chart version and adapt your files where necessary.
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

## The TLS of NATS

From the release with the TLS of NATS, the bundled NATS uses TLS for the clients and mutual TLS for the routes (see [NATS users](nats-users.md#tls)). The upgrade restarts the NATS pods one at a time. A server with TLS does not accept a route without TLS: until the third server has restarted, the cluster can lose its majority, and JetStream does not answer for some minutes. The processes connect again with TLS. The outbox of each service sends the events again; an API call that sends a NATS command in that time gets an error. Do this upgrade in a maintenance window.

The service and config pods of the wallet get a memory limit of 1 GiB (`organisationWallet.service.resources`, `.config.resources`).

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
