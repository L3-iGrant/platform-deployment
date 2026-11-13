# Keys

The keys of the platform and the Secrets that hold them: the Secrets of `scripts/make-keys.sh`, and the Secrets that the chart creates.

[Back to the contents](../README.md#contents)

`scripts/make-keys.sh` creates these keys and Secrets (`<release>` is the release name):

| Secret | Key | Content |
| --- | --- | --- |
| `<release>-api-token-hash` | `token-hash-secret.json` | The secret for the hashes of the API keys and tokens |
| `<release>-api-token-signing` | `jwks.json` | The keys that sign the API tokens |
| `<release>-api-db-wrapping` | `db-wrapping-keys.json` | The keys that encrypt the OpenID provider's keys in the database |
| `<release>-gateway-internal-token` | `internal-token-jwks.json` | The key that signs the gateway's internal token |
| `<release>-api-service-key`, `<release>-consent-service-key`, `<release>-wallet-service-key` | `service-jwks.json` | The keys that sign each service's NATS messages |
| `<release>-nats-<user>` | `seed` | The nkey seed of each NATS user |

The script runs the `igrant-api keys` commands of the api image (`generate-hash-secret`, `generate-token-key`, `generate-wrapping-key`, `export-token-jwks`, `generate-nats-seed`). To change a key:

1. Add a new key to the file with the same command (`--rotate` for the hash secret and the wrapping key).
2. Update the Secret and the public keys, then upgrade.
3. Set the new active key id, and upgrade again.

The chart creates these Secrets itself (random values, kept across upgrades):

| Secret | Keys |
| --- | --- |
| `<release>-postgres` | one key per database name, and the admin password of the bundled server (`POSTGRES_PASSWORD`); a Helm hook that the chart creates before the other hooks (see [Database](database.md#hooks-of-the-databases)) |
| `<release>-postgres-tls` | `tls.crt`, `tls.key`, `ca.crt` of the bundled server |
| `<release>-read-access` | the passwords of the read-only users (`<reader>-<owner>`); a Helm hook, like `<release>-postgres` |
| `<release>-wallet-database-roles` | the passwords of the wallet's database roles, one key per role without the prefix (for example `launcher_app`, `jobs`, `clock`, `migrator`); a Helm hook that the chart creates before the other hooks (see [Database](database.md#database-roles-of-the-wallet)) |
| `<release>-api` | `api-secret-key`, and the SMTP and Twilio values if you set them as values |
| `<release>-openbao-wallet`, `<release>-openbao-tls` | see [OpenBao](openbao.md) |
| `<release>-redis-users`, `<release>-redis-tls` | the passwords of the ACL users and the certificates of the bundled Valkey; see [Redis](redis.md#acl-users) |
| `<release>-nats-tls` | `tls.crt`, `tls.key`, `ca.crt` of the bundled NATS; see [NATS users](nats-users.md#tls) |

`helm template` cannot read the cluster, so it shows new random values. A tool that only renders the templates (for example a GitOps tool that renders) creates new values on every render. With such a tool, set the passwords as values or use the `existingSecret` values.
