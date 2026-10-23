# Keys

This page lists the keys of the platform and the Secrets that hold them: the Secrets of `scripts/make-keys.sh` and the Secrets that the chart creates.

[Back to the contents](../README.md#contents)

`scripts/make-keys.sh` creates these keys and Secrets (`<release>` is the release name):

| Secret | Key | Content |
| --- | --- | --- |
| `<release>-api-token-hash` | `token-hash-secret.json` | The secret of the hashes of the API keys and tokens |
| `<release>-api-token-signing` | `jwks.json` | The keys that sign the API tokens |
| `<release>-api-db-wrapping` | `db-wrapping-keys.json` | The keys that encrypt the keys of the OpenID provider in the database |
| `<release>-gateway-internal-token` | `internal-token-jwks.json` | The key that signs the internal token of the gateway |
| `<release>-api-service-key`, `<release>-consent-service-key`, `<release>-wallet-service-key` | `service-jwks.json` | The keys that sign the NATS messages of each service |
| `<release>-nats-<user>` | `seed` | The nkey seed of each NATS user |

The script runs the `igrant-api keys` commands of the api image (`generate-hash-secret`, `generate-token-key`, `generate-wrapping-key`, `export-token-jwks`, `generate-nats-seed`). To change a key, add a new key to the file with the same command (`--rotate` for the hash secret and the wrapping key), update the Secret and the public keys, upgrade, then set the new active key id and upgrade again.

The chart creates these Secrets itself (random values, kept across upgrades):

| Secret | Keys |
| --- | --- |
| `<release>-postgres` or `<release>-mysql` | one key per database name, and the admin password of the bundled server (`POSTGRES_PASSWORD` or `MARIADB_ROOT_PASSWORD`) |
| `<release>-postgres-tls` or `<release>-mysql-tls` | `tls.crt`, `tls.key`, `ca.crt` of the bundled server |
| `<release>-read-access` | the passwords of the read-only users (`<reader>-<owner>`) |
| `<release>-api` | `api-secret-key`, and the SMTP and Twilio values when you set them as values |
| `<release>-openbao-wallet`, `<release>-openbao-tls` | see [OpenBao](openbao.md) |

`helm template` cannot read the cluster, so it shows new random values. A tool that only renders the templates (for example a GitOps tool that renders) makes new values at each render: with such a tool, set the passwords in values or use the `existingSecret` values.
