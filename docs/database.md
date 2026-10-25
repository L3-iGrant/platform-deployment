# Database

This page explains the database options of the platform: PostgreSQL for all components, on a bundled or an external server.

[Back to the contents](../README.md#contents)

The whole platform uses one database engine: `database.engine` is `postgresql`, the only supported engine. The engine applies to every component, to the migration and read access Jobs and to the network policies. Each component has its own database and owner user: `igrant_api`, `igrant_oidc`, `igrant_consent` and `igrant_wallet`.

| `database.mode` | The chart | You give |
| --- | --- | --- |
| `bundled` (default) | Runs one PostgreSQL 18.6 server (`<release>-postgres`). Creates the databases, the users (init Job) and a TLS certificate. | The size of the volume and the resources |
| `external` | Creates the databases and the users with your admin user (init Job), or uses your databases and users | `database.external.host`, `.port`, the CA of the server (`database.tls.caSecret`), and an admin user (`database.external.admin`) or the passwords of your users (`database.auth.existingSecret`, one key for each database name) |

## TLS

All components verify the server with its CA (`sslmode=verify-full`). An external PostgreSQL without `database.tls.caSecret` gets `require` (encryption without verification). With `database.tls.enabled: false`, the connections are not encrypted.

## Size of the bundled PostgreSQL

The memory (`database.resources`, default 1536Mi) holds `shared_buffers`, about 5 MB for each connection up to `max_connections` (`database.postgresql.parameters`, default 150) and autovacuum (3 x `maintenance_work_mem`). Under load, each wallet role opens up to 50 connections. When you raise `max_connections`, raise the memory too: at the memory limit Kubernetes stops the server, and all components lose their connections.

## External PostgreSQL

The admin user needs `CREATEROLE` and `CREATEDB`, and must be able to `SET ROLE` to the users that it creates (a superuser, or PostgreSQL 16 or later with `createrole_self_grant = 'set, inherit'`).

## Data scopes of the wallet

The wallet keeps its tables in data scopes: `platform`, `kms`, `trust`, `issuer`, `authorisation_server`, `relying_party`, `business_wallet`, `wallet_provider`, `events` and `conformance`. A data scope is a schema in the wallet database, for example `issuer` in `igrant_wallet`. The wallet migration makes the schemas: the owner of the wallet database needs no other grant.

The read views stay in the schemas `read_v1` and `read_v2`, with the same names and columns (see [Read access](read-access.md)).

## Without an admin user

Create the databases and the users yourself: each user owns its database. Then set `readAccess.jobs.enabled: false`, and let a DBA create the read-only users (see [Read access](read-access.md)).
