# Database

This page explains the database options of the platform: one engine for all components, on a bundled or an external server.

[Back to the contents](../README.md#contents)

The whole platform uses one database engine: `database.engine` is `postgresql` or `mysql`. The engine applies to every component, to the migration and read access Jobs and to the network policies. Each component has its own database and owner user: `igrant_api`, `igrant_oidc`, `igrant_consent` and `igrant_wallet`.

| `database.mode` | The chart | You give |
| --- | --- | --- |
| `bundled` (default) | Runs one server: PostgreSQL 18.6 (`<release>-postgres`) or MariaDB 13.0 (`<release>-mysql`). Creates the databases, the users (init Job) and a TLS certificate. | The size of the volume and the resources |
| `external` | Creates the databases and the users with your admin user (init Job), or uses your databases and users | `database.external.host`, `.port`, the CA of the server (`database.tls.caSecret`), and an admin user (`database.external.admin`) or the passwords of your users (`database.auth.existingSecret`, one key for each database name) |

## TLS

All components verify the server with its CA (PostgreSQL `sslmode=verify-full`; MySQL with the CA and the host name). An external PostgreSQL without `database.tls.caSecret` gets `require` (encryption without verification). With `database.tls.enabled: false`, the connections are not encrypted.

## Size of the bundled PostgreSQL

The memory (`database.resources`, default 1536Mi) holds `shared_buffers`, about 5 MB for each connection up to `max_connections` (`database.postgresql.parameters`, default 150) and autovacuum (3 x `maintenance_work_mem`). Under load, each wallet role opens up to 50 connections. When you raise `max_connections`, raise the memory too: at the memory limit Kubernetes stops the server, and all components lose their connections.

## External PostgreSQL

The admin user needs `CREATEROLE` and `CREATEDB`, and must be able to `SET ROLE` to the users that it creates (a superuser, or PostgreSQL 16 or later with `createrole_self_grant = 'set, inherit'`).

## MySQL protocol

The bundled server is MariaDB 13.0, the server that the tests of all components use. An external server can be MariaDB or MySQL 8.0, with `default_time_zone='+00:00'`, `max_allowed_packet` of 64M or more, `character-set-server=utf8mb4` and `collation-server=utf8mb4_bin`. The admin user needs `CREATE USER` and `ALL PRIVILEGES ... WITH GRANT OPTION` on the databases and on the data scope databases of the wallet (for example `root`). Each process uses a fixed pool of up to 100 connections: give the server enough `max_connections` (the bundled server has 1000).

## Data scopes of the wallet

The wallet keeps its tables in data scopes: `platform`, `kms`, `trust`, `issuer`, `authorisation_server`, `relying_party`, `business_wallet`, `wallet_provider`, `events` and `conformance`. The wallet migration makes them.

| Engine | A data scope is | The grant |
| --- | --- | --- |
| PostgreSQL | A schema in the wallet database, for example `issuer` in `igrant_wallet` | None: the owner of the wallet database makes the schemas |
| MySQL | A database `<wallet>_<scope>` on the same server, for example `igrant_wallet_issuer` | The wallet user gets ``ALL PRIVILEGES ON `igrant\_wallet\_%`.*`` |

The init Job gives the MySQL grant. In a grant, `_` is a wildcard, so the pattern escapes each `_` of the wallet database name: for the name `my_wallet`, the pattern is `` `my\_wallet\_%` ``. When the wallet user cannot make the data scope databases, the wallet migration stops and shows the statements to run.

Rules on MySQL:

- The wallet database name has at most 43 characters: the longest data scope database, `<wallet>_authorisation_server`, must fit the 64 characters of a database name. The chart limits each name to 32 characters, because the name is also the MySQL user name.
- No other database may start with `<wallet>_`, because the wallet user gets all privileges on it. The chart refuses such a name for its own databases. On a shared server, do not give another installation a name such as `igrant_wallet_eu` next to `igrant_wallet`.
- MySQL 8.0 with `partial_revokes=ON` reads `_` and `%` in a grant as plain characters, so the pattern grant gives nothing. On such a server, a DBA grants each data scope database by its name, without `\`: ``GRANT ALL PRIVILEGES ON `igrant_wallet_issuer`.* TO 'igrant_wallet'@'%'``, one statement for each data scope. Check the list of data scopes at each upgrade.

The read views do not move: they stay in the schemas `read_v1` and `read_v2` (PostgreSQL) and in the wallet database (MySQL), with the same names and columns (see [Read access](read-access.md)).

## Without an admin user

Create the databases and the users yourself: each user owns its database (PostgreSQL) or has all privileges on it (MySQL, with `utf8mb4` and `utf8mb4_bin`). On MySQL, also give the wallet user all privileges on its data scope databases (see [Data scopes of the wallet](#data-scopes-of-the-wallet)). Then set `readAccess.jobs.enabled: false`, and let a DBA create the read-only users (see [Read access](read-access.md)).
