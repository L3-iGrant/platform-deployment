# Audit log

This page describes the audit log of the organisation wallet: its settings, the write-once bucket of its anchors and exports, the check of the log, and the retention purge of the wallet data.

[Back to the contents](../README.md#contents)

The wallet records the actions of the platform in an audit log in its database: for example a configuration change, a key retirement, an issued credential or a refused request. Each data scope with an audit log (`platform`, `kms`, `trust`, `issuer`, `authorisation_server`, `relying_party`, `business_wallet`, `individual_wallet_provider`, `business_wallet_provider`; see [Database](database.md#data-scopes-of-the-wallet)) has its own audit tables, with a hash chain for each organisation (the scopes `issuer` and `authorisation_server`: 8 sub-chains for each organisation, see [Settings](#settings)). The events of a scope are in monthly partitions.

| Part | Where | Written by |
| --- | --- | --- |
| The audit events and the chain heads | The wallet database: `<scope>.audit_event` and `<scope>.audit_chain` | The wallet pods, only through the append routine of the database. No wallet pod can change or delete an event. |
| An anchor of each scope every hour | `platform.audit_anchor`, signed with the key `audit-anchor-<scope>` of the Transit engine of OpenBao | The workers (the actors `audit.anchor_dispatch` and `audit.anchor` of the queue `realtime`) |
| The copies of the anchors and the monthly exports | The audit bucket | The workers (the actors of the anchors, and `audit.export` of the queue `maintenance`) |
| The monthly partitions | The wallet database | The migration hook: it makes the partitions of the next 24 months and drops the months that are older than the retention, only after a verified export |

The workers make the anchor keys at their start: Transit keys of OpenBao, not exportable (the policy of the wallet in OpenBao allows them, see [OpenBao](openbao.md)). A rotation of a key adds a version; each anchor names the version that signed it.

## Settings

| Value | Wallet setting | Default |
| --- | --- | --- |
| `organisationWallet.audit.retentionYears` | `audit.retention_years`: the years that the events of a data scope stay in the database (at least 1) | `7` |
| `organisationWallet.audit.scopeRetentionYears` | `audit.scope_retention_years`: another period for some data scopes, for example `{kms: 10}` | `{}` |
| `organisationWallet.audit.bucket.type` | `audit.bucket.type`: `s3` (an S3 store with Object Lock) or `gcs` (Google Cloud Storage through the Google client) | `s3` |
| `organisationWallet.audit.bucket.name`, `.prefix` | `audit.bucket.name`, `.prefix`: the audit bucket and the folder of the objects (for example `audit/production/`). Empty name: no bucket | `""` |
| `organisationWallet.audit.bucket.endpoint`, `.region` | Type `s3`: `audit.bucket.endpoint`, `.region`: the S3 API of the store (`https://host` or `https://host:port`) and the region of the signatures. Required with a name | `""` |
| `organisationWallet.audit.bucket.accessKey.existingSecret`, `.idKey`, `.secretKey` | Type `s3`: `audit.bucket.access_key_id_file`, `.secret_access_key_file`: the Secret with the access key of the wallet. Required with a name | `""`, `access-key-id`, `secret-access-key` |
| `organisationWallet.audit.bucket.ca.existingSecret`, `.key` | Type `s3`: `audit.bucket.ca_file`: the Secret with a PEM CA bundle of the TLS certificate of the store. Empty: the CA bundle of the client | `""`, `ca.crt` |
| `organisationWallet.audit.bucket.project` | Type `gcs`: `audit.bucket.project`: the project of the bucket. Empty: the project of the credentials | `""` |
| `organisationWallet.audit.bucket.credentials.existingSecret`, `.key` | Type `gcs`: `audit.bucket.credentials_file`: the Secret with the service account JSON of the bucket. Empty: the Google default credentials | `""`, `service-account.json` |

Each step of an issuance writes an audit event in the scope `issuer`, and each token request before a credential request writes an audit event in the scope `authorisation_server`. So that the issuances of one organisation do not wait for the head of one chain, the scopes `issuer` and `authorisation_server` have 8 sub-chains for each organisation, and each other scope has one: the default of the wallet for `audit.scope_sub_chains` (`{issuer: 8, authorisation_server: 8}`), the same in each process without a value of the chart. A scope that the value does not name keeps its default. `audit verify` checks each sub-chain. An installation that keeps one chain for these scopes sets the value in the files of all wallet roles: `organisationWallet.extraConfig: {audit: {scope_sub_chains: {issuer: 1, authorisation_server: 1}}}`. All processes must have the same value.

The chart writes the retention to the configuration of each wallet role (not of the clock) and of the migration hook, and the bucket only to the configuration of the worker groups, the only pods that mount the credentials of the bucket. The values of one type do not mix with the values of the other type: the render stops. Seven years is the period of EN 319 411-1 for the records of the key life cycle. Set a longer period when your practice statement or your certification asks for one.

## Audit bucket

The audit bucket keeps a copy of each hourly anchor and the monthly exports out of the reach of a database owner. A person who can change the wallet database cannot then rewrite the log without a trace: `audit verify` compares the anchors with their copies, and the exports keep the months that the migration hook drops.

The export of a month writes no local file: it sends each chain in parts of at most 16 MiB to the bucket, with a memory peak of about 263 to 424 MiB for one export (see [Workers and clock](workers.md#the-tmp-folder-of-the-workers)).

The wallet writes each object once with a create-only write (it never overwrites an object), reads it back, and never deletes an object or makes a bucket. Each object must stay unchanged for at least `organisationWallet.audit.retentionYears`: set a retention period of at least that value.

### Type s3: an S3 store with Object Lock

The bucket must be a bucket of an S3 store with Object Lock and a default retention in compliance mode. With compliance mode, no user of the store can delete a version of an object or shorten its retention before the retention ends. Object Lock can only be turned on when the bucket is made. At its start, the sink of the wallet reads the lock configuration of the bucket and refuses a bucket without a default retention in compliance mode: the anchors then stay in the database, and the workers log the refusal and record the event `audit_anchor.failed` for each anchor until the bucket has one.

Use a store that a team outside the platform operates, for example a Ceph RGW of your storage team: a store in the same cluster is weaker evidence, because an administrator of the cluster can delete its disks. Not Garage (no Object Lock) and not MinIO (no longer maintained).

For example, with the AWS CLI and the administrator key of your store:

```bash
BUCKET=example-ows-audit
aws s3api create-bucket --bucket "$BUCKET" --object-lock-enabled-for-bucket --endpoint-url https://s3.example.org
aws s3api put-object-lock-configuration --bucket "$BUCKET" --endpoint-url https://s3.example.org \
  --object-lock-configuration '{"ObjectLockEnabled":"Enabled","Rule":{"DefaultRetention":{"Mode":"COMPLIANCE","Years":7}}}'
```

Give the wallet an access key with only these rights on the bucket: `s3:PutObject`, `s3:GetObject`, `s3:GetObjectVersion`, `s3:ListBucketVersions` and `s3:GetBucketObjectLockConfiguration`. No delete right. Give the key as a Secret:

```bash
kubectl -n ows create secret generic ows-audit-bucket \
  --from-file=access-key-id=<file> --from-file=secret-access-key=<file>
```

```yaml
organisationWallet:
  audit:
    bucket:
      type: s3
      name: example-ows-audit
      endpoint: https://s3.example.org
      region: eu-west-1
      accessKey:
        existingSecret: ows-audit-bucket
      # ca:
      #   existingSecret: ows-audit-bucket-ca   # the CA of a store with a private certificate
```

With network policies, the workers reach a store with a public address through the egress profile `internet` (port 443). For a store in your network, set the egress profile `auditBucket` (`networkPolicy.egress.profiles.auditBucket.cidrs` and `.ports`; see [Network policies](network-policies.md)).

### Type gcs: Google Cloud Storage

The bucket must be a Google Cloud Storage bucket with:

- a retention policy of at least `organisationWallet.audit.retentionYears`, locked. With a locked retention policy, an object cannot be changed or deleted before its retention period ends, and the policy cannot be removed or shortened. A bucket with a locked policy cannot be deleted while it holds objects: check the name, the location and the period before you lock the policy;
- uniform bucket-level access and public access prevention;
- a service account for the wallet with object create and read only, on this bucket and not on the project: the roles `roles/storage.objectCreator` and `roles/storage.objectViewer`. Do not give `roles/storage.objectAdmin` or a bucket role.

The wallet does not check that the policy is locked: check it after the install (`gcloud storage buckets describe gs://<bucket>`). This type stays until the conformance test of the S3 API of Google Cloud Storage decides: when that test passes, a release replaces it with type `s3` (endpoint `https://storage.googleapis.com`, region `auto`, the HMAC key of the service account).

For example, with your project, location and names:

```bash
BUCKET=example-ows-audit
gcloud storage buckets create "gs://$BUCKET" --project=<project> --location=<location> \
  --uniform-bucket-level-access --public-access-prevention --retention-period=7y
gcloud storage buckets update "gs://$BUCKET" --lock-retention-period
gcloud iam service-accounts create ows-audit --project=<project>
SA=ows-audit@<project>.iam.gserviceaccount.com
for role in roles/storage.objectCreator roles/storage.objectViewer; do
  gcloud storage buckets add-iam-policy-binding "gs://$BUCKET" --member="serviceAccount:$SA" --role="$role"
done
```

Give a key of the service account as a Secret, or use Workload Identity for the workers (no Secret: the Google default credentials):

```bash
kubectl -n ows create secret generic ows-audit-bucket --from-file=service-account.json=<key file>
```

```yaml
organisationWallet:
  audit:
    bucket:
      type: gcs
      name: example-ows-audit
      project: <project>
      credentials:
        existingSecret: ows-audit-bucket
```

With network policies, the workers reach Google Cloud Storage through the egress profile `internet` (port 443). With Workload Identity, also add the profile `metadata` to the role `wallet-worker` (see [Network policies](network-policies.md)).

### Without a bucket

Without a bucket (the default), the anchors stay in the database only, no month is exported, the migration hook drops no partition, and `audit verify` reports the check of the bucket copies (C9) as skipped.

## Check the audit log

`audit verify` reads every chain and every anchor and checks the sequence numbers, the hashes, the chain heads, the anchor signatures, the gaps of more than 2 hours between anchors and the bucket copies. Run it in a worker pod, with the configuration of the worker (its database role reads the audit tables for the exports, and it has the key store and the bucket):

```bash
kubectl -n ows exec deploy/ows-wallet-worker-maintenance -- /app/.venv/bin/audit verify
```

Exit code 0: the log is verified. Exit code 1: evidence of change; the output names the first bad row of each chain and the first bad anchor of each scope. Exit code 2: an input, configuration or connection error. For support, `audit timeline --request-id <id>` (or `--object <type>:<id>`, or `--organisation <id> --from <time> --to <time>`) gives the events in time order.

The root file system of the wallet pods is read-only. A command that writes a file, for example `audit export --organisation` or `audit anchor-keys ensure --jwks`, writes to the folder or the file that you give: give a path below `/tmp`, then copy the file with `kubectl cp`.

The roles hook also makes the audit reader `<prefix>_audit_reader`: it can read the audit tables and nothing else. Its password is the key `audit_reader` of the Secret `<release>-wallet-database-roles` (see [Database](database.md#database-roles-of-the-wallet)). No pod of the chart uses it: give it to an auditor who runs `audit verify` from the wallet image with a configuration file that has only `database` (the audit reader) and `audit` (the bucket).

## Retention purge

Each day the actor `retention.dispatch` of the workers (queue `maintenance`) starts the purge of the rows below, in batches. The deactivation of an organisation or a sandbox (its delete in the dashboard or the API) writes the purge date. The chart writes the same values to all wallet files (not to the clock).

| Value | Wallet setting | Default | Rows |
| --- | --- | --- | --- |
| `organisationWallet.retention.softDeletedDays` | `retention.soft_deleted_days` | `30` | Soft-deleted history rows, after their delete |
| `organisationWallet.retention.deactivatedOrganisationDays` | `retention.deactivated_organisation_days` | `30` | A deactivated organisation with its rows, after the deactivation |
| `organisationWallet.retention.deactivatedSandboxDays` | `retention.deactivated_sandbox_days` | `7` | A deactivated sandbox with its rows, after the deactivation |
| `organisationWallet.retention.deadLetterDays` | `retention.dead_letter_days` | `30` | The dead letters of the event consumers |
| `organisationWallet.retention.loginCodeDays` | `retention.login_code_days` | `1` | The login codes of the conformance tests, after their expiry |
| `organisationWallet.retention.verifierResponseKeyDays` | `retention.verifier_response_key_days` | `1` | The verifier response keys, after the expiry of their verification |
| `organisationWallet.retention.issuedCredentialTokenDays` | `retention.issued_credential_token_days` | `30` | The tokens of the issued credentials, after the issue. The issued credential stays; its read then gives no token |
| `organisationWallet.retention.batchSize` | `retention.batch_size` | `500` | The rows of one delete statement (1 to 10000) |

The purge also deletes the protocol session of an issuance (the hashes of its codes and tokens) one day after the end of its grant; this rule has no value. The history of the issuances, verifications, held credentials, presentations and wallet units that is not deleted has no age rule. The first run after an upgrade from a release without the purge deletes the soft-deleted rows that are older than the period.

## Partitions

At each install and upgrade, the migration hook runs `migrate-database`: the revisions, the grant step, then the partition step of the audit log. The partition step makes the monthly partitions of the next 24 months and drops the months that are older than the retention of their scope, only when the export of the month is verified. A month without a verified export stays, and the hook names it in its log. When the partition step fails (exit code 4), the schema is at the head with all grants: run the upgrade again (see [Upgrade](upgrade.md)).
