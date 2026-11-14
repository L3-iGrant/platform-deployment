# iGrant.io platform: Docker Compose

This folder runs the iGrant.io platform on a single Docker host. Use it for
development and tests. For a Kubernetes cluster, use the Helm chart in this
repository. For production, use the enterprise installation (on request:
support@igrant.io).

Follow the [Installation](#installation) steps in order. Each step ends with
a check: go to the next step only when the check passes.

## Contents

- [Components](#components)
- [Prerequisites](#prerequisites)
- [Installation](#installation)
- [Operation](#operation)
- [Settings](#settings)
- [Consent](#consent)
- [Configuration files](#configuration-files)
- [Database roles of the wallet](#database-roles-of-the-wallet)
- [Database server logs](#database-server-logs)
- [Audit log](#audit-log)
- [Worker and clock](#worker-and-clock)
- [Valkey](#valkey)
- [Security settings](#security-settings)
- [Secrets](#secrets)
- [Reverse proxy](#reverse-proxy)
- [Privacy dashboard](#privacy-dashboard)
- [Commands](#commands)
- [Troubleshooting](#troubleshooting)
- [Licence](#licence)

## Components

| Component | What it does | Host port |
|---|---|---|
| Gateway (`gateway`) | Entry point for all API calls from your systems and from the dashboard. It checks every request (API keys, logins, rate limits). | `API_PORT` (8080) |
| API (`api`) and webhook handler (`webhook`) | Organisations, admins, API keys, and the webhooks to your systems. | none |
| Consent management (`consent`) | Data agreements and consent records. Off by default: see [Consent](#consent). | none |
| Organisation wallet (`wallet-service`, `wallet-config`, `wallet-worker`, `wallet-clock`) | Issues and verifies credentials (OpenID4VCI, OpenID4VP) for the EUDI Wallet and the European Business Wallet. The worker runs the background work and the clock sends the scheduled work (see [Worker and clock](#worker-and-clock)). | `WALLET_PORT` (8090) |
| Enterprise dashboard (`dashboard`) | The web app for the admins of your organisations. | `DASHBOARD_PORT` (3000) |
| Database (`postgres`) | One PostgreSQL server for all components (`DB_ENGINE`). | none |
| NATS (`nats`) | Messaging between the components. | none |
| OpenBao (`openbao`) | Holds the signing keys of your organisations. | none |
| Valkey (`valkey`, `valkey-replica`, `valkey-sentinel`) | The wallet's work queue, single-use values and caches: a primary, a replica and a Sentinel. See [Valkey](#valkey). | none |

Some services run once at each start and then exit:
`database-init`, `wallet-database-roles`, `api-migrate`, `wallet-migrate`,
`api-read-access-wallet`, `wallet-read-access-api`, `openbao-init` and
`nats-data-owner`, and with consent also `consent-migrate`,
`api-read-access-consent`, `consent-read-access` and
`wallet-read-access-consent`. They create the databases, the wallet's
database roles, the tables, the read-only database users and the OpenBao
configuration, and hand the NATS volume to the NATS user.

For HSM support and larger installations, see the chart pages [Connect your on-premise HSM](../docs/on-premise-hsm.md), [DPoD key stores](../docs/dpod-key-stores.md) and [Scaled deployments](../docs/scaled-deployments.md).

## Prerequisites

- A Linux host with Docker Engine, Docker Compose 2.24 or newer, GNU Make,
  Bash, OpenSSL, curl and Python 3.8 or newer (`python3`, standard library
  only: `make configs` uses it to write the configuration files, see
  [Configuration files](#configuration-files)).
- Access to the iGrant.io image registry (`IMAGE_REGISTRY`, default
  `europe-docker.pkg.dev/jenkins-189019/igrant-customers`) and the tag of your
  release (`PLATFORM_TAG`). Ask support@igrant.io for a key file
  (`key.json`) or for access for your Google account.
- Your own reverse proxy with TLS in front of the three host ports, and a
  DNS name for each public service (API, wallet, dashboard). This folder
  does not install a reverse proxy; its settings are in
  [Reverse proxy](#reverse-proxy).
- Outbound HTTPS from the host to the internet: the image registries, the
  EU list of trusted lists (`https://ec.europa.eu/tools/lotl/eu-lotl.xml`),
  the trusted lists that organisations add as trust sources, and the
  services of other issuers, verifiers and wallets.
- Optional: your SMTP server, for the api's e-mails (admin invitations,
  password reset).

## Installation

Run these steps in this folder (`docker-compose` in the repository).

### Step 1: Log in to the image registry

With a key file:

```bash
cat key.json | docker login -u _json_key --password-stdin https://europe-docker.pkg.dev
```

Or with your Google account (Google Cloud CLI):

```bash
gcloud auth configure-docker europe-docker.pkg.dev
```

If you use your own mirror, log in to your registry instead and set
`IMAGE_REGISTRY` in step 2.

Check: `docker login` shows `Login Succeeded`; `gcloud auth
configure-docker` shows that the credential helper for
`europe-docker.pkg.dev` is registered in your Docker configuration.

### Step 2: Make your settings

```bash
make env
```

Check: you see `env: wrote .env: set your values, then run make secrets`.

Open `.env` and set the values. The file describes each value (the same
text is in [Settings](#settings)). Every installation must set
`PLATFORM_TAG`:

- `PLATFORM_TAG`: the release tag, for example `2026.11.4`. `2026.11.x` is a placeholder:
  `make secrets` and `make check` stop until you replace it.

If the installation runs behind your reverse proxy (not only on
localhost), also set:

- `API_PUBLIC_URL`, `WALLET_PUBLIC_URL`, `DASHBOARD_PUBLIC_URL`: the
  `https://` URLs of your reverse proxy.
- `CLIENT_ADDRESS_HEADER`: the header in which your reverse proxy sends the
  client address (for example `X-Real-IP`).
- `SMTP_HOST`, `SMTP_PORT`, `SMTP_USERNAME`, `SMTP_FROM`: your SMTP server.

Consent management is off by default. To install it, set
`CONSENT_ENABLED=true` before step 3 (see [Consent](#consent)).

### Step 3: Make the secrets

```bash
make secrets
```

This creates all the platform's passwords and keys in `secrets/` (git
ignores it). It runs the api image without a network to generate the keys.
When `SMTP_USERNAME` is set, it asks for the SMTP password (the input is
hidden). It prints no secret values.

Check: you see `secrets: secrets/: 36 new, 0 kept (no value printed)`
(37 with the SMTP password).

### Step 4: Check the configuration

```bash
make check
```

This writes the components' configuration files to `generated/` from your
`.env` (`make configs`, see [Configuration files](#configuration-files)),
then checks `.env`, the files in `secrets/` and `generated/`, and the
Compose files for your `DB_ENGINE`. It starts no containers.

Check: the last line is
`check: the configuration is valid (DB_ENGINE=postgresql, <n> warning(s))`.
Each `FAIL` line says what to fix; fix it and run this step again. Read
every `WARN` line: for example, a public URL with `http://` does not work
with mobile wallets.

### Step 5: Start the platform

```bash
make up
```

This runs `make check` again (with `make configs`), then starts the
services. The first start pulls the images and creates the databases, so it
can take a few minutes.

Check: you see `up: started. make status shows the state of the services.`
Then wait two minutes and run:

```bash
make status
```

Check: you see one line per service.

- `gateway`, `api`, `webhook`, `wallet-config`, `wallet-service`,
  `wallet-worker`, `wallet-clock`, `dashboard`, `nats`, `openbao`,
  `valkey`, `valkey-replica`, `valkey-sentinel` and `postgres`, and with
  consent also `consent`: `running`. Services with a health check also
  show `(healthy)`.
- `database-init`, `wallet-database-roles`, `api-migrate`,
  `wallet-migrate`, `api-read-access-wallet`, `wallet-read-access-api`,
  `openbao-init` and `nats-data-owner`, and with consent also
  `consent-migrate`, `api-read-access-consent`, `consent-read-access` and
  `wallet-read-access-consent`: `exited`, with the status `Exited (0)`.

If a service is in another state, see [Troubleshooting](#troubleshooting).

### Step 6: Check the host ports

On the Docker host:

```bash
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8080/readyz
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8090/readyz
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:3000/
```

If you changed `PUBLISH_ADDRESS` or the ports, use your values.

Check: you see `200` three times (API, wallet, dashboard).

### Step 7: Connect your reverse proxy

Set up your reverse proxy as described in [Reverse proxy](#reverse-proxy).

Check: `https://<your API host>/readyz` and `https://<your wallet
host>/readyz` return `200`, and `https://<your dashboard host>` shows the
dashboard login page.

### Step 8: Make the platform operator organisation and the first platform admin

An installation has one platform operator organisation. Its platform admins
add, suspend and delete the other organisations of the installation in the
dashboard. Only the command line can create the platform operator
organisation and grant the first platform admin right.

```bash
make platform-operator ADMIN_EMAIL=admin@example.com ADMIN_NAME="First Admin" \
  ORG_NAME="Example Wallet Provider" ORG_LOCATION=Stockholm \
  ORG_POLICY_URL=https://example.com/privacy
```

This runs `igrant-api onboard bootstrap-platform` in the `api` container.
In one go, it creates the organisation type `Technology` (if no type has
that name), the first admin, the organisation with the platform operator
mark, and the admin's platform admin right. To use another organisation
type, add `ORGANISATION_TYPE=<type>`.

The command asks for the admin's first password (the input is hidden). The
password reaches the command on standard input, never as an argument. A
platform admin password needs 15 to 256 characters and at least one
special character, for example `!`, `#` or `%` (a space does not count).
It must not be a known password, and it must not contain part of the
e-mail address, the name or the organisation name. If the API refuses the
password, the command lists the rules that failed and creates nothing.

Check: you see one JSON line with `organisationId`, `adminId` and
`"created":true`, followed by a status line (and preceded by an api log
line, for example `IAM provider chain: [builtin]`). A second run with the
same values changes nothing and shows `"created":false`; the password of
an existing account does not change. Then:

```bash
make platform-status
```

The JSON line has `operatorOrganisationId` (your organisation's id) and one
entry in `platformAdmins`. The command only reads, and it prints no
secrets.

Then log in to the dashboard with the e-mail address and the password. The
account must change its password at the first login: the dashboard opens
the new password page (15 characters or more, with at least one special
character). This needs no e-mail service. The dashboard shows the platform
admin functions in the group "Wallet Provider (Organisations)" ("Platform"
without the wallet).

Rules of the command:

- Use it only on a new installation. If an admin with that e-mail address
  belongs to a different organisation, the command exits 1 and changes
  nothing.
- The platform operator mark cannot be transferred or removed.
- The wallet of the platform operator organisation is the wallet provider
  of the installation: the wallet gets this flag when an admin deploys it,
  and no route can change the flag later.

### After the installation: the other organisations and admins

A platform admin does these tasks in the dashboard, in the group "Wallet
Provider (Organisations)" ("Platform" without the wallet). No `make` target
is needed.

| Task | What the operator must know |
|---|---|
| Add an organisation with its first admin (page "Organisations", button "Add Organisation") | The first admin gets an e-mail invitation or a one-time password. Invitations need the e-mail service (`SMTP_HOST`); without it, use the one-time password. The API deploys the new organisation's wallet. |
| Set the features of an organisation ("Manage Features") | The panel has one switch for each feature of an installed service: Issuer & Verifier and Wallet Unit (Holder) with the wallet, Consent Management and Data Marketplace with consent (2 switches when consent is off). A feature of a service that is not installed has no switch. A new organisation has only Issuer & Verifier on; the platform operator organisation has each of them on. Getting Started, Account, Webhooks and Activity Logs have no switch and are always available. The gateway refuses the routes of a feature that is off for the organisation (`FEATURES_ENFORCE`, see [Settings](#settings)). |
| Suspend and resume an organisation | Within 60 seconds, the gateway refuses every credential of a suspended organisation. If the wallet did not get the new state, the page shows a warning: send the request again. |
| Delete a suspended organisation ("Delete Organisation") | This cannot be undone. The API deletes its data of the organisation in steps, consent (when it is installed) purges its data, and the wallet deactivates the organisation's wallets and purges them after its retention period. No background job retries a failed API step: when the page shows failed steps, use "Run Deletion Again" until none are left. Each failed step is one `ERROR` line in `docker compose logs api`. |
| Give and remove the platform admin right (page "Super Admins", row menu "Give Platform Admin Right" or "Remove Platform Admin Right") | Only an admin of the platform operator organisation can get the right. A platform admin whose password has fewer than 15 characters must set a new one at the next login. |

All other new passwords need 12 characters or more and at least one
special character.

If no platform admin can log in, give the right to an admin of the
platform operator organisation with `make platform-grant-admin
ADMIN_EMAIL=...`.

Admin login with a wallet: the api configuration has no
`AdminAuth.walletLogin.organisationId`. While it is empty, wallet login
uses the platform operator organisation, as long as it is the wallet
provider and its OIDC extension is on.

## Operation

| Task | Command |
|---|---|
| Show the state of the services | `make status` |
| Follow the logs | `make logs` |
| Stop the platform (the data stays) | `make down` |
| Start the platform again | `make up` |
| Change a setting | Edit `.env`, then run `make check` and `make up` (`make configs` writes the configuration files again, and Compose restarts the services whose file or setting changed) |
| Move to a new release | Set its tag in `PLATFORM_TAG` in `.env`, then run `make secrets`, `make check` and `make up` (see [Database roles of the wallet](#database-roles-of-the-wallet)) |
| Show the platform operator organisation and the platform admins | `make platform-status` |
| Delete all data and start again | `make reset`, then `make up`, then step 8 |
| OpenBao seal status | `make openbao-status` |
| SQL shell on the database server | `make db-shell` |
| Database server log (DDL statements, connections) | `docker compose logs postgres` |

Keep these safe. Without them, the platform data cannot be used:

- the `secrets/` folder (including `secrets/openbao/static-seal.key`, the
  key that unseals OpenBao, and `secrets/openbao/init.json`, the OpenBao
  root token and recovery key);
- the Docker volumes of the project `igrant-platform`.

## Settings

`.env.example` is the reference for all settings: for each one, the file
gives its meaning, its default and its allowed values. `make env` copies it
to `.env`. Use `KEY=value` lines with no spaces around `=`. A value set in
your shell overrides the value in `.env`.

| Setting | Default | Use |
|---|---|---|
| `DB_ENGINE` | `postgresql` | The database engine of all components: `postgresql` (PostgreSQL 18), the only supported engine. |
| `COMPOSE_PROFILES` | the derived line at the end of `.env.example` | Starts the database server of `DB_ENGINE`, and the consent services with `CONSENT_ENABLED`. Do not change it. |
| `CONSENT_ENABLED` | empty | `true` installs consent management; empty: no consent, the Helm chart's default. Only empty or `true`. See [Consent](#consent). |
| `TEST_CA_ENABLED`, `TEST_CA_LEAF_VALIDITY_DAYS` | `true`, `365` | The wallet's built-in test CA issues test certificates for development and testing. They are on no trusted list. Set `TEST_CA_ENABLED=false` if the installation must not offer it. `TEST_CA_LEAF_VALIDITY_DAYS` (1 to 3650) is the validity of a test certificate when the request gives none; the preset's maximum validity caps it. |
| `AUDIT_RETENTION_YEARS` | `7` | How many years the wallet's audit log keeps the events of each data scope (1 to 999). See [Audit log](#audit-log). |
| `API_PUBLIC_URL`, `WALLET_PUBLIC_URL`, `DASHBOARD_PUBLIC_URL` | `http://localhost:8080`, `:8090`, `:3000` | The public URLs (your reverse proxy). |
| `PUBLISH_ADDRESS` | `127.0.0.1` | The IP address of the host ports. |
| `API_PORT`, `WALLET_PORT`, `DASHBOARD_PORT` | `8080`, `8090`, `3000` | The host ports. |
| `CLIENT_ADDRESS_HEADER` | empty | The header in which your reverse proxy sends the client address. |
| `FEATURES_ENFORCE` | `true` | The gateway's feature gate (`Features.enforce`). With `true`, the gateway refuses a route of a product feature that is off for the credential's organisation (`403`, `feature_disabled`). With `false`, it refuses no route for a feature: use this only in an emergency. |
| `MAX_ORGANISATIONS`, `MAX_ORGANISATION_WALLET_UNITS` | empty (100) | The installation limits: the maximum number of organisations (`Limits.maxOrganisations` of the api, 1 to 100) and of organisation wallet units of the wallet provider (`wallet_unit.organisation_wallet_units_max` of the wallet, 1 to 100). Creating one more gets `409` (`organisation_limit_reached` from the api, `organisation_wallet_unit.limit_reached` from the wallet); existing organisations and organisation wallets stay. When empty, the configuration files get no key, and the api and the wallet use their default, 100. The maximum is 100. An installation with more than 100 organisations or organisation wallets keeps them, but cannot create a new organisation. |
| `SMTP_HOST`, `SMTP_PORT`, `SMTP_USERNAME`, `SMTP_FROM` | empty, `587`, empty, empty | Your SMTP server. With an empty `SMTP_HOST`, no e-mail is sent. |
| `IMAGE_REGISTRY` | `europe-docker.pkg.dev/jenkins-189019/igrant-customers` | The registry of the iGrant.io images (the Helm chart's default). The repositories are `api`, `gateway`, `consent-management-backend`, `eudi-wallet` and `dashboard`. |
| `PLATFORM_TAG` | `2026.11.x` (placeholder) | The release tag of all iGrant.io images. Set the tag of your release. The dashboard shows it as its version. |
| `POSTGRES_IMAGE`, `NATS_IMAGE`, `OPENBAO_IMAGE`, `VALKEY_IMAGE` | see `.env.example` | The images of the dependencies. |

The databases are `igrant_api`, `igrant_oidc`, `igrant_wallet`, and with
consent `igrant_consent`, each with its own owner user. The wallet keeps
its tables in data scopes: schemas in `igrant_wallet` (for example
`issuer`) that `wallet-database-roles` creates. Each wallet process
connects with its own database role (see
[Database roles of the wallet](#database-roles-of-the-wallet)).

The components' configuration files come from the templates in
`compose.configs.yaml`, filled in with the values of `.env` (see
[Configuration files](#configuration-files)).

## Consent

Consent management (data agreements and consent records) is off by
default, as in the Helm chart. The installation then has only the
organisation wallet:

- The consent services do not run: `consent`, `consent-migrate`,
  `consent-read-access`, `api-read-access-consent` and
  `wallet-read-access-consent` (the Compose profile `consent`).
  `database-init` makes no database `igrant_consent`.
- `make configs` writes the files as the chart does without consent: the
  api and gateway files get `Installation.services: [wallet]`, the gateway
  file has no consent upstream, the api trusts no NATS messages of consent,
  the wallet reads only the api's views, and NATS has no user `consent`.
  The dashboard file does not change.
- The gateway answers `404` (`service_not_installed`) on every consent
  route, and the dashboard shows no consent area (see
  [The services of the installation](../docs/components.md#the-services-of-the-installation)).
- `make secrets` still writes the consent passwords and keys. Only the
  public nkey of consent in `secrets/public/nats-nkeys.conf` follows
  `CONSENT_ENABLED`: NATS does not start with an nkey that no user uses.

To install consent, set `CONSENT_ENABLED=true` in `.env` (only empty or
`true`), then run `make secrets`, `make check` and `make up`. The derived
`COMPOSE_PROFILES` then has the profile `consent`. `make up` starts the
consent services and restarts the services whose files change (`api`,
`webhook`, `gateway`, `wallet-config` and `nats`). `wallet-config` waits
for `consent-read-access`.

To turn consent off later, empty `CONSENT_ENABLED`, then run
`make secrets`, `make check` and `make up`. `make up` first removes the
consent containers, because Compose does not stop the services of a
profile that is off. The database `igrant_consent` and its data stay. The
organisations keep their consent features, webhook event types and API
key scopes: they have no effect without consent, and apply again when you
turn consent on.

## Configuration files

Every service runs with a read-only root file system. Compose can give such
a service a configuration only from a file (a `file` config), not from text
in the Compose file (a `content` config). So:

1. `compose.configs.yaml` holds the templates of the components'
   configuration files, with the values of `.env` as variables (for example
   `${API_PUBLIC_URL}`).
2. `make configs` (`render-configs.py`) reads the templates with
   `docker compose -f compose.render.yaml config`, so Compose fills in the
   values of `.env` and `config/engine/<DB_ENGINE>.env` with the same rules
   and files as for the services. The script keeps the lines between
   `#if ${VAR}` and `#end` only when the value is not empty, and the lines
   between `#unless ${VAR}` and `#end` only when it is empty (the consent
   parts, see [Consent](#consent)). It writes each file to `generated/`
   (mode `0644`), also `generated/nats-users.conf` (the NATS users of
   `config/nats/users.conf`, without the user `consent` when consent is
   off), and `generated/configs.env` with the SHA-256 of each file.
3. The services in `compose.platform.yaml` read the files in `generated/`.
   Each one has the SHA-256 of its file in a label, so when a file changes,
   `docker compose up` restarts the service.

`make check` and `make up` run `make configs` first. After you change
`.env`, use them, not `docker compose up` alone (which keeps the old
files). `make check` stops when `generated/` does not match the current
values. The templates hold no secret values: each secret is a file in
`secrets/`, and the configurations only give its path. Git ignores
`generated/`.

Each file is written to a temporary file and then renamed, and
`generated/configs.env` is written last. So if `make configs` stops at any
point, the files are still complete, and the next `make configs` writes
them all. A missing value with `${VAR:?...}` stops `make configs` before it
writes any file.

## Database roles of the wallet

The wallet connects to `igrant_wallet` with one database role per process,
never with the database owner user `igrant_wallet`. The database roles
have the database name, `igrant_wallet`, as their prefix.

At each `make up`, the wallet's one-shot services run in this order; each
starts only after the one before it exits with code 0:

1. `database-init` creates the database `igrant_wallet` and its owner user.
2. `wallet-database-roles` (`database-roles apply`, as the admin user of
   the database server) creates the owner role `igrant_wallet_owner` and
   the login database roles with their passwords from `secrets/database/`,
   creates the data scope schemas, hands the tables, views and sequences of
   an older release to the owner role, and sets the grants.
3. `wallet-migrate` (`migrate-database`, as `igrant_wallet_migrator`)
   applies the wallet migrations as the owner role, then gives the database
   roles their grants on the new tables. It is the only service that
   changes the wallet schema.
4. `wallet-read-access-api` and, with consent, `wallet-read-access-consent`
   (as the admin user) create the read-only users of the api and of consent
   on the wallet views (one service per reader, because the wallet image
   has no shell). The wallet processes start after `wallet-migrate`.

| Process | Service | Database role |
|---|---|---|
| Database roles | `wallet-database-roles` | The admin user (`DB_ADMIN_USER`) |
| Migrations | `wallet-migrate` | `igrant_wallet_migrator` |
| Read access | `wallet-read-access-api`, `wallet-read-access-consent` (with consent) | The admin user (`DB_ADMIN_USER`) |
| Config routes and public routes | `wallet-config`, `wallet-service` | `igrant_wallet_launcher_app` |
| Background work | `wallet-worker` | `igrant_wallet_jobs` |
| Clock | `wallet-clock` | `igrant_wallet_clock` (it can only connect) |

The database roles of the wallet processes read and write data, but cannot
change the schema. Every wallet process except the clock waits until the
schema reaches the head of its code. If the schema does not get there in
time, the process exits and Compose starts it again.

The other login database roles (`igrant_wallet_audit_reader` and one
database role per role application, for example
`igrant_wallet_issuer_app`) also get passwords, but no process of this
release logs in with them. The audit reader can only read the audit log
(see [Audit log](#audit-log)).

A new release can add database roles and migrations. Set its tag in
`PLATFORM_TAG` in `.env`, then run `make secrets`, `make check` and
`make up`. `make secrets` creates the password files that the release adds
and keeps the others. The one-shot services then do the database work in
the order above, with no manual step.

## Database server logs

The `postgres` server writes these events to its container log
(`docker compose logs postgres`):

- the text of each DDL statement (`log_statement=ddl`): `CREATE`, `ALTER`
  and `DROP` (also of roles), `GRANT` and `REVOKE`, but no data
  statements;
- each connection, with the client address, the user, the database and the
  authentication method (`log_connections=on`);
- the end of each session, with its duration (`log_disconnections=on`).

These logs show the changes to schemas and rights, and the sessions of each
database user. `make check` warns when the `postgres` command lacks one of
the three settings, for example when a Compose override file changes it.

The log holds the text of every DDL statement, so never put a password in a
statement on this server: `ALTER ROLE ... PASSWORD '...'` writes the
password to the log. Use `\password` of psql (`make db-shell`), which sends
a SCRAM-SHA-256 verifier, not the password. `database-init` sets the
passwords of the owner users this way. `wallet-database-roles`
(`database-roles apply`) and the read access services of the wallet, the
api and consent (`read-access apply`) also send only the SCRAM-SHA-256
verifier of each password, never the password.

Docker keeps the container logs. Set up log rotation for your Docker
daemon (the options `max-size` and `max-file` of the log driver
`json-file`) so that the logs do not fill the disk.

## Audit log

The wallet records platform actions in an audit log in its database: for
example a configuration change, a key retirement, an issued credential or
a refused request. Each data scope of the wallet has its own hash chains.
Every hour, `wallet-worker` signs an anchor of each scope with the OpenBao
Transit key `audit-anchor-<scope>`; the worker creates the keys when it
starts.

| Part | Compose |
| --- | --- |
| Retention | `AUDIT_RETENTION_YEARS` (default 7) in each wallet file and in `wallet-migrate` |
| Monthly partitions | `wallet-migrate` creates the partitions of the next 24 months at each start |
| Audit bucket | None. The anchors stay in the database only, no month is exported, and `wallet-migrate` drops no partition |

A Helm chart installation can copy the anchors and the monthly exports to
a write-once bucket: an S3 store with Object Lock in compliance mode, or
Google Cloud Storage with a locked retention policy (see
[Audit log](../docs/audit-log.md)). Compose has no such bucket: storage on
the same host is no place for evidence.

Check the chains and the anchors (exit code 0: verified; 1: evidence of a
change, with the first bad row of each chain; 2: an input or connection
error):

```bash
docker compose exec wallet-worker /app/.venv/bin/audit verify
```

The check of the bucket copies (C9) is skipped. For support,
`audit timeline --request-id <id>` lists the events of one request in time
order.

The worker also purges wallet data every day: soft-deleted history rows 30
days after their deletion, a deleted organisation 30 days and a deleted
sandbox 7 days after its deactivation, dead letters after 30 days, and the
tokens of issued credentials 30 days after the issue (the wallet's
`retention` settings, with their defaults).

## Worker and clock

The wallet runs its background work as actors on Valkey queues:

| Service | Function |
| --- | --- |
| `wallet-worker` | Runs the actors of all queues (`realtime`, `attestation`, `status`, `kms`, `maintenance`): one worker process with 8 threads. On stop, it waits at most one hour for the running actors (`stop_grace_period`); an actor that does not finish in that time runs again from its message. |
| `wallet-clock` | Sends the cron actors' messages to the queues when they are due. It holds the database leader lock while it sends. It connects to neither NATS nor a key store. |

The worker and the clock each have a health port (9191 and 9192, only on
the Compose network): `/healthz` (the heartbeat), `/readyz` (Valkey and the
database; the healthcheck of the service) and `/metrics` (Prometheus).
To check that the clock is the leader:

```bash
docker compose exec wallet-clock /app/.venv/bin/python -c \
  "import urllib.request; print(urllib.request.urlopen('http://127.0.0.1:9192/metrics').read().decode())" | grep '^ows_clock_leader '
```

You see `ows_clock_leader 1.0`. The Helm chart runs the workers in queue
groups, with two clocks: see [Workers and clock](../docs/workers.md).

## Valkey

The wallet uses Valkey (a Redis-compatible server) for its background job
queue, its short-lived single-use values (nonces and proof ids that a
replay check refuses the second time) and its caches. Valkey is never the
record: the evidence stays in the database. The platform runs it in the
same shape as the Helm chart, on one host:

| Service | Function |
| --- | --- |
| `valkey` | The data server that is the primary at the first start (volume `valkey-data`). |
| `valkey-replica` | Its replica (volume `valkey-replica-data`). The primary refuses writes without an in-sync replica (`min-replicas-to-write 1`), so the wallet accepts a single-use value only when the replica has it. |
| `valkey-sentinel` | The Sentinel. It tells the wallet which server is the primary, and promotes the replica when the primary does not answer for 5 seconds. |

The data servers use the chart's settings (AOF `everysec`,
`maxmemory-policy noeviction`, `maxmemory 256mb`), with one difference:
like the other services in this folder, Valkey has no TLS on the Compose
network. The templates are in `config/valkey/`. At the start of each
service, `config/valkey/start.sh` writes the configuration with the
passwords to a tmpfs and finds the primary: the one the Sentinel reports,
else a data server with the role master, else `valkey`.

Each wallet role and the gateway log in with their own ACL user (no
`default` user). The passwords are in `secrets/valkey/` (`make secrets`):

| User | Process | Rights |
| --- | --- | --- |
| `wallet-config`, `wallet-service`, `wallet-worker`, `wallet-clock` | the wallet roles | the keys `ows:*`, `ows-wallet` and `ows-wallet:*`; read, write, scripts, `INFO` and `KEYS`; on the Sentinel, primary discovery |
| `gateway` | the gateway | the keys `gw:*`; read and write |
| `replication`, `sentinel`, `probe` | the replica, the Sentinel, the healthchecks | the commands that each one needs |

The rights are the same as in the Helm chart (`docs/redis.md` of the chart:
[Redis](../docs/redis.md#acl-users)). The redis section of each wallet file
names the Sentinel `valkey-sentinel:26379`, the primary name `ows`, the
role's user and its password file.

Check: `docker compose exec valkey-sentinel sh -c 'REDISCLI_AUTH="$(cat /run/secrets/valkey/sentinel)" valkey-cli -p 26379 --user sentinel SENTINEL get-master-addr-by-name ows'`
shows the primary (`valkey` at the first start) and `6379`.

## Security settings

Every service runs with a read-only root file system (`read_only: true`),
no Linux capabilities (`cap_drop: [ALL]`) and `no-new-privileges`, and all
of them except the root one-shot services below run as a non-root user.
Services write only to a tmpfs (in memory, with a size limit) or to a
volume. `tests/compose-files.sh` in this repository checks every service of
all profiles: a service without these settings fails the test.

| Service | User (UID:GID) | Writable paths |
| --- | --- | --- |
| `api`, `webhook` | `65532:65532` | `/tmp` (tmpfs, 64 MB) |
| `api-migrate`, `api-read-access-wallet`, `api-read-access-consent` | `65532:65532` | `/tmp` (tmpfs, 16 MB) |
| `gateway` | `65532:65532` | none |
| `consent` | `65532:65532` | `/tmp` (tmpfs, 64 MB) |
| `consent-migrate`, `consent-read-access` | `65532:65532` | `/tmp` (tmpfs, 16 MB) |
| `wallet-config`, `wallet-service` | `65532:65532` | `/tmp` (tmpfs, 64 MB) |
| `wallet-worker` | `65532:65532` | `/tmp` (the volume `wallet-worker-tmp`, on disk), `/run/ows-worker` (tmpfs, 64 MB) |
| `wallet-clock` | `65532:65532` | `/tmp` (tmpfs, 64 MB) |
| `wallet-database-roles`, `wallet-migrate`, `wallet-read-access-api`, `wallet-read-access-consent` | `65532:65532` | `/tmp` (tmpfs, 64 MB) |
| `dashboard` | `101:101` | `/tmp` (tmpfs, 64 MB): the nginx pid file and temporary files |
| `postgres` | `999:999` (the image's `postgres` user) | the volume `postgres-data`, `/var/run/postgresql` and `/tmp` (tmpfs) |
| `database-init` | `999:999` | `/tmp` (tmpfs, 16 MB) |
| `nats` | `65532:65532` | the volume `nats-data` |
| `openbao` | `100:1000` (the image's `openbao` user) | the volume `openbao-data`, `/tmp` (tmpfs, 64 MB) |
| `openbao-init` | your user (`HOST_UID:HOST_GID`) | `secrets/openbao/` (`init.json`), `/tmp` (tmpfs, 1 MB) |
| `valkey`, `valkey-replica` | `999:1000` (the image's `valkey` user) | the volumes `valkey-data` and `valkey-replica-data`, `/run/valkey` (tmpfs, 8 MB) and `/tmp` (tmpfs, 16 MB) |
| `valkey-sentinel` | `999:1000` | `/run/valkey` (tmpfs, 8 MB) and `/tmp` (tmpfs, 16 MB) |

- The configuration files are files in `generated/` (see
  [Configuration files](#configuration-files)): Compose can give a
  read-only service a configuration only from a file.
- `api`, `webhook`, `consent` and `dashboard` listen on port 80 in their
  containers. The sysctl `net.ipv4.ip_unprivileged_port_start=0` (also
  Docker's default) lets a non-root user open it.
- The NATS image has no user, and Docker creates the volume `nats-data` as
  root. Before `nats` starts, the one-shot service `nats-data-owner` hands
  each file and folder of the volume with another owner or group to the
  user 65532 (`find` with `-user` and `-group`, then `chown`). It runs as
  root with only the capabilities `CHOWN` and `DAC_READ_SEARCH` and without
  a network. On a store that is already correct, it only reads the owners
  and writes nothing (measured on a store of 1,000,000 files: about
  3 seconds, no writes). It is safe to stop at any point: the next start
  changes the rest.
- The api image has no shell: every service of the api image runs
  `/app/bin/igrant-api` directly.
- `openbao`, `openbao-init` and the Valkey services: `openbao` runs as the
  `openbao` user of its image (100:1000) and the Valkey services as the
  `valkey` user of their image (999:1000), the owners of their volumes.
  OpenBao needs no capability (`disable_mlock`). `openbao-init` runs as
  your user (`HOST_UID` and `HOST_GID`, which `make` sets) so that you own
  `init.json`. Without them it runs as root without capabilities and stops
  with "cannot open secrets/openbao/": use `make up`.

## Secrets

`make secrets` writes these files and keeps any file that already exists.
To create a new password, delete its file, run `make secrets`, then
`make up`. On an installation with data, never delete these files:

- `secrets/database/admin-password`: the database server keeps the
  password of its first start;
- `secrets/api/token-hash-secret.json`: all API keys stop working;
- `secrets/api/db-wrapping-keys.json`: the keys in the database become
  unusable;
- the files in `secrets/openbao/`: OpenBao and its keys become unusable.

| Folder | Content |
|---|---|
| `secrets/database/` | The passwords of the database server's admin user, of each database's owner user, of the read-only users and of the wallet's login database roles (`igrant_wallet_<name>-password`). |
| `secrets/api/` | The api keys (API secret key, token keys, database wrapping key, service key), its NATS seeds and the SMTP password. |
| `secrets/gateway/` | The key that the gateway signs its requests to the other components with. |
| `secrets/consent/`, `secrets/wallet/` | The keys that sign the NATS messages of consent and of the wallet, and their NATS seeds. The consent files are also made without consent. |
| `secrets/openbao/` | The OpenBao seal key, the password of the wallet's OpenBao user, and `init.json` (created at the first start). |
| `secrets/valkey/` | The passwords of the Valkey ACL users (see [Valkey](#valkey)). |
| `secrets/public/` | The public keys that the components use to verify each other (not secret). |

The folders are `0700`, so only your user can open them. The files are
`0644` because the services that run as a non-root user in their
containers must read the mounted files. `init.json` is `0600`.

## Reverse proxy

Your reverse proxy terminates TLS and sends each public host name to its
host port. It only routes: the platform does the authentication, CORS and
rate limits itself.

| Public host | Target |
|---|---|
| API (`API_PUBLIC_URL`) | `127.0.0.1:API_PORT` (proxy on the Docker host) or `<address of the Docker host>:API_PORT` |
| Wallet (`WALLET_PUBLIC_URL`) | `127.0.0.1:WALLET_PORT` or `<address of the Docker host>:WALLET_PORT` |
| Dashboard (`DASHBOARD_PUBLIC_URL`) | `127.0.0.1:DASHBOARD_PORT` or `<address of the Docker host>:DASHBOARD_PORT` |

The API host and the wallet host need these proxy settings:

- Request body size: at least 16 MB (the largest request of the API and of
  the wallet is 10 MB).
- Read timeout: at least 3900 seconds. The API's event streams
  (server-sent events, `text/event-stream`) stay open for up to 3900
  seconds.
- No response buffering, so each event reaches the client at once.
- The headers `Host`, `X-Forwarded-For` and `X-Forwarded-Proto`. The wallet
  uses the client address of `X-Forwarded-For` for the rate limit of the
  nonce routes and in its logs (the DPoP checks use the published URL, not
  the request scheme). It accepts these headers
  only from the loopback address and the ranges 10.0.0.0/8, 172.16.0.0/12,
  192.168.0.0/16, 100.64.0.0/10 and fc00::/7, so a reverse proxy on another
  computer must connect from one of these addresses.
- The header named in `CLIENT_ADDRESS_HEADER`, with the client address. The
  proxy must always replace it.

Example for nginx (one `server` block per host):

```nginx
client_max_body_size 16m;
proxy_read_timeout 3900s;
proxy_buffering off;
proxy_set_header Host $host;
proxy_set_header X-Real-IP $remote_addr;
proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
proxy_set_header X-Forwarded-Proto $scheme;
```

The example caches no responses. The metadata routes and the issuers' JWKS
answer with `Cache-Control: max-age=60` and an `ETag`; a proxy cache must
keep the header `Vary: Accept` of the credential issuer metadata (see
[Proxies in front of the cluster](../docs/exposure.md#proxies-in-front-of-the-cluster)).

With `PUBLISH_ADDRESS=0.0.0.0`, make sure that only your reverse proxy can
reach the host ports: clients must not get around the proxy. Docker adds
its port rules before the rules of ufw, so put your firewall rules in the
`DOCKER-USER` chain.

## Privacy dashboard

The privacy dashboard of an organisation is not available in this release:
the feature is off, and the api answers that it is not configured.

## Commands

| Command | Use |
|---|---|
| `make env` | Create `.env` from `.env.example` (keeps an existing `.env`). |
| `make secrets` | Create all secrets and keys in `secrets/` (keeps existing files). |
| `make configs` | Write the components' configuration files to `generated/` from `.env` (see [Configuration files](#configuration-files)). `make check` and `make up` run it. |
| `make check` | Write the configuration files, then check `.env`, `secrets/`, `generated/` and the Compose files. Starts no container. |
| `make up` | Check, then start the platform. |
| `make status` | Show the state of all services. |
| `make logs` | Follow the logs. |
| `make down` | Stop and remove the containers. The data stays. |
| `make reset` | Remove the containers and all data (asks first). |
| `make platform-operator ADMIN_EMAIL=... ADMIN_NAME=... ORG_NAME=... ORG_LOCATION=... ORG_POLICY_URL=... [ORGANISATION_TYPE=...]` | On a new installation: create the platform operator organisation and its first platform admin. |
| `make platform-grant-admin ADMIN_EMAIL=...` | Recovery when no platform admin can log in: give the platform admin right to an admin of the platform operator organisation. |
| `make platform-status` | Show the platform operator organisation and the platform admins (read only). |
| `make openbao-status` | Show the OpenBao seal status. |
| `make db-shell` | Open an SQL shell on the database server. |

## Troubleshooting

- `stat .../.env: no such file or directory`: run step 2 (`make env`).
- `make check` shows `missing: secrets/...`: run step 3 (`make secrets`).
- `stat .../generated/configs.env: no such file or directory`, or `make
  check` shows `generated/ is not the render of the current values`: run
  `make configs` (`make check` and `make up` run it too), see
  [Configuration files](#configuration-files).
- `openbao-init` shows `cannot open secrets/openbao/`: it ran without your
  user (`HOST_UID` and `HOST_GID`), for example after `docker compose up`
  without `make`. Run `make up`.
- `stat .../config/engine/<value>.env: no such file or directory`:
  `DB_ENGINE` (in `.env` or in your shell) is not `postgresql`.
- A one-shot service exits with a code other than 0, or a service does not
  start: read `docker compose logs <service>`. When a one-shot service
  fails, the services that wait for it do not start. One exception:
  `wallet-config` waits for `consent-read-access` only as an optional
  dependency (it runs only with consent). When it fails, `make up` shows
  the warning `optional dependency "consent-read-access" didn't complete
  successfully`, and `wallet-config` stays unhealthy.
- `make check` shows `CONSENT_ENABLED ... must be empty (no consent) or
  true`: `false` is not allowed, because any value turns the consent
  profile on. Empty the value.
- `make check` shows `secrets/public/nats-nkeys.conf has the consent nkey`
  or `has no consent nkey`: `CONSENT_ENABLED` changed after
  `make secrets`. Run `make secrets`, then `make check`.
- `wallet-migrate` shows `Exited (1)`: a migration failed; `Exited (2)`: a
  configuration or connection error; `Exited (3)`: the schema is at the
  head, but the grants are not complete. Read `docker compose logs
  wallet-migrate`, fix the cause, then run `make up` again.
- `wallet-migrate` shows `Exited (4)`: a partition step failed (for example
  the rows of a month in the default partition). The schema is at the head
  and the grants are complete. Take the scope and the month from `docker
  compose logs wallet-migrate`, run `docker compose run --rm --no-deps
  --entrypoint /app/.venv/bin/audit wallet-migrate partitions repair
  --scope <scope> --month <YYYY-MM>`, then run `make up` again.
- `wallet-migrate` shows `Exited (5)`: a newer release migrated the
  database, and this release is not compatible with it. Nothing changed,
  and `make up` cannot help. Set `PLATFORM_TAG` back to the newer release,
  or contact iGrant.io to downgrade the wallet database first.
- `make check` shows `no password file for the database roles ...`: run
  `make secrets` (a new release can add database roles).
- `openbao-init` shows "init.json is missing": OpenBao has data, but
  `secrets/openbao/init.json` is not there. Put your copy of the file back.
- A host port is already in use: change `API_PORT`, `WALLET_PORT` or
  `DASHBOARD_PORT` in `.env`. Also change the targets of your reverse proxy
  and each `http://localhost` public URL. Then run `make check` and
  `make up`.
- No e-mail arrives: set `SMTP_HOST`, `SMTP_FROM` (and `SMTP_USERNAME`),
  then run `make secrets`, `make check` and `make up`.

## Licence

Copyright (c) 2026 iGrant Technologies AB (iGrant.io), Sweden.

Apache License 2.0.
