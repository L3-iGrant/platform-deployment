# iGrant.io platform: Docker Compose

This folder installs the iGrant.io platform on one Docker host. Use it for
development and tests. For a Kubernetes cluster, use the Helm chart of this
repository. For production, use the enterprise installation (on request:
support@igrant.io).

Do the steps of [Installation](#installation) one by one. Each step has a
check: do the next step only when you see the result of the check.

## Contents

- [Components](#components)
- [Prerequisites](#prerequisites)
- [Installation](#installation)
- [Operation](#operation)
- [Change to the release with the platform operator](#change-to-the-release-with-the-platform-operator)
- [Settings](#settings)
- [Database roles of the wallet](#database-roles-of-the-wallet)
- [Database server logs](#database-server-logs)
- [Audit log](#audit-log)
- [Worker and clock](#worker-and-clock)
- [Valkey](#valkey)
- [Secrets](#secrets)
- [Reverse proxy](#reverse-proxy)
- [Privacy dashboard](#privacy-dashboard)
- [Commands](#commands)
- [Troubleshooting](#troubleshooting)
- [Licence](#licence)

## Components

| Component | What it does | Host port |
|---|---|---|
| Gateway (`gateway`) | The entry point of all API calls of your systems and of the dashboard. It checks each request (API keys, logins, rate limits). | `API_PORT` (8080) |
| API (`api`) and webhook handler (`webhook`) | The organisations, the admins, the API keys, the webhooks to your systems. | none |
| Consent management (`consent`) | The data agreements and the consent records. | none |
| Organisation wallet (`wallet-service`, `wallet-config`, `wallet-worker`, `wallet-clock`) | Issues and verifies credentials (OpenID4VCI, OpenID4VP) for the EUDI Wallet and the European Business Wallet. The worker runs the background work, the clock sends the scheduled work (see [Worker and clock](#worker-and-clock)). | `WALLET_PORT` (8090) |
| Enterprise dashboard (`dashboard`) | The web application of the admins of your organisations. | `DASHBOARD_PORT` (3000) |
| Database (`postgres`) | One PostgreSQL server for all components (`DB_ENGINE`). | none |
| NATS (`nats`) | The messages between the components. | none |
| OpenBao (`openbao`) | Keeps the signing keys of your organisations. | none |
| Valkey (`valkey`, `valkey-replica`, `valkey-sentinel`) | The work queue, the single-use values and the caches of the wallet: a primary, a replica and a Sentinel. See [Valkey](#valkey). | none |

Some services run one time at each start and then stop:
`database-init`, `wallet-database-roles`, `api-migrate`,
`consent-migrate`, `wallet-migrate`, `api-read-access`,
`consent-read-access`, `wallet-read-access` and `openbao-init`. They create
the databases, the database roles of the wallet, the database tables, the
read-only database users and the configuration of OpenBao.

For HSM support and larger installations, see the chart pages [Connect your on-premise HSM](../docs/on-premise-hsm.md), [DPoD key stores](../docs/dpod-key-stores.md) and [Scaled deployments](../docs/scaled-deployments.md).

## Prerequisites

- A Linux host with Docker Engine and Docker Compose 2.24 or newer, GNU
  Make, Bash, OpenSSL and curl.
- Access to the image registry of iGrant.io for customers (`IMAGE_REGISTRY`,
  default `europe-docker.pkg.dev/jenkins-189019/igrantio`), and the tag of
  your release (`PLATFORM_TAG`). Ask support@igrant.io for a key file
  (`key.json`) or for access of your Google account.
- Your reverse proxy with TLS in front of the three host ports, and a DNS
  name for each public service (API, wallet, dashboard). The reverse proxy
  is yours: this folder does not install one. Its settings are in
  [Reverse proxy](#reverse-proxy).
- Outbound HTTPS from the host to the internet: the image registries, the
  EU list of trusted lists (`https://ec.europa.eu/tools/lotl/eu-lotl.xml`),
  the trusted lists that the organisations add as trust sources, and the
  services of other issuers, verifiers and wallets.
- Optional: your SMTP server, for the e-mails of the api (invitations of
  new admins, password reset).

## Installation

Do these steps in this folder (`docker-compose` of the repository).

### Step 1: Log in to the image registry

With a key file:

```bash
cat key.json | docker login -u _json_key --password-stdin https://europe-docker.pkg.dev
```

Or with your Google account (Google Cloud CLI):

```bash
gcloud auth configure-docker europe-docker.pkg.dev
```

With your own mirror, log in to your registry and set `IMAGE_REGISTRY` in
step 2.

Check: `docker login` shows `Login Succeeded`; `gcloud auth
configure-docker` shows that the credential helper of
`europe-docker.pkg.dev` is registered in your Docker configuration.

### Step 2: Make your settings

```bash
make env
```

Check: you see `env: wrote .env: set your values, then run make secrets`.

Open `.env` and set the values. Each value has its description in the file
(the same text is in [Settings](#settings)). Set `PLATFORM_TAG` for all
installations:

- `PLATFORM_TAG`: set the release tag. The value `2026.10.x` is a
  placeholder: `make secrets` and `make check` stop until you replace it.

For an installation behind your reverse proxy (not only on localhost), also set:

- `API_PUBLIC_URL`, `WALLET_PUBLIC_URL`, `DASHBOARD_PUBLIC_URL`: the
  `https://` URLs of your reverse proxy.
- `CLIENT_ADDRESS_HEADER`: the header with the client address that your
  reverse proxy sets (for example `X-Real-IP`).
- `SMTP_HOST`, `SMTP_PORT`, `SMTP_USERNAME`, `SMTP_FROM`: your SMTP server.

### Step 3: Make the secrets

```bash
make secrets
```

This command creates all passwords and keys of the platform in the folder
`secrets/` (git ignores it). It runs the api image without network to create
the keys. When `SMTP_USERNAME` is set, it asks for the SMTP password (the
input is hidden). It prints no secret value.

Check: you see `secrets: secrets/: 36 new, 0 kept (no value printed)`
(37 with the SMTP password).

### Step 4: Check the configuration

```bash
make check
```

This command checks the values of `.env`, the files in `secrets/` and the
Compose files for your `DB_ENGINE`. It starts no container.

Check: the last line is
`check: the configuration is valid (DB_ENGINE=postgresql, <n> warning(s))`.
Each `FAIL` line tells what to correct; correct it and do this step again.
Read each `WARN` line. For example, a public URL with `http://` does not
work with mobile wallets.

### Step 5: Start the platform

```bash
make up
```

This command does `make check` again, then starts the services. The first
start pulls the images and creates the databases; it can take some minutes.

Check: you see `up: started. make status shows the state of the services.`
Then wait two minutes and do:

```bash
make status
```

Check: you see one line for each service.

- `gateway`, `api`, `webhook`, `consent`, `wallet-config`,
  `wallet-service`, `wallet-worker`, `wallet-clock`,
  `dashboard`, `nats`, `openbao` and `postgres`: `running`. The services with a health check also
  show `(healthy)`.
- `database-init`, `wallet-database-roles`, the three `*-migrate`
  services, the three `*-read-access` services and `openbao-init`:
  `exited`, with the status `Exited (0)`.

If a service has another state, see [Troubleshooting](#troubleshooting).

### Step 6: Check the host ports

On the Docker host:

```bash
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8080/readyz
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8090/readyz
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:3000/
```

Use your `PUBLISH_ADDRESS` and ports when they are not the defaults.

Check: you see `200` three times (API, wallet, dashboard).

### Step 7: Connect your reverse proxy

Configure your reverse proxy as in [Reverse proxy](#reverse-proxy).

Check: `https://<your API host>/readyz` and `https://<your wallet
host>/readyz` give `200`, and `https://<your dashboard host>` shows the
login page of the dashboard.

### Step 8: Make the platform operator organisation and the first platform admin

An installation has one platform operator organisation. The platform admins
of this organisation add, suspend and delete the other organisations of the
installation in the dashboard. Only the command line makes the platform
operator organisation and gives the first platform admin right.

```bash
make platform-operator ADMIN_EMAIL=admin@example.com ADMIN_NAME="First Admin" \
  ORG_NAME="Example Wallet Provider" ORG_LOCATION=Stockholm \
  ORG_POLICY_URL=https://example.com/privacy
```

This command runs `igrant-api onboard bootstrap-platform` in the `api`
container. In one command, it makes the organisation type `Technology`
(when no type has the name), the first admin, the organisation with the
platform operator mark, and the platform admin right of the admin. To use
another organisation type, add `ORGANISATION_TYPE=<type>`.

The command asks for the first password of the admin (the input is hidden).
The password goes to the command on standard input: it is never an argument.
The password of a platform admin must have 15 characters or more (at most
256) and at least one special character, for example `!`, `#` or `%`. A
space is not a special character. It must not be a known password, and it must not have a part of the
e-mail address, the name or the organisation name. When the API refuses the
password, the command names the rules that failed, and makes nothing.

Check: you see one JSON line with `organisationId`, `adminId` and
`"created":true`, with a status line after it (and a log line of the api
before it, for example `IAM provider chain: [builtin]`). A second run with the
same values changes nothing and shows `"created":false`; the password of an
account that exists does not change. Then:

```bash
make platform-status
```

The JSON line has `operatorOrganisationId` (the id of your organisation)
and one entry in `platformAdmins`. The command reads only, and it prints
no secret.

Then log in on the dashboard with the e-mail address and the password. The
account must change the password at the first login: the dashboard opens
the page for the new password (15 characters or more, with at least one
special character). This needs no
e-mail service. The dashboard shows the functions of a platform admin in
the group "Wallet Provider (Orgs)".

Rules of the command:

- Use it only for a new installation. For an installation that has
  organisations, see
  [Change to the release with the platform operator](#change-to-the-release-with-the-platform-operator).
  When an admin with the e-mail address has a different organisation, the
  command exits 1 and changes nothing.
- There is no transfer and no removal of the platform operator mark.
- The wallet of the platform operator organisation is the wallet provider
  of the installation: the wallet gets this flag when an admin deploys it,
  and no route changes the flag later.

### After the installation: the other organisations and admins

A platform admin does these tasks in the dashboard, in the group "Wallet
Provider (Orgs)". No `make` target is necessary.

| Task | What an operator of the installation must know |
|---|---|
| Add an organisation with its first admin (page "Wallet Units", the + button) | The first admin gets an invitation by e-mail or a one-time password. An invitation needs the e-mail service (`SMTP_HOST`): without it, use the one-time password. The API deploys the wallet of the new organisation. |
| Set the features of an organisation ("Manage Features") | The panel has four switches: Issuer & Verifier, Wallet Unit (Holder), Consent Management and Data Marketplace. A new organisation has only Issuer & Verifier on, and the platform operator organisation has the four on. Getting Started, Account, Webhooks and Activity Logs have no switch and are always available. The gateway refuses the routes of a feature that is off for the organisation (`FEATURES_ENFORCE`, see [Settings](#settings)). |
| Suspend and resume an organisation | The gateway refuses each credential of a suspended organisation within 60 seconds. When the wallet did not get the state, the page shows a warning: send the request again. |
| Delete a suspended organisation ("Delete Organisation") | The deletion cannot be undone. The API deletes its data of the organisation in steps, consent purges its data, and the wallet deactivates the wallets of the organisation and purges them after its retention period. No background job repeats a failed step of the API: when the page shows failed steps, use "Run Deletion Again" until none is left. Each failed step is one `ERROR` line in `docker compose logs api`. |
| Give and remove the platform admin right (page "Platform Admins") | Only an admin of the platform operator organisation can get the right. A platform admin with a password of less than 15 characters sets a new password at the next login. |

Each other new password must have 12 characters or more and at least one
special character.

When no platform admin can log in, give the right to an admin of the
platform operator organisation with `make platform-grant-admin
ADMIN_EMAIL=...`.

The wallet login of the admins: the configuration of the api has no
`AdminAuth.walletLogin.organisationId`. With this empty value, the platform
operator organisation is the organisation of the wallet login, when it is
the wallet provider and its OIDC extension is on.

The targets `make admin` and `make organisation` of the earlier releases
stay. They make an admin (a password of 12 characters or more, with at
least one special character) and an
organisation without the platform operator mark and without the platform
admin right: the functions of a platform admin stay hidden in the
dashboard. Do not use them for the first organisation of a new
installation.

## Operation

| Task | Command |
|---|---|
| Show the state of the services | `make status` |
| Follow the logs | `make logs` |
| Stop the platform (the data stays) | `make down` |
| Start the platform again | `make up` |
| Change a setting | Change `.env`, then `make check` and `make up` (Compose starts the changed services again) |
| Use a new release | Set its tag in `PLATFORM_TAG` in `.env`, then `make secrets`, `make check` and `make up` (see [Database roles of the wallet](#database-roles-of-the-wallet)). From the release with the input limits, an installation has at most 100 organisations and 100 organisation wallets: an installation with more keeps them, but it cannot make a new organisation (see [Settings](#settings)). For the release with the platform operator, see [Change to the release with the platform operator](#change-to-the-release-with-the-platform-operator) |
| Show the platform operator organisation and the platform admins | `make platform-status` |
| Delete all data and start again | `make reset`, then `make up`, then step 8 |
| OpenBao seal status | `make openbao-status` |
| SQL shell of the database server | `make db-shell` |
| Log of the database server (DDL statements, connections) | `docker compose logs postgres` |

Keep these files safe. Without them, the data of the platform cannot be
used:

- the folder `secrets/` (with `secrets/openbao/static-seal.key`, the key
  that unseals OpenBao, and `secrets/openbao/init.json`, the root token and
  the recovery key of OpenBao);
- the Docker volumes of the project `igrant-platform`.

## Change to the release with the platform operator

From this release, an installation has one platform operator organisation
(see [step 8](#step-8-make-the-platform-operator-organisation-and-the-first-platform-admin)).
An installation that exists has none after the change to this release: the organisations
and their admins work as before, but the functions of a platform admin
stay hidden in the dashboard until you do the steps below. Do not use
`make platform-operator` for an installation that exists: with an e-mail
address that no admin has, it makes a new organisation with the platform
operator mark, and then no organisation that exists can get the mark.

Removed in this release of the API: the command `igrant-api iam
set-organisation-login` (a platform admin suspends and resumes an
organisation in the dashboard), the route `POST
/v4/onboard/platform/organisation` and the API key scope
`organisation:create` (a platform admin adds an organisation in the
dashboard). Change each script that uses them.

Before you start the new release, with the earlier release:

1. Choose the organisation that becomes the platform operator. The platform
   operator is always the wallet provider organisation of the installation.
   When one organisation is the wallet provider, only this organisation can
   be the platform operator. When no organisation is the wallet provider,
   choose an organisation with no wallet, or do item 2 for the organisation
   that you choose. To read the id of an organisation and the state of its
   wallet, use an API key of the organisation with the scopes `onboard` and
   `config`:

   ```text
   GET <API_PUBLIC_URL>/v4/onboard/platform/organisation
   GET <API_PUBLIC_URL>/v4/config/ows/wallet/deployment
   ```

   A release without the `/v4` routes has them at `GET
   /v2/onboard/organisation` and `GET /v2/config/digital-wallet/openid`.
   The first answer has the `id` of the organisation. The second answer
   has `statusStr` (`Deployed` for a deployed wallet) and
   `isWalletProvider`. An organisation with `"isWalletProvider": true`, or
   with a wallet that is not deployed, needs no more work before the new
   release.

2. Only for an organisation whose wallet is deployed and is not the wallet
   provider (and no other organisation is the wallet provider): make its
   wallet the wallet provider with the earlier release. The new release has
   no route and no command for this. An admin of that organisation, or an
   API key of it with the scope `config`, sends this request one time:

   ```text
   PUT <API_PUBLIC_URL>/v4/config/ows/wallet/deployment
   Content-Type: application/json

   {"isWalletProvider": true}
   ```

   A release without the routes `/v4/config/ows/...` has the same route at
   `PUT /v2/config/digital-wallet/openid`. A build of the API that has the
   command `platform set-operator` and still sets the flag in this route
   takes the body `{}` for the organisation with the platform operator
   mark. Check: the answer shows `"isWalletProvider": true`. If you did not
   do this item with the earlier release, the organisation cannot become
   the platform operator in the new release: contact iGrant.io.

3. Decide the first value of the feature gate (`FEATURES_ENFORCE`). With
   the default `true`, an organisation that uses the routes of a feature
   that is off for it gets `403` `feature_disabled` from the first request
   with the new release. To check the features first, set
   `FEATURES_ENFORCE=false` before you start the new release.

4. From the release with the four feature switches, an organisation has
   four product features: Issuer & Verifier, Wallet Unit (Holder), Consent
   Management and Data Marketplace. `api-migrate` of the new release
   changes the stored features of each organisation: Consent Management is
   on for an organisation that had the consent management, the data
   agreements, the personal data or the privacy dashboard on, and the three
   other switches keep their values. Nothing that an organisation can use
   goes off. Stop the gateway container of the earlier release before you
   start the new release, or set `FEATURES_ENFORCE=false` for the earlier
   release: with the changed records, a gateway of the earlier release
   refuses the routes of Account, Webhooks and Activity Logs. With the new
   release, a new organisation has only Issuer & Verifier on: a platform
   admin turns the other areas on in "Manage Features".

The start of the new release. A release that changes the messages between the services has a
release order: consent, then the wallet, then the API and the gateway. A
plain `make up` starts the new services in the order of their dependencies,
which is not this order: for some seconds, a container of the earlier
consent release can refuse the answers of the new API. To keep the order,
start the services in steps (the services lose their NATS connection for
some seconds and connect again):

```bash
# PLATFORM_TAG in .env is the tag of the new release
make secrets
make check
docker compose up -d --force-recreate nats
docker compose up -d consent
docker compose up -d wallet-config wallet-service wallet-worker wallet-clock
make up
```

Each step first runs the one-shot services that its services wait for (the
migrations and the read access). Check after each step: `make status`
shows the services of the step as `running`, and the one-shot services as
`exited` with the code 0.

After the start of the new release:

1. Give the organisation the platform operator mark, then give one of its
   admins the platform admin right:

   ```bash
   make platform-set-operator ORGANISATION_ID=6731f0c2a1b2c3d4e5f60789
   make platform-grant-admin ADMIN_EMAIL=admin@example.com
   ```

   Check: each command shows one JSON line with `"changed":true` (or
   `"changed":false` when the result exists), with a status line after it. `platform-set-operator`
   exits 1 for an organisation whose wallet is deployed and is not the
   wallet provider, and when a different organisation is the wallet
   provider or has the mark. `platform-grant-admin` exits 1 for an admin
   who is not an admin of the platform operator organisation.

2. `make platform-status` shows `operatorOrganisationId` with the id of
   your organisation, and the admin in `platformAdmins`.

3. The admin logs in on the dashboard (the gateway and the API read the
   platform operator again within 60 seconds). A platform admin needs a
   password of 15 characters or more: an admin with a shorter password sets
   a new password at this login. Each new password also needs at least one
   special character. This rule applies only when a password is set or
   changed: the accounts of today continue to log in, with no forced change.

4. With `FEATURES_ENFORCE=false`: a platform admin opens "Manage Features"
   of each organisation in the dashboard and reads the features that are
   off. Decide with the organisation: an organisation that uses the routes
   of a feature (for example with an API key) needs the feature on. The
   features with routes in the gate are the data agreements, the data
   disclosure agreements, issuer and verifier, the wallet units, consent
   management, the privacy dashboard, the account, the action logs and the
   webhooks. Then set `FEATURES_ENFORCE=true`, and do `make check` and
   `make up`.

5. An organisation that you stopped with `iam set-organisation-login`
   with the earlier release stays suspended in the API, but consent and the
   wallet do not know it. A platform admin sends the suspend request for it
   one time in the dashboard.

`config/nats/users.conf` of this release gives the API the right to publish
`api.v1.evt.organisation.deleted` (the deletion of an organisation). The
NATS server reads the file only when its container is made: the command
`docker compose up -d --force-recreate nats` above makes the container
again with the new file (the data of NATS is in its volume and stays).
Without it, the API cannot publish the deletion of an organisation, and
consent and the wallet keep the data of a deleted organisation.

## Settings

`.env.example` is the reference of all settings: each setting has its
meaning, its default and its allowed values in the file. `make env` copies
it to `.env`. Use `KEY=value` lines without spaces around `=`. A value in
your shell has priority over the value in `.env`.

| Setting | Default | Use |
|---|---|---|
| `DB_ENGINE` | `postgresql` | The database engine of all components: `postgresql` (PostgreSQL 18), the only supported engine. |
| `COMPOSE_PROFILES` | the derived line at the end of `.env.example` | Starts the database server of `DB_ENGINE`. Do not change it. |
| `TEST_CA_ENABLED`, `TEST_CA_LEAF_VALIDITY_DAYS` | `true`, `365` | The built-in test CA of the wallet issues test certificates for development and testing. They are not on any trusted list. Set `TEST_CA_ENABLED=false` when the installation must not offer it. `TEST_CA_LEAF_VALIDITY_DAYS` (1 to 3650) is the validity of a test certificate when the request gives none; the largest validity of the preset caps it. |
| `AUDIT_RETENTION_YEARS` | `7` | The years that the audit log of the wallet keeps the events of each data scope (1 to 999). See [Audit log](#audit-log). |
| `API_PUBLIC_URL`, `WALLET_PUBLIC_URL`, `DASHBOARD_PUBLIC_URL` | `http://localhost:8080`, `:8090`, `:3000` | The public URLs (your reverse proxy). |
| `PUBLISH_ADDRESS` | `127.0.0.1` | The IP address of the host ports. |
| `API_PORT`, `WALLET_PORT`, `DASHBOARD_PORT` | `8080`, `8090`, `3000` | The host ports. |
| `CLIENT_ADDRESS_HEADER` | empty | The header with the client address that your reverse proxy sets. |
| `FEATURES_ENFORCE` | `true` | The feature gate of the gateway (`Features.enforce`): with `true`, the gateway refuses a route of a product feature that is off for the organisation of the credential (`403`, `feature_disabled`). With `false`, it refuses no route for a feature: use it for an emergency, or for the first start of the release with the gate on an installation that exists (see [Change to the release with the platform operator](#change-to-the-release-with-the-platform-operator)). |
| `MAX_ORGANISATIONS`, `MAX_ORGANISATION_WALLET_UNITS` | empty (100) | The limits of the installation: the most organisations (`Limits.maxOrganisations` of the api, 1 to 100) and the most organisation wallet units of the wallet provider (`wallet_unit.organisation_wallet_units_max` of the wallet, 1 to 100). The create of one more organisation gets `409` (`organisation_limit_reached` from the api, `organisation_wallet_unit.limit_reached` from the wallet); the organisations and the organisation wallets that exist stay. Empty: the configuration files get no key, and the api and the wallet use their default, 100. Set a value only with the images of the release with the input limits: an api or a wallet of an earlier release does not know the key and does not start. The largest value is 100. An installation with more than 100 organisations or organisation wallets keeps them, but it cannot make a new organisation. |
| `SMTP_HOST`, `SMTP_PORT`, `SMTP_USERNAME`, `SMTP_FROM` | empty, `587`, empty, empty | Your SMTP server. Empty `SMTP_HOST`: no e-mail. |
| `IMAGE_REGISTRY` | `europe-docker.pkg.dev/jenkins-189019/igrantio` | The registry of the iGrant.io images (the default of the Helm chart). The repositories are `api`, `gateway`, `consent-management-backend`, `eudi-wallet` and `dashboard`. |
| `PLATFORM_TAG` | `2026.10.x` (placeholder) | The release tag of all iGrant.io images. Set the tag of your release. The dashboard shows it as its version. |
| `POSTGRES_IMAGE`, `NATS_IMAGE`, `OPENBAO_IMAGE`, `VALKEY_IMAGE` | see `.env.example` | The images of the dependencies. |

The databases are `igrant_api`, `igrant_oidc`, `igrant_consent` and
`igrant_wallet`, each with its own owner user. The wallet keeps its tables
in data scopes: schemas in `igrant_wallet` (for example `issuer`), which
`wallet-database-roles` creates. Each process of the wallet connects with
its own database role (see
[Database roles of the wallet](#database-roles-of-the-wallet)).

The configuration files of the components are in `compose.platform.yaml`
(section `configs`). Compose writes the values of `.env` into them.

## Database roles of the wallet

The wallet connects to `igrant_wallet` with one database role for each
process, never with the owner user `igrant_wallet` of the database. The
prefix of the database roles is the name of the database, `igrant_wallet`.

At each `make up`, the one-shot services of the wallet run in this order;
each one starts only when the one before it stopped with exit code 0:

1. `database-init` creates the database `igrant_wallet` and its owner user.
2. `wallet-database-roles` (`database-roles apply`, as the admin user of
   the database server) creates the owner role `igrant_wallet_owner` and
   the login database roles with their passwords from `secrets/database/`,
   creates the data scope schemas, gives the tables, views and sequences of
   an older release to the owner role, and gives the grants.
3. `wallet-migrate` (`migrate-database`, as `igrant_wallet_migrator`)
   applies the migrations of the wallet as the owner role, then gives the
   database roles their grants on the new tables. It is the only service
   that changes the schema of the wallet.
4. `wallet-read-access` (as the admin user) creates the read-only users of
   the api and of consent on the wallet views. The wallet processes start
   after `wallet-migrate`.

| Process | Service | Database role |
|---|---|---|
| Database roles | `wallet-database-roles` | The admin user (`DB_ADMIN_USER`) |
| Migrations | `wallet-migrate` | `igrant_wallet_migrator` |
| Read access | `wallet-read-access` | The admin user (`DB_ADMIN_USER`) |
| Config routes and public routes | `wallet-config`, `wallet-service` | `igrant_wallet_launcher_app` |
| Background work | `wallet-worker` | `igrant_wallet_jobs` |
| Clock | `wallet-clock` | `igrant_wallet_clock` (it can only connect) |

The database roles of the wallet processes read and write the data, but
cannot change the schema. A wallet process (but the clock) waits until
the schema is at the head of its code. When the schema does not get there in time, the
process stops and Compose starts it again.

The other login database roles (`igrant_wallet_audit_reader` and one
database role for each role application, for example
`igrant_wallet_issuer_app`) also get their passwords. No process of this
release logs in with them. The audit reader can only read the audit log
(see [Audit log](#audit-log)).

A new release can add database roles and migrations. Set its tag in
`PLATFORM_TAG` in `.env`, then do `make secrets`, `make check` and
`make up`. `make secrets` creates the password files that the release adds
and keeps the others. The one-shot services then do the database work in
the order above: there is no step by hand.

## Database server logs

The server `postgres` writes these events to its container log
(`docker compose logs postgres`):

- the text of each DDL statement (`log_statement=ddl`): `CREATE`, `ALTER`
  and `DROP` (also of roles), `GRANT` and `REVOKE`, but not the data
  statements;
- each connection, with the client address, the user, the database and the
  authentication method (`log_connections=on`);
- the end of each session, with its duration (`log_disconnections=on`).

These logs show the changes of the schemas and of the rights, and the
sessions of each database user. `make check` gives a warning when the
command of `postgres` does not have the three settings, for example when a
Compose override file changes it.

The log holds the text of each DDL statement. Do not put a password in the
text of a statement on this server: `ALTER ROLE ... PASSWORD '...'` writes
the password to the log. Use `\password` of psql (`make db-shell`), which
sends a SCRAM-SHA-256 verifier, not the password. `database-init` sets the
passwords of the owner users in this way. `wallet-database-roles`
(`database-roles apply`) and the read access services of the wallet, the
api and consent (`read-access apply`) also send the SCRAM-SHA-256 verifier
of each password, never the password.

Docker keeps the container logs. Set a log rotation for your Docker
daemon (the options `max-size` and `max-file` of the log driver
`json-file`), so that the logs do not fill the disk.

## Audit log

The wallet records the actions of the platform in an audit log in its
database: for example a configuration change, a key retirement, an issued
credential or a refused request. Each data scope of the wallet has its own
hash chains. Every hour, `wallet-worker` signs an anchor of each scope
with the Transit key `audit-anchor-<scope>` of OpenBao; the worker makes the
keys at its start.

| Part | Compose |
| --- | --- |
| Retention | `AUDIT_RETENTION_YEARS` (default 7) in each wallet file and in `wallet-migrate` |
| Monthly partitions | `wallet-migrate` makes the partitions of the next 24 months at each start |
| Audit bucket | None. The anchors stay in the database only, no month is exported, and `wallet-migrate` drops no partition |

An installation of the Helm chart can copy the anchors and the monthly
exports to a write-once bucket: an S3 store with Object Lock in
compliance mode, or Google Cloud Storage with a locked retention policy
(see [Audit log](../docs/audit-log.md)). Compose has no such bucket: a
store on the same host is not a place for evidence.

Check the chains and the anchors (exit code 0: verified; 1: evidence of
change, with the first bad row of each chain; 2: an input or connection
error):

```bash
docker compose exec wallet-worker /app/.venv/bin/audit verify
```

The check of the bucket copies (C9) is skipped. For support,
`audit timeline --request-id <id>` gives the events of one request in time
order.

The worker also purges the wallet data every day: soft-deleted history
rows 30 days after their delete, a deleted organisation 30 days and a
deleted sandbox 7 days after its deactivation, dead letters after 30 days,
the tokens of the issued credentials 30 days after the issue
(the `retention` settings of the wallet, with their defaults).

## Worker and clock

The wallet runs its background work as actors on the queues of Valkey:

| Service | Function |
| --- | --- |
| `wallet-worker` | Runs the actors of all queues (`realtime`, `attestation`, `status`, `kms`, `maintenance`): one worker process with 8 threads. A stop waits at most one hour for the running actors (`stop_grace_period`); an actor that does not end in that time runs again from its message. |
| `wallet-clock` | Sends the messages of the cron actors to the queues when their time comes. It holds the leader lock of the database while it sends. It connects to no NATS and to no key store. |

The worker and the clock have a health port (9191 and 9192, only on the
Compose network): `/healthz` (the heartbeat), `/readyz` (Valkey and the
database, the healthcheck of the service) and `/metrics` (Prometheus).
Check that the clock leads:

```bash
docker compose exec wallet-clock /app/.venv/bin/python -c \
  "import urllib.request; print(urllib.request.urlopen('http://127.0.0.1:9192/metrics').read().decode())" | grep '^ows_clock_leader '
```

You see `ows_clock_leader 1.0`. The Helm chart runs the workers in groups
of queues and two clocks: see [Workers and clock](../docs/workers.md).

When you use a new release on data of a release that kept each issuance
in one table (`issuer.credential_issuance`), the worker copies the
issuances into the tables of the issuance (see
[The copy of the issuances](../docs/workers.md#the-copy-of-the-issuances)).
Check the progress:

```bash
docker compose exec wallet-worker /app/.venv/bin/issuance-backfill status
```

The copy is complete when `progress.applied` is `true` and
`counts.missing` and `counts.changed` are `0`. A later release drops the
table of the earlier releases: use that release only after the copy is
complete.

## Valkey

The wallet uses Valkey (a Redis-compatible server) for the work queue of
its background jobs, the short-lived single-use values (the nonces and the
proof ids that a replay check refuses the second time) and the caches.
Valkey is never a record: the evidence stays in the database. The
platform runs it in the same shape as the Helm chart, on one host:

| Service | Function |
| --- | --- |
| `valkey` | The data server that is the primary at the first start (volume `valkey-data`). |
| `valkey-replica` | Its replica (volume `valkey-replica-data`). The primary refuses writes without a replica in sync (`min-replicas-to-write 1`): the wallet accepts a single-use value only when the replica has it. |
| `valkey-sentinel` | The Sentinel. It gives the primary to the wallet, and it makes the replica the primary when the primary does not answer for 5 seconds. |

The settings of the data servers are those of the chart (AOF `everysec`,
`maxmemory-policy noeviction`, `maxmemory 256mb`), with one difference: the
Compose network has no Valkey TLS, as for the other services of this
folder. The templates are in `config/valkey/`; `config/valkey/start.sh`
writes the configuration with the passwords to a tmpfs at the start of
each service, and finds the primary: the one that the Sentinel gives, else
a data server with the role master, else `valkey`.

Each wallet role and the gateway log in with their own ACL user (no
`default` user). The passwords are in `secrets/valkey/` (`make secrets`):

| User | Process | Rights |
| --- | --- | --- |
| `wallet-config`, `wallet-service`, `wallet-worker`, `wallet-clock` | the roles of the wallet | the keys `ows:*`, `ows-wallet` and `ows-wallet:*`; read, write, scripts, `INFO` and `KEYS`; on the Sentinel, the discovery of the primary |
| `gateway` | the gateway | the keys `gw:*`; read and write |
| `replication`, `sentinel`, `probe` | the replica, the Sentinel, the healthchecks | the commands of each |

The rights are the rights of the Helm chart (`docs/redis.md` of the chart:
[Redis](../docs/redis.md#acl-users)). The redis section of each wallet file
names the Sentinel `valkey-sentinel:26379`, the primary name `ows`, the
user of the role and its password file.

Check: `docker compose exec valkey-sentinel sh -c 'REDISCLI_AUTH="$(cat /run/secrets/valkey/sentinel)" valkey-cli -p 26379 --user sentinel SENTINEL get-master-addr-by-name ows'`
shows the primary (`valkey` at the first start) and `6379`.

## Secrets

`make secrets` writes these files. It keeps a file that exists. To create a
new password, delete its file, do `make secrets`, then `make up`. On an
installation with data, do not delete these files:

- `secrets/database/admin-password`: the database server keeps the
  password of its first start;
- `secrets/api/token-hash-secret.json`: all API keys stop working;
- `secrets/api/db-wrapping-keys.json`: the keys in the database become
  unusable;
- the files in `secrets/openbao/`: OpenBao and its keys become unusable.

| Folder | Content |
|---|---|
| `secrets/database/` | The passwords of the admin user of the database server, of the owner user of each database, of the read-only users and of the login database roles of the wallet (`igrant_wallet_<name>-password`). |
| `secrets/api/` | The keys of the api (API secret key, token keys, database wrapping key, service key), its NATS seeds and the SMTP password. |
| `secrets/gateway/` | The key that the gateway uses to sign its requests to the other components. |
| `secrets/consent/`, `secrets/wallet/` | The keys that sign the NATS messages of consent and of the wallet, and their NATS seeds. |
| `secrets/openbao/` | The seal key of OpenBao, the password of the OpenBao user of the wallet, and `init.json` (created at the first start). |
| `secrets/valkey/` | The passwords of the ACL users of Valkey (see [Valkey](#valkey)). |
| `secrets/public/` | The public keys that the components use to verify each other (no secret). |

The folders are `0700`: only your user can open them. The files are
`0644`, because the services that run as a non-root user in their
containers read the mounted files. `init.json` is `0600`.

## Reverse proxy

Your reverse proxy ends TLS and sends each public host name to its host
port. It only routes: the platform does the authentication, the CORS and
the rate limits itself.

| Public host | Target |
|---|---|
| API (`API_PUBLIC_URL`) | `127.0.0.1:API_PORT` (proxy on the Docker host) or `<address of the Docker host>:API_PORT` |
| Wallet (`WALLET_PUBLIC_URL`) | `127.0.0.1:WALLET_PORT` or `<address of the Docker host>:WALLET_PORT` |
| Dashboard (`DASHBOARD_PUBLIC_URL`) | `127.0.0.1:DASHBOARD_PORT` or `<address of the Docker host>:DASHBOARD_PORT` |

Settings that the platform needs on the API host and the wallet host:

- Request body size: at least 16 MB (the largest request of the API and
  of the wallet is 10 MB).
- Read timeout: at least 3900 seconds. The event streams (server-sent
  events, `text/event-stream`) of the API stay open up to 3900 seconds.
- No response buffering, so that each event goes to the client at once.
- The headers `Host`, `X-Forwarded-For` and `X-Forwarded-Proto`. The wallet
  uses `X-Forwarded-Proto` for the DPoP checks. It uses these headers only
  from the loopback address and the ranges 10.0.0.0/8, 172.16.0.0/12,
  192.168.0.0/16, 100.64.0.0/10 and fc00::/7: a reverse proxy on another
  computer must connect from one of these addresses.
- The header of `CLIENT_ADDRESS_HEADER` with the address of the client,
  always replaced by the proxy.

Example for nginx (one `server` block for each host):

```nginx
client_max_body_size 16m;
proxy_read_timeout 3900s;
proxy_buffering off;
proxy_set_header Host $host;
proxy_set_header X-Real-IP $remote_addr;
proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
proxy_set_header X-Forwarded-Proto $scheme;
```

The example keeps no answer in a cache. The metadata routes and the JWKS
of the issuers answer with `Cache-Control: max-age=60` and an `ETag`: a
proxy cache must keep the header `Vary: Accept` of the credential issuer
metadata (see
[Proxies in front of the cluster](../docs/exposure.md#proxies-in-front-of-the-cluster)).

With `PUBLISH_ADDRESS=0.0.0.0`, let only your reverse proxy reach the host
ports: a client must not reach the ports without the proxy. Docker sets its
port rules before the rules of ufw: put your firewall rules in the
`DOCKER-USER` chain.

## Privacy dashboard

The privacy dashboard of an organisation is not available in this release:
the function is off, and the api answers that it is not configured.

## Commands

| Command | Use |
|---|---|
| `make env` | Create `.env` from `.env.example` (keeps a `.env` that exists). |
| `make secrets` | Create all secrets and keys in `secrets/` (keeps the files that exist). |
| `make check` | Check `.env`, `secrets/` and the Compose files. No container starts. |
| `make up` | Check, then start the platform. |
| `make status` | The state of all services. |
| `make logs` | Follow the logs. |
| `make down` | Stop and remove the containers. The data stays. |
| `make reset` | Remove the containers and all data (asks first). |
| `make platform-operator ADMIN_EMAIL=... ADMIN_NAME=... ORG_NAME=... ORG_LOCATION=... ORG_POLICY_URL=... [ORGANISATION_TYPE=...]` | A new installation: create the platform operator organisation and its first platform admin. |
| `make platform-set-operator ORGANISATION_ID=...` | An installation that exists: give an organisation the platform operator mark. |
| `make platform-grant-admin ADMIN_EMAIL=...` | Give an admin of the platform operator organisation the platform admin right. |
| `make platform-status` | The platform operator organisation and the platform admins (reads only). |
| `make admin ADMIN_EMAIL=... ADMIN_NAME=... ADMIN_PHONE=...` | Earlier releases: create an admin without an organisation. |
| `make organisation ADMIN_EMAIL=... ORG_NAME=... ORG_LOCATION=... ORG_POLICY_URL=... [ORG_DESCRIPTION=...]` | Earlier releases: create the organisation of that admin, without the platform operator mark. |
| `make openbao-status` | The seal status of OpenBao. |
| `make db-shell` | The SQL shell of the database server. |

## Troubleshooting

- `stat .../.env: no such file or directory`: do step 2 (`make env`).
- `make check` shows `missing: secrets/...`: do step 3 (`make secrets`).
- `stat .../config/engine/<value>.env: no such file or directory`:
  `DB_ENGINE` (in `.env` or in your shell) is not `postgresql`.
- A one-shot service shows an exit code other than 0, or a service does not
  start: `docker compose logs <service>`. When a one-shot service fails,
  the services that wait for it do not start.
- `wallet-migrate` shows `Exited (1)`: a migration failed; `Exited (2)`:
  a configuration or connection error; `Exited (3)`: the schema is at the
  head, but the grants are not complete. Read `docker compose logs
  wallet-migrate`, correct the cause, then do `make up` again.
- `make check` shows `no password file for the database roles ...`: do
  `make secrets` (a new release can add database roles).
- `openbao-init` shows "init.json is missing": OpenBao has data, but
  `secrets/openbao/init.json` is not there. Put your copy of the file back.
- A host port is in use: change `API_PORT`, `WALLET_PORT` or
  `DASHBOARD_PORT` in `.env`. Also change the targets of your reverse proxy
  and each `http://localhost` public URL. Then do `make check` and
  `make up`.
- No e-mail arrives: set `SMTP_HOST`, `SMTP_FROM` (and `SMTP_USERNAME`),
  run `make secrets`, `make check` and `make up`.

## Licence

Copyright (c) 2026 iGrant Technologies AB (iGrant.io), Sweden.

Apache License 2.0.
