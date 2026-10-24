# Read access

This page explains the read-only database users with which the services read the data of other services.

[Back to the contents](../README.md#contents)

A service reads the data of another service from read-only views in the database of that service, with its own read-only user:

| Reader | Owner database | Values |
| --- | --- | --- |
| api | wallet | `readAccess.api.wallet` |
| consent | api, wallet | `readAccess.consent.api`, `readAccess.consent.wallet` |
| wallet | api, consent | `readAccess.wallet.api`, `readAccess.wallet.consent` |

The read access Jobs (`readAccess.jobs.enabled`, default `true`) create the users with the admin user of the database server at each install and upgrade (for example `ows-api-read-access-wallet-<revision>`). The passwords are in the Secret `<release>-read-access` (or your Secrets: `readAccess.<reader>.<owner>.passwordSecret`).

Without an admin user (an external server), a DBA creates the users with the SQL of the owner command `read-access print-sql` (for example `igrant-api read-access print-sql --config <file> --reader wallet --user wallet_api_reader`), and you set `readAccess.jobs.enabled: false` and the password Secrets.

PostgreSQL: the user gets `CONNECT`, `USAGE` on the schema of its views and `SELECT` on the views. The schema is `read_v1`, except for consent on the wallet database: it reads `read_v2` (the view `wallet_read_v2_presentation_event`). MySQL: the user is `'<user>'@'%'` and gets `SELECT` on the views in the owner database. The views have the migration user of the owner as definer: do not drop it.

The wallet views read the tables in the data scopes of the wallet (see [Database](database.md#data-scopes-of-the-wallet)) with the rights of the definer. The views keep their names, columns and places, and the read-only users get no right on the data scopes. On MySQL, the definer needs its grant on the data scope databases: do not revoke it.
