# Audit log

This page describes the audit log of the organisation wallet: its settings, the write-once bucket of its anchors and exports, the check of the log, and the retention purge of the wallet data.

[Back to the contents](../README.md#contents)

The wallet records the actions of the platform in an audit log in its database: for example a configuration change, a key retirement, an issued credential or a refused request. Each data scope with an audit log (`platform`, `kms`, `trust`, `issuer`, `authorisation_server`, `relying_party`, `business_wallet`, `wallet_provider`; see [Database](database.md#data-scopes-of-the-wallet)) has its own audit tables, with one hash chain for each organisation. The events of a scope are in monthly partitions.

| Part | Where | Written by |
| --- | --- | --- |
| The audit events and the chain heads | The wallet database: `<scope>.audit_event` and `<scope>.audit_chain` | The wallet pods, only through the append routine of the database. No wallet pod can change or delete an event. |
| An anchor of each scope every hour | `platform.audit_anchor`, signed with the key `audit-anchor-<scope>` of the Transit engine of OpenBao | The scheduler |
| The copies of the anchors and the monthly exports | The audit bucket | The scheduler |
| The monthly partitions | The wallet database | The migration hook: it makes the partitions of the next 24 months and drops the months that are older than the retention, only after a verified export |

The scheduler makes the anchor keys at its start: Transit keys of OpenBao, not exportable (the policy of the wallet in OpenBao allows them, see [OpenBao](openbao.md)). A rotation of a key adds a version; each anchor names the version that signed it.

## Settings

| Value | Wallet setting | Default |
| --- | --- | --- |
| `organisationWallet.audit.retentionYears` | `audit.retention_years`: the years that the events of a data scope stay in the database (at least 1) | `7` |
| `organisationWallet.audit.scopeRetentionYears` | `audit.scope_retention_years`: another period for some data scopes, for example `{kms: 10}` | `{}` |
| `organisationWallet.audit.bucket.name`, `.project`, `.prefix` | `audit.bucket`: the audit bucket, its project (empty: the project of the credentials) and the folder of the objects (for example `audit/production/`). Empty name: no bucket | `""` |
| `organisationWallet.audit.bucket.credentials.existingSecret`, `.key` | `audit.bucket.credentials_file`: the Secret with the service account JSON of the bucket. Empty: the Google default credentials | `""`, `service-account.json` |

The chart writes the retention to the configuration of each wallet role and of the migration hook, and the bucket only to the configuration of the scheduler, the only pod that mounts the service account of the bucket. Seven years is the period of EN 319 411-1 for the records of the key life cycle. Set a longer period when your practice statement or your certification asks for one.

## Audit bucket

The audit bucket keeps a copy of each hourly anchor and the monthly exports out of the reach of a database owner. A person who can change the wallet database cannot then rewrite the log without a trace: `audit verify` compares the anchors with their copies, and the exports keep the months that the migration hook drops.

The bucket must be a Google Cloud Storage bucket with:

- a retention policy of at least `organisationWallet.audit.retentionYears`, locked. With a locked retention policy, an object cannot be changed or deleted before its retention period ends, and the policy cannot be removed or shortened. A bucket with a locked policy cannot be deleted while it holds objects: check the name, the location and the period before you lock the policy;
- uniform bucket-level access and public access prevention;
- a service account for the wallet with object create and read only, on this bucket and not on the project: the roles `roles/storage.objectCreator` and `roles/storage.objectViewer`. Do not give `roles/storage.objectAdmin` or a bucket role. The wallet writes each object once (it never overwrites an object), reads it back, and never deletes an object or makes a bucket.

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

Give a key of the service account as a Secret, or use Workload Identity for the scheduler (no Secret: the Google default credentials):

```bash
kubectl -n ows create secret generic ows-audit-bucket --from-file=service-account.json=<key file>
```

```yaml
organisationWallet:
  audit:
    bucket:
      name: example-ows-audit
      project: <project>
      credentials:
        existingSecret: ows-audit-bucket
```

With network policies, the scheduler reaches Google Cloud Storage through the egress profile `internet` (port 443). With Workload Identity, also add the profile `metadata` to the role `wallet-scheduler` (see [Network policies](network-policies.md)).

Without a bucket (the default), the anchors stay in the database only, no month is exported, the migration hook drops no partition, and `audit verify` reports the check of the bucket copies (C9) as skipped.

## Check the audit log

`audit verify` reads every chain and every anchor and checks the sequence numbers, the hashes, the chain heads, the anchor signatures, the gaps of more than 2 hours between anchors and the bucket copies. Run it in the scheduler pod, with the configuration of the scheduler (its database role reads the audit tables for the exports, and it has the key store and the bucket):

```bash
kubectl -n ows exec deploy/ows-wallet-scheduler -- /app/.venv/bin/audit verify
```

Exit code 0: the log is verified. Exit code 1: evidence of change; the output names the first bad row of each chain and the first bad anchor of each scope. Exit code 2: an input, configuration or connection error. For support, `audit timeline --request-id <id>` (or `--object <type>:<id>`, or `--organisation <id> --from <time> --to <time>`) gives the events in time order.

The roles hook also makes the audit reader `<prefix>_audit_reader`: it can read the audit tables and nothing else. Its password is the key `audit_reader` of the Secret `<release>-wallet-database-roles` (see [Database](database.md#database-roles-of-the-wallet)). No pod of the chart uses it: give it to an auditor who runs `audit verify` from the wallet image with a configuration file that has only `database` (the audit reader) and `audit` (the bucket).

## Retention purge

The daily job `retention_purge` of the scheduler deletes the rows below, in batches. The deactivation of an organisation or a sandbox (its delete in the dashboard or the API) is in the config pods: they write the purge date. The chart writes the same values to both.

| Value | Wallet setting | Default | Rows |
| --- | --- | --- | --- |
| `organisationWallet.retention.softDeletedDays` | `retention.soft_deleted_days` | `30` | Soft-deleted history rows, after their delete |
| `organisationWallet.retention.deactivatedOrganisationDays` | `retention.deactivated_organisation_days` | `30` | A deactivated organisation with its rows, after the deactivation |
| `organisationWallet.retention.deactivatedSandboxDays` | `retention.deactivated_sandbox_days` | `7` | A deactivated sandbox with its rows, after the deactivation |
| `organisationWallet.retention.deadLetterDays` | `retention.dead_letter_days` | `30` | The dead letters of the event consumers |
| `organisationWallet.retention.loginCodeDays` | `retention.login_code_days` | `1` | The login codes of the conformance tests, after their expiry |
| `organisationWallet.retention.verifierResponseKeyDays` | `retention.verifier_response_key_days` | `1` | The verifier response keys, after the expiry of their verification |
| `organisationWallet.retention.batchSize` | `retention.batch_size` | `500` | The rows of one delete statement (1 to 10000) |

The history of the issuances, verifications, held credentials, presentations and wallet units that is not deleted has no age rule. The first run after an upgrade from a release without the purge deletes the soft-deleted rows that are older than the period.

## Partitions

At each install and upgrade, the migration hook runs `migrate-database`: the revisions, the grant step, then the partition step of the audit log. The partition step makes the monthly partitions of the next 24 months and drops the months that are older than the retention of their scope, only when the export of the month is verified. A month without a verified export stays, and the hook names it in its log. When the partition step fails (exit code 4), the schema is at the head with all grants: run the upgrade again (see [Upgrade](upgrade.md)).
