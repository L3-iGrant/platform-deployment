# Organisation Wallet Suite by iGrant.io: Docker Compose

This folder installs the Organisation Wallet Suite by iGrant.io on one Docker host. Use it for
tests and for small production installations. For a Kubernetes cluster, use
the Helm chart of this repository.

Do the steps of [Installation](#installation) one by one. Each step has a
check: do the next step only when you see the result of the check.

## Contents

- [Components](#components)
- [Prerequisites](#prerequisites)
- [Installation](#installation)
- [Operation](#operation)
- [Settings](#settings)
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
| Organisation wallet (`wallet-service`, `wallet-config`, `wallet-scheduler`) | Issues and verifies credentials (OpenID4VCI, OpenID4VP) for the EUDI Wallet and the European Business Wallet. | `WALLET_PORT` (8090) |
| Enterprise dashboard (`dashboard`) | The web application of the admins of your organisations. | `DASHBOARD_PORT` (3000) |
| Database (`postgres` or `mariadb`) | One database server for all components (`DB_ENGINE`). | none |
| NATS (`nats`) | The messages between the components. | none |
| OpenBao (`openbao`) | Keeps the signing keys of your organisations. | none |
| File store (`storage`) | Keeps the PDF documents of the verifier (the uploaded and the signed documents). | none |

Some services run one time at each start and then stop:
`database-init`, `api-migrate`, `consent-migrate`, `wallet-migrate`,
`api-read-access`, `consent-read-access`, `wallet-read-access` and
`openbao-init`. They create the databases, the database tables, the
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
  trust list service of the wallet (`https://trustlist.nxd.foundation`)
  and the services of other issuers, verifiers and wallets.
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

For a production installation, also set:

- `DB_ENGINE`: `postgresql` or `mysql`. Choose it now: a change later does
  not copy the data.
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

Check: you see `secrets: secrets/: 26 new, 0 kept (no value printed)`
(27 with the SMTP password).

### Step 4: Check the configuration

```bash
make check
```

This command checks the values of `.env`, the files in `secrets/` and the
Compose files for your `DB_ENGINE`. It starts no container.

Check: the last line is
`check: the configuration is valid (DB_ENGINE=<your engine>, <n> warning(s))`.
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
  `wallet-service`, `wallet-scheduler`, `dashboard`, `nats`, `openbao`,
  `storage` and `postgres` (or `mariadb`): `running`. The services with a
  health check also show `(healthy)`.
- `database-init`, the three `*-migrate` services, the three
  `*-read-access` services and `openbao-init`: `exited`, with the status
  `Exited (0)`.

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

### Step 8: Make the first admin

```bash
make admin ADMIN_EMAIL=admin@example.com ADMIN_NAME="First Admin" ADMIN_PHONE=+46700000000
```

This command creates the organisation type `Technology` and the first admin
account. It asks for the password of the admin (the input is hidden). To
use another organisation type, add `ORGANISATION_TYPE=<type>` to the
commands of step 8 and step 9, with the same value.

Check: you see two JSON lines, each with a status line after it (and a
log line of the api before it, for example `IAM provider chain: [builtin]`).
The second JSON line has your e-mail address and `"created":true` (or
`"created":false` when the admin exists).

### Step 9: Make the organisation of the first admin

The dashboard login refuses an admin without an organisation.

```bash
make organisation ADMIN_EMAIL=admin@example.com ORG_NAME="Example Organisation" \
  ORG_LOCATION=Stockholm ORG_POLICY_URL=https://example.com/privacy \
  ORG_DESCRIPTION="The organisation of the first admin."
```

Check: you see one JSON line with your e-mail address and
`"created":true` (or `"created":false` when the admin has an organisation).
Then log in on the dashboard with the first admin: the dashboard shows your
organisation.

## Operation

| Task | Command |
|---|---|
| Show the state of the services | `make status` |
| Follow the logs | `make logs` |
| Stop the platform (the data stays) | `make down` |
| Start the platform again | `make up` |
| Change a setting | Change `.env`, then `make check` and `make up` (Compose starts the changed services again) |
| Use a new release | Set its tag in `PLATFORM_TAG` in `.env`, then `make check` and `make up` |
| Delete all data and start again | `make reset`, then `make up`, then steps 8 and 9 |
| OpenBao seal status | `make openbao-status` |
| SQL shell of the database server | `make db-shell` |

Keep these files safe. Without them, the data of the platform cannot be
used:

- the folder `secrets/` (with `secrets/openbao/static-seal.key`, the key
  that unseals OpenBao, and `secrets/openbao/init.json`, the root token and
  the recovery key of OpenBao);
- the Docker volumes of the project `igrant-platform`.

## Settings

`.env.example` is the reference of all settings: each setting has its
meaning, its default and its allowed values in the file. `make env` copies
it to `.env`. Use `KEY=value` lines without spaces around `=`. A value in
your shell has priority over the value in `.env`.

| Setting | Default | Use |
|---|---|---|
| `DB_ENGINE` | `postgresql` | The database engine of all components: `postgresql` (PostgreSQL 18) or `mysql` (the MySQL protocol; the server is MariaDB 13). |
| `COMPOSE_PROFILES` | the derived line at the end of `.env.example` | Starts the database server of `DB_ENGINE`. Do not change it. |
| `TEST_CA_ENABLED`, `TEST_CA_LEAF_VALIDITY_DAYS` | `true`, `365` | The built-in test CA of the wallet issues test certificates for development and testing. They are not on any trusted list. Set `TEST_CA_ENABLED=false` when the installation must not offer it. `TEST_CA_LEAF_VALIDITY_DAYS` (1 to 3650) is the validity of a test certificate when the request gives none; the largest validity of the preset caps it. |
| `API_PUBLIC_URL`, `WALLET_PUBLIC_URL`, `DASHBOARD_PUBLIC_URL` | `http://localhost:8080`, `:8090`, `:3000` | The public URLs (your reverse proxy). |
| `PUBLISH_ADDRESS` | `127.0.0.1` | The IP address of the host ports. |
| `API_PORT`, `WALLET_PORT`, `DASHBOARD_PORT` | `8080`, `8090`, `3000` | The host ports. |
| `CLIENT_ADDRESS_HEADER` | empty | The header with the client address that your reverse proxy sets. |
| `SMTP_HOST`, `SMTP_PORT`, `SMTP_USERNAME`, `SMTP_FROM` | empty, `587`, empty, empty | Your SMTP server. Empty `SMTP_HOST`: no e-mail. |
| `IMAGE_REGISTRY` | `europe-docker.pkg.dev/jenkins-189019/igrantio` | The registry of the iGrant.io images (the default of the Helm chart). The repositories are `api`, `gateway`, `consent-management-backend`, `eudi-wallet` and `dashboard`. |
| `PLATFORM_TAG` | `2026.10.x` (placeholder) | The release tag of all iGrant.io images. Set the tag of your release. The dashboard shows it as its version. |
| `POSTGRES_IMAGE`, `MARIADB_IMAGE`, `NATS_IMAGE`, `OPENBAO_IMAGE`, `STORAGE_IMAGE` | see `.env.example` | The images of the dependencies. |

The databases are `igrant_api`, `igrant_oidc`, `igrant_consent` and
`igrant_wallet`, each with its own owner user.

The configuration files of the components are in `compose.platform.yaml`
(section `configs`). Compose writes the values of `.env` into them.

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
| `secrets/database/` | The passwords of the admin user of the database server, of the owner user of each database and of the read-only users. |
| `secrets/api/` | The keys of the api (API secret key, token keys, database wrapping key, service key), its NATS seeds and the SMTP password. |
| `secrets/gateway/` | The key that the gateway uses to sign its requests to the other components. |
| `secrets/consent/`, `secrets/wallet/` | The keys that sign the NATS messages of consent and of the wallet, and their NATS seeds. |
| `secrets/openbao/` | The seal key of OpenBao, the password of the OpenBao user of the wallet, and `init.json` (created at the first start). |
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
| `make admin ADMIN_EMAIL=... ADMIN_NAME=... ADMIN_PHONE=...` | Create the first admin. |
| `make organisation ADMIN_EMAIL=... ORG_NAME=... ORG_LOCATION=... ORG_POLICY_URL=... [ORG_DESCRIPTION=...]` | Create the organisation of the first admin. |
| `make openbao-status` | The seal status of OpenBao. |
| `make db-shell` | The SQL shell of the database server. |

## Troubleshooting

- `stat .../.env: no such file or directory`: do step 2 (`make env`).
- `make check` shows `missing: secrets/...`: do step 3 (`make secrets`).
- `stat .../config/engine/<value>.env: no such file or directory`:
  `DB_ENGINE` (in `.env` or in your shell) is not `postgresql` or `mysql`.
- A one-shot service shows an exit code other than 0, or a service does not
  start: `docker compose logs <service>`. When a one-shot service fails,
  the services that wait for it do not start.
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
