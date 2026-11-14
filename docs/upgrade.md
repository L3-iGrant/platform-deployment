# Upgrade

How to move an installation to a new release of the platform.

[Back to the contents](../README.md#contents)

1. Set `global.imageTag` in `my-site.yaml` to the release tag of the new version (from iGrant.io). A chart and its images belong to one release: a new chart with the images of an older release can stop the pods (for example, the wallet refuses a configuration key that it does not know). Then compare your files with the [Values reference](values-reference.md) of the new chart version, and adapt them where necessary.
2. Check the render with the new chart (`helm template`, as in install step 3).
3. Upgrade:

   ```bash
   helm upgrade ows ./platform-deployment -n ows \
     -f ./ows-keys/values-keys.yaml -f my-site.yaml \
     -f ./platform-deployment/profiles/exposure-envoy-gateway.yaml \
     --wait --timeout 15m
   ```

   Before any pod changes, the hooks of the release run in this order:

   1. The init hook (`ows-db-init`) connects as the admin user of the database server. It creates the database and the owner user of each enabled component that does not have them yet, and sets the passwords of the owner users.
   2. The wallet's roles hook (`ows-wallet-database-roles`) also connects as the admin user. It creates the wallet's database roles, sets their passwords and gives their grants.
   3. The migration hooks (`ows-api-migrate`, `ows-consent-migrate`, `ows-wallet-migrate`) update the database schemas. The wallet hook connects as the wallet's migrator role. After the grants, it creates the audit log partitions and drops the months older than the retention (see [Audit log](audit-log.md#partitions)).
   4. The wallet's read access hooks (`ows-wallet-read-access-api`, `ows-wallet-read-access-consent`) update the read-only users that the api and consent use to read the wallet database.

   Valkey is not a hook: it changes with the other resources. Its pods restart one at a time, and a Sentinel moves the primary to a replica before the primary stops (see [Redis](redis.md#bundled-valkey)). The first upgrade to a release with Valkey creates the Valkey pods and their volumes; the wallet pods then get their `redis` section.

   If a hook fails, the upgrade stops and the old pods keep running. Read the log of its Job, for example `kubectl -n ows logs job/ows-wallet-migrate`. After the upgrade, the hook `ows-consent-migrate-after` completes the consent data: it needs `--wait`. The new wallet pods start work only when the database schema is at the head of their release. They wait up to 600 seconds, then exit, and Kubernetes starts them again. See [Database](database.md#hooks-of-the-databases).

   An upgrade can turn a component on, for example `organisationWallet.enabled: true`. The hooks create its passwords, its database and its users before its migration hook runs. With `database.auth.existingSecret`, first add the password of the new database to your Secret (the key is the database name, for example `igrant_wallet`).

   The exit codes of the wallet migration hook (`migrate-database`):

   | Exit code | Meaning | Action |
   | --- | --- | --- |
   | 0 | The schema is at the head of the release, with all grants | None |
   | 1 | A revision failed | The log names the revision and the error. Fix the cause, or send the log to iGrant.io, then run the upgrade again. |
   | 2 | A configuration or connection error | Check the database values and the wallet's database roles (the roles hook ran before), then run the upgrade again. |
   | 3 | The grant step failed: the schema is at the head, but some grants are missing | Run the upgrade again: the hook gives the missing grants. |
   | 4 | The audit log partition step failed: the schema is at the head with all grants, but a partition is missing or a drop failed | Run the upgrade again: the hook completes the partitions. |
   | 5 | The database is ahead of this release and does not record it as compatible: a newer release migrated it with a revision that is not backward compatible. Nothing changed | Run the newer release again, or see [Rollback](#rollback). |

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

   Check: `kubectl -n ows exec ows-openbao-2 -- bao status` shows `Sealed false`. Go to the next pod only when this check passes. After the third pod, the `updatedReplicas` command shows `3/3`.

5. Bundled OpenBao: run `bootstrap.sh` again (install step 5, item 3). It changes only what the new version needs, for example new Transit paths in the wallet policy. External OpenBao: compare your policy with [External OpenBao](openbao.md#external-openbao).

Check: `helm -n ows status ows` shows `STATUS: deployed`, and `kubectl -n ows get pods` shows all pods `Running` and `READY`.

## Rollback

A rollback (`helm rollback`, or an upgrade with the chart of an earlier release) restores the objects and the images, but not the database schemas: the migration hooks of the newer release changed them.

- If the newer release has only backward compatible wallet revisions, the wallet pods of the earlier release start on the newer schema, with a warning.
- If it has a revision that is not backward compatible, the wallet pods of the earlier release do not start, and the earlier wallet migration hook exits with code 5 and changes nothing. Run the newer release again, or contact iGrant.io to downgrade the wallet database first.

The release notes of each release say whether it has such a revision.

## The services of the installation

An installation can run without consent or without the organisation wallet (see [Components](components.md#the-services-of-the-installation)). To remove or add a service later:

### Remove a service

1. In your values files, set `consent.enabled: false` (or `organisationWallet.enabled: false`), and remove `gateway.upstreams.consent.url` (or `gateway.upstreams.walletConfig.url`). Without consent, also set `privacyDashboard.enabled: false`.
2. Run the upgrade (step 3 at the top of this page).

Helm removes the pods, Jobs, Services and ConfigMaps of the service. The service's data stays: the chart deletes no database, no database user and no Secret with `helm.sh/resource-policy: keep` (for example the passwords in `<release>-postgres`). Without the wallet, the volumes of the bundled OpenBao also stay, with the wallet keys in them. The organisations' data stays too:

- The stored features of the service stay on the organisation record, but have no effect: the dashboard shows no area for the service.
- A webhook keeps its event types of the service, but gets no events of the service.
- An API key keeps its scopes of the service, but every route of the service answers `404` (`service_not_installed`).

### Add a service later

1. In your values files, set `consent.enabled: true` (or `organisationWallet.enabled: true`), or set the URL of the service in another release.
2. Run the upgrade.

The stored features, webhook subscriptions and API keys of the service apply again. A service that was installed before finds its data in its database. With the bundled OpenBao, the OpenBao pods start with their earlier volumes: unseal each pod (install step 5, item 2), and do not initialise OpenBao again.

Consent and the organisation wallet get the api's events from the stream `API_EVENTS` (consent: organisation changes and deletions; the wallet: organisation and sandbox changes and deletions). The stream keeps an event for 8 days, and no tool sends an older event again.

- A service that you add for the first time has a new database: it misses nothing, and you do nothing.
- A service that you removed and add again misses the events older than 8 days:
  - Consent, organisation suspensions and resumptions: no action. Consent reads each organisation from the api again when its local copy expires (after at most 15 minutes), and gets the current state.
  - Consent, organisation deletions: consent keeps the consent data of each organisation that a platform admin deleted while consent was not installed.
  - The wallet: the wallet keeps the wallets of each organisation and sandbox that a platform admin deleted while the wallet was not installed, and the api sent no wallet commands in that time (for example the suspension of an organisation).

  The platform operator's organisations list shows each deleted organisation with the status `deleting`, without a date. The action log of the platform operator organisation has the entry `organisation_deletion_started` with the date, but only for `api.actionLogRetentionDays` (default 30 days). So keep your own record of each organisation that you delete while a service is not installed. After the upgrade, send this record to iGrant.io support to purge the data of these organisations in the service.
