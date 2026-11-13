# Database

The database options of the platform: PostgreSQL for all components, on a bundled or an external server, and the database roles of the organisation wallet.

[Back to the contents](../README.md#contents)

The whole platform uses one database engine. `database.engine` is `postgresql`, the only supported engine: the api, consent and the organisation wallet accept only PostgreSQL, so any other value (for example `mysql`) stops the render with a message. The engine applies to every component, to the migration and read access Jobs, and to the network policies.

Each component has its own database and owner user: `igrant_api`, `igrant_oidc`, `igrant_consent` and `igrant_wallet`. The wallet's processes do not connect as its owner user: each one has its own database role (see [Database roles of the wallet](#database-roles-of-the-wallet)).

| `database.mode` | The chart | You give |
| --- | --- | --- |
| `bundled` (default) | Runs one PostgreSQL 18.6 server (`<release>-postgres`). Creates the databases and the users (init hook), the wallet's database roles (roles hook) and a TLS certificate. | The size of the volume and the resources |
| `external` | Creates the databases and the users (init hook) and the wallet's database roles (roles hook) with your admin user. Without the organisation wallet, it can also use your own databases and users. | `database.external.host`, `.port`, the CA of the server (`database.tls.caSecret`), and an admin user (`database.external.admin`, required with the organisation wallet) or the passwords of your users (`database.auth.existingSecret`, one key for each database name) |

## TLS

All components verify the server with its CA (`sslmode=verify-full`). An external PostgreSQL without `database.tls.caSecret` gets `require` (encryption without verification). With `database.tls.enabled: false`, the connections are not encrypted.

The bundled server always serves TLS, even with `database.tls.enabled: false`: that value only controls how the components connect. Its certificate is in the Secret `<release>-postgres-tls` (made by the chart, kept across upgrades) or in your Secret `database.tls.existingSecret`. The chart makes `<release>-postgres-tls` as a hook, before the other hooks. So an upgrade can turn `database.tls.enabled` on: the hooks get the CA, and the server already serves TLS.

## Size of the bundled PostgreSQL

The memory (`database.resources`, default 2048Mi) holds `shared_buffers`, about 5 MB for each connection up to `max_connections` (`database.postgresql.parameters`, default 250), and autovacuum (3 x `maintenance_work_mem`). The pools of all processes must fit in `max_connections` (see [Connection budget](#connection-budget)). If you raise `max_connections`, raise the memory too: at the memory limit, Kubernetes stops the server, and all components lose their connections.

## Connection budget

Each process has its own connection pools. A pool opens a connection only when its process needs one, so usually far fewer connections are open. But a load peak can open all of them, and when the server then refuses a connection, requests and jobs fail. The rule: the sum of these connections must be at most `max_connections` of the server, minus the connections that it keeps for the superuser (`superuser_reserved_connections`, 3 by default, and `reserved_connections`; the administrator connects as the superuser):

- for each process: the most connections of one pod (the table below), times its pods (with an autoscaler, its maximum: `organisationWallet.service.autoscaling.maxReplicas`, `autoscaling.keda.maxReplicaCount` of a worker group);
- the hooks of an install or an upgrade (the migration, the roles step and the read access steps run one after the other: 5 connections).

With the bundled server, the chart checks the rule: the render stops when the sum is too large, and the message shows the sum of each process. Then lower the pools (`database.pools`) or the replicas, or raise `max_connections` and `database.resources` together (see [Size of the bundled PostgreSQL](#size-of-the-bundled-postgresql)). With an external server, the chart cannot read its limit: the notes of `helm install` and `helm upgrade` print the sum. Give your server at least this sum, plus its reserved connections and its other users.

During a rollout, the new pods of a Deployment start before the old pods stop (`maxSurge: 25%`: one more pod for a Deployment of 2 to 4 pods). The free connections in the table below cover this for the pods whose pools are not full at that time. For an upgrade during a load peak, keep more connections free.

The pools of each process:

| Process | Connections of one pod | Values |
| --- | --- | --- |
| api core | `maxConns` of `DataBase`, of the OIDC database and of the wallet views reader, plus 1 health connection (outside the pools: a database check every 2 s) | `database.pools.api`, `.oidc`, `.apiReadAccess` |
| webhook handler | the same (also the health connection) | `database.pools.webhook`, `.oidc`, `.apiReadAccess` |
| gateway | `maxConns`, plus 1 health connection | `database.pools.gateway` |
| consent | `maxConns`, plus 5 for each of its two readers (api and wallet views), plus 1 health connection | `database.pools.consent` |
| wallet service | `poolSize` + `maxOverflow` (the sessions) + `allocationPoolSize` (the status list allocations) + 1 (the start and the schema check) | `database.pools.walletService` |
| wallet config | the same, plus 10 for each of its two readers (api and consent views), plus 1 for a WIA pool mint (see below) | `database.pools.walletConfig` |
| wallet worker | for each worker process: `threads` + `maxOverflow` (the sessions) + `allocationPoolSize` + at most 2 for each thread (an actor's lock has its own connection) + 1; plus 1 for the pod's health server | `database.pools.walletWorker`, the `processes` and `threads` of the group |
| wallet clock | 1 (the leader lock) + 1 (the health server) | none |

The WIA pool mint of the wallet unit attestation route (in the config role) holds the mint lock on its own connection while the route waits for the mint (the wallet's lock engine has no pool). The rule counts one mint for each config pod. Each additional mint that runs at the same time for another organisation opens one more connection: the free connections in the table cover a few.

The default values give these maximums. They are starting values, not measurements: a load test of your installation gives the real values.

| Process | Pods | Maximum for each pod | Sum |
| --- | --- | --- | --- |
| api core | 1 | 10 + 5 (OIDC) + 5 (reader) + 1 (health) = 21 | 21 |
| webhook handler | 1 | 5 + 5 (OIDC) + 5 (reader) + 1 (health) = 16 | 16 |
| gateway | 2 | 10 + 1 (health) = 11 | 22 |
| consent | 2 | 6 + 5 + 5 (readers) + 1 (health) = 17 | 34 |
| wallet service | 1 | 12 + 4 + 5 + 1 = 22 | 22 |
| wallet config | 1 | 8 + 4 + 2 + 20 (readers) + 1 + 1 (mint) = 36 | 36 |
| workers `main` | 2 | 8 + 2 + 2 + 16 (locks) + 1 + 1 (health) = 30 | 60 |
| workers `maintenance` | 1 | 2 + 2 + 2 + 4 (locks) + 1 + 1 (health) = 12 | 12 |
| clock | 2 | 1 (leader) + 1 (health) = 2 | 4 |
| **Total** | | | **227** |
| the hooks | | | 5 |
| the superuser (`superuser_reserved_connections`) | | | 3 |
| **`max_connections` of the bundled server** | | | **250** (15 free) |

## Connection pooler

The organisation wallet can connect through a connection pooler in transaction mode, for example when the pools of many pods are too large for `max_connections` of your server. The chart does not run the pooler. Use PgBouncer 1.21 or later with `pool_mode = transaction` and `max_prepared_statements` above 0 (the wallet sends named prepared statements), and a pool for the wallet database and each of its database roles (`<prefix>_launcher_app`, `<prefix>_jobs`).

| Value | Description |
| --- | --- |
| `database.pooler.host`, `.port` | The pooler (default port 6432). Empty host: no pooler. Its certificate must name the host, and the database CA (`database.tls`) must verify it. |
| `database.pooler.serverConnections` | The most connections that the pooler opens to the server for the wallet database (the sum of its pools). Required with the bundled server: the connection budget counts them instead of the wallet's session pools. |

With a pooler, the configuration of the service, config and worker processes has `database.pooler`, and their sessions (the requests, the actors, the NATS commands, the start checks) go through the pooler. These connections stay direct to the server:

- the locks of the WIA pool mints and of the clock;
- the status list allocations;
- the readers of the api and consent views;
- the readiness checks of the workers and the clock;
- the hooks (the migration lock and `SET ROLE` need one server session).

A connection through the pooler gives the server no timeout at its start. So the roles step sets the timeouts of each database role as its defaults (`ALTER ROLE ... SET`), and a process sets other timeouts in each transaction. The other components (the api, consent, the gateway) connect to the server.

The connection budget then counts, for the wallet, only the direct connections (the allocation pools, 20 for the readers and 1 mint for each config pod, 2 lock connections for each worker thread, the health checks, the clock) and `serverConnections`. With network policies, add the address of the pooler to `networkPolicy.externalDatabases`.

## External PostgreSQL

The admin user needs `CREATEROLE` and `CREATEDB`, and must be able to `SET ROLE` to the users that it creates (a superuser, or PostgreSQL 16 or later with `createrole_self_grant = 'set, inherit'`). The organisation wallet needs this admin user: the roles hook creates the wallet's database roles with it, and the render stops without `database.external.admin.user`.

Set the log parameters of [Logs of the database server](#logs-of-the-database-server) on your server too. The chart does not change the parameters of an external server.

The wallet's migration hook adds the PostgreSQL extension `pg_trgm` (to search issuances by part of the holder name) with `CREATE EXTENSION IF NOT EXISTS pg_trgm`, as the owner role `<prefix>_owner`. The roles hook gives this role `CREATE` on the wallet database and on the schema `public`. `pg_trgm` is a trusted extension (PostgreSQL 13 and later), so the role needs no superuser right. Your server must have the extension (in the PostgreSQL contrib modules; the image `postgres` has them) and must allow it: on a managed service, read its list of allowed extensions. If only the admin user of your service can create an extension, create it once before the upgrade, as that user, in the wallet database:

```sql
CREATE EXTENSION IF NOT EXISTS pg_trgm SCHEMA public;
```

Without the extension, the wallet's migration hook exits with code 1, and the pods of the earlier release keep running.

## Logs of the database server

The bundled server writes these events to its container log (`kubectl -n <namespace> logs <release>-postgres-0`, or the log system of your cluster):

| Parameter | The server logs |
| --- | --- |
| `log_statement = 'ddl'` | The text of each DDL statement: `CREATE`, `ALTER` and `DROP` (also of roles), `GRANT` and `REVOKE`. Not the data statements (`SELECT`, `INSERT`, `UPDATE`, `DELETE`). |
| `log_connections = on` | Each connection: the client address, the user, the database and the authentication method. |
| `log_disconnections = on` | The end of each session, with its duration. |

These logs show the changes to the schemas and the rights, and the sessions of each database user. The wallet's audit log (see [Audit log](audit-log.md)) does not see them: it records the actions of the platform, not the work of the database server. The migration hooks write the DDL of each release to this log. The components connect through connection pools, so there are few connection lines.

`database.postgresql.logDdlAndConnections` (default `true`) sets the three parameters. A parameter with the same name in `database.postgresql.parameters` wins, for example `log_statement: mod` to also log the data changes. With `false`, the chart sets none of the three. A change to these values restarts the server pod: the components lose their connections for a short time and connect again.

The log holds the text of each DDL statement. So never put a password in the text of a statement on this server: `ALTER ROLE ... PASSWORD '...'` writes the password to the log. Use `\password` of psql, which sends a SCRAM-SHA-256 verifier, not the password. The init hook sets the passwords of the owner users this way. The wallet's database roles hook (`database-roles apply`) and the read access Jobs of the wallet, the api and consent (`read-access apply`) also send only the SCRAM-SHA-256 verifier of each password, never the password.

On an external server, set the same three parameters yourself, for example as the database flags of your managed service.

pgaudit (an audit log with the objects of each statement) needs a PostgreSQL image with the extension. The bundled image `postgres` does not have it: pgaudit comes later, with its own image.

## Database roles of the wallet

Each process of the organisation wallet connects with its own database role. So no running process can change the schema of the wallet database: only the migration hook does. The role names start with the wallet database name (`database.databases.wallet.name`), for example `igrant_wallet_launcher_app`. A role name has at most 63 characters, so the wallet database name has at most 43.

| Database role | Used by | Rights |
| --- | --- | --- |
| `<prefix>_owner` | No process: it cannot log in | Owns the data scope schemas and their tables, views and sequences, and the read view schemas |
| `<prefix>_migrator` | The migration hook (`migrate-database`) | A member of the owner role: it changes the schema as the owner, then gives the grants on the new objects |
| `<prefix>_launcher_app` | The service and config pods | Reads and writes the tables of all data scopes; no schema change |
| `<prefix>_jobs` | The workers | Reads and writes the tables of the data scopes of the background tasks; no schema change |
| `<prefix>_clock` | The clock | Only connects: the clock takes its leader lock (a session advisory lock) and reads `pg_is_in_recovery()`. It reads and writes no table |

The roles hook also creates the audit reader `<prefix>_audit_reader`, which can only read the audit tables (see [Audit log](audit-log.md#check-the-audit-log)), and one role for each role application of the wallet (for example `<prefix>_issuer_app`). No chart pod uses them yet.

The role passwords are in the Secret `<release>-wallet-database-roles`: one key for each role, named without the prefix (for example `launcher_app`), with random values that are kept across upgrades. An upgrade adds a key for a new role (for example `clock`) with a random value. Each wallet pod and the migration hook mount only the key of their own role; the roles hook mounts all keys. No wallet pod or Job mounts the password of the owner user `igrant_wallet`, which stays the owner of the database. Only the roles hook and the wallet's read access hooks mount the password of the admin user.

## Hooks of the databases

The database hooks run in this order:

| Order | Hook | Connects as | What it does |
| --- | --- | --- | --- |
| 1 | The Secrets `<release>-postgres` (the database user passwords), `<release>-read-access` (the read-only user passwords), `<release>-wallet-database-roles` (the passwords of the wallet's database roles) and, with the bundled server, `<release>-postgres-tls` (its certificate and CA) | | Created before the other hooks, with the passwords and the certificate of the earlier release |
| 2 | `<release>-db-init` | The admin user | Waits until the database server is ready (up to 300 seconds), then creates the database and the owner user of each enabled component and sets the owner users' passwords |
| 3 | `<release>-wallet-database-roles` | The admin user | `database-roles apply`: creates the database roles and sets their passwords, makes the owner role the owner of the wallet database objects, creates the missing data scope schemas and gives the grants |
| 4 | `<release>-wallet-migrate`; on an upgrade also `<release>-api-migrate` and `<release>-consent-migrate` | `<prefix>_migrator`; the owner users of the api and consent | `migrate-database`: migrates the schema to the head of the release, gives the grants on the new objects, then creates the monthly audit log partitions and drops the months older than the retention (see [Audit log](audit-log.md#partitions)). The api and consent migrate their databases |
| 5 | `<release>-wallet-read-access-api`, `<release>-wallet-read-access-consent` | The admin user | `read-access apply`: the read-only users that the api and consent use to read the wallet database (see [Read access](read-access.md)) |

On a new installation, Helm creates the Secrets first (Helm `pre-install`) and runs the Jobs after the resources of the release exist (Helm `post-install`). So the init hook waits for the bundled server that starts with the release. The api and consent migrate their databases when their pods start: the api in an init container, consent before it serves. On an upgrade, the hooks run before any pod changes (Helm `pre-upgrade`); see [Upgrade](upgrade.md).

An upgrade can turn a component on (the organisation wallet, the api or consent): the hooks create its passwords and its database before its migration hook connects. With `database.auth.existingSecret`, add the password of the new database to your Secret before that upgrade. The wallet pods (except the clock) start work only when the database schema is at the head of their release: they wait up to 600 seconds, then exit, and Kubernetes starts them again.

## Data scopes of the wallet

The wallet keeps its tables in data scopes: `platform`, `kms`, `trust`, `issuer`, `authorisation_server`, `relying_party`, `business_wallet`, `individual_wallet_provider`, `business_wallet_provider`, `events` and `conformance`. A data scope is a schema in the wallet database, for example `issuer` in `igrant_wallet`. The roles hook creates the schemas, owned by the owner role, and the migration hook creates their tables.

The read views stay in the schemas `read_v1` and `read_v2`, with the same names and columns (see [Read access](read-access.md)).

## Without an admin user

Only without the organisation wallet (`organisationWallet.enabled: false`): create the databases and the users yourself, so that each user owns its database. Then set `readAccess.jobs.enabled: false`, and have a DBA create the read-only users (see [Read access](read-access.md)). The organisation wallet always needs the admin user, because the chart creates its database roles.
