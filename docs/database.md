# Database

This page explains the database options of the platform: PostgreSQL for all components, on a bundled or an external server, and the database roles of the organisation wallet.

[Back to the contents](../README.md#contents)

The whole platform uses one database engine: `database.engine` is `postgresql`, the only supported engine. The engine applies to every component, to the migration and read access Jobs and to the network policies. Each component has its own database and owner user: `igrant_api`, `igrant_oidc`, `igrant_consent` and `igrant_wallet`. The processes of the organisation wallet do not connect as its owner user: each one has its own database role (see [Database roles of the wallet](#database-roles-of-the-wallet)).

| `database.mode` | The chart | You give |
| --- | --- | --- |
| `bundled` (default) | Runs one PostgreSQL 18.6 server (`<release>-postgres`). Creates the databases, the users (init Job), the database roles of the wallet (roles hook) and a TLS certificate. | The size of the volume and the resources |
| `external` | Creates the databases and the users (init Job) and the database roles of the wallet (roles hook) with your admin user. Without the organisation wallet, it can also use your databases and users. | `database.external.host`, `.port`, the CA of the server (`database.tls.caSecret`), and an admin user (`database.external.admin`, required with the organisation wallet) or the passwords of your users (`database.auth.existingSecret`, one key for each database name) |

## TLS

All components verify the server with its CA (`sslmode=verify-full`). An external PostgreSQL without `database.tls.caSecret` gets `require` (encryption without verification). With `database.tls.enabled: false`, the connections are not encrypted.

## Size of the bundled PostgreSQL

The memory (`database.resources`, default 1536Mi) holds `shared_buffers`, about 5 MB for each connection up to `max_connections` (`database.postgresql.parameters`, default 150) and autovacuum (3 x `maintenance_work_mem`). Under load, each wallet role opens up to 50 connections. When you raise `max_connections`, raise the memory too: at the memory limit Kubernetes stops the server, and all components lose their connections.

## External PostgreSQL

The admin user needs `CREATEROLE` and `CREATEDB`, and must be able to `SET ROLE` to the users that it creates (a superuser, or PostgreSQL 16 or later with `createrole_self_grant = 'set, inherit'`). The organisation wallet needs this admin user: the roles hook makes the database roles of the wallet with it, and the render stops without `database.external.admin.user`.

Set the log parameters of [Logs of the database server](#logs-of-the-database-server) on your server too. The chart does not change the parameters of an external server.

## Logs of the database server

The bundled server writes these events to its container log (`kubectl -n <namespace> logs <release>-postgres-0`, or the log system of your cluster):

| Parameter | The server logs |
| --- | --- |
| `log_statement = 'ddl'` | The text of each DDL statement: `CREATE`, `ALTER` and `DROP` (also of roles), `GRANT` and `REVOKE`. Not the data statements (`SELECT`, `INSERT`, `UPDATE`, `DELETE`). |
| `log_connections = on` | Each connection: the client address, the user, the database and the authentication method. |
| `log_disconnections = on` | The end of each session, with its duration. |

These logs show the changes of the schemas and of the rights, and the sessions of each database user. The audit log of the wallet (see [Audit log](audit-log.md)) does not see them: it records the actions of the platform, not the work of the database server. The migration hooks write the DDL of each release to this log. The components connect through connection pools, so the connection lines stay few.

`database.postgresql.logDdlAndConnections` (default `true`) sets the three parameters. A value of the same name in `database.postgresql.parameters` wins, for example `log_statement: mod` to also log the data changes. With `false`, the chart sets none of the three. A change of these values restarts the server pod: the components lose their connections for a short time and connect again.

The log holds the text of each DDL statement. Do not put a password in the text of a statement on this server: `ALTER ROLE ... PASSWORD '...'` writes the password to the log. Use `\password` of psql, which sends a SCRAM-SHA-256 verifier, not the password. The init Job sets the passwords of the owner users in this way.

On an external server, set the same three parameters yourself, for example as the database flags of your managed service.

pgaudit (an audit log with the objects of each statement) needs a PostgreSQL image with the extension. The bundled image `postgres` does not have it: pgaudit comes later, with an own image.

## Database roles of the wallet

Each process of the organisation wallet connects with its own database role, so that no running process can change the schema of the wallet database: only the migration hook changes it. The names of the roles begin with the wallet database name (`database.databases.wallet.name`), for example `igrant_wallet_launcher_app`. A role name has at most 63 characters, so the wallet database name has at most 43.

| Database role | Used by | Rights |
| --- | --- | --- |
| `<prefix>_owner` | No process: it cannot log in | Owns the data scope schemas and their tables, views and sequences, and the read view schemas |
| `<prefix>_migrator` | The migration hook (`migrate-database`) | A member of the owner role: it changes the schema as the owner, then gives the grants on the new objects |
| `<prefix>_launcher_app` | The service and config pods | Reads and writes the tables of all data scopes; no schema change |
| `<prefix>_jobs` | The scheduler | Reads and writes the tables of the data scopes of the background tasks; no schema change |

The roles hook also makes the audit reader `<prefix>_audit_reader`, which can only read the audit tables (see [Audit log](audit-log.md#check-the-audit-log)), and one role for each role application of the wallet (for example `<prefix>_issuer_app`). No pod of the chart uses them yet.

The passwords of the roles are in the Secret `<release>-wallet-database-roles` (one key for each role, with the name of the role without the prefix, for example `launcher_app`; random values, kept across upgrades). Each wallet pod and the migration hook mount only the key of their own role; the roles hook mounts all keys. No wallet pod or Job mounts the password of the owner user `igrant_wallet`, which stays the owner of the database. Only the roles hook and the read access hooks of the wallet mount the password of the admin user.

## Hooks of the wallet

The hooks of the wallet run in this order:

| Order | Hook | Connects as | What it does |
| --- | --- | --- | --- |
| 1 | The Secret `<release>-wallet-database-roles` | | Created before the other hooks, with the passwords of the earlier release |
| 2 | `<release>-wallet-database-roles` | The admin user | `database-roles apply`: creates the database roles and sets their passwords, makes the owner role the owner of the objects of the wallet database, creates the missing data scope schemas and gives the grants |
| 3 | `<release>-wallet-migrate` | `<prefix>_migrator` | `migrate-database`: migrates the schema to the head of the release, gives the grants on the new objects, then makes the monthly partitions of the audit log and drops the months that are older than its retention (see [Audit log](audit-log.md#partitions)) |
| 4 | `<release>-wallet-read-access-api`, `<release>-wallet-read-access-consent` | The admin user | `read-access apply`: the read-only users with which the api and consent read the wallet database (see [Read access](read-access.md)) |

On a new installation, Helm creates the Secret first (Helm `pre-install`), and the Jobs run after the resources of the release exist (Helm `post-install`). The database server and its init Job start at the same time, so the roles hook tries again for up to 10 minutes while the server and the wallet database do not exist yet. On an upgrade, the hooks run before any pod changes (Helm `pre-upgrade`); see [Upgrade](upgrade.md). The wallet pods start their work only when the database schema is at the head of their release: they wait up to 600 seconds, then stop, and Kubernetes starts them again.

## Data scopes of the wallet

The wallet keeps its tables in data scopes: `platform`, `kms`, `trust`, `issuer`, `authorisation_server`, `relying_party`, `business_wallet`, `wallet_provider`, `events` and `conformance`. A data scope is a schema in the wallet database, for example `issuer` in `igrant_wallet`. The roles hook creates the schemas, with the owner role as their owner, and the migration hook creates their tables.

The read views stay in the schemas `read_v1` and `read_v2`, with the same names and columns (see [Read access](read-access.md)).

## Without an admin user

Only without the organisation wallet (`organisationWallet.enabled: false`): create the databases and the users yourself, so that each user owns its database. Then set `readAccess.jobs.enabled: false`, and let a DBA create the read-only users (see [Read access](read-access.md)). The organisation wallet always needs the admin user, because the chart creates its database roles.
