# Read access

This page explains the read-only database users with which the services read the data of other services.

[Back to the contents](../README.md#contents)

A service reads the data of another service from read-only views in the database of that service, with its own read-only user:

| Reader | Owner database | Values |
| --- | --- | --- |
| api | wallet | `readAccess.api.wallet` |
| consent | api, wallet | `readAccess.consent.api`, `readAccess.consent.wallet` |
| wallet | api, consent | `readAccess.wallet.api`, `readAccess.wallet.consent` |

The read access Jobs (`readAccess.jobs.enabled`, default `true`) create the users with the admin user of the database server at each install and upgrade (for example `ows-api-read-access-wallet-<revision>`). There is one Job for each reader and owner that are both on in this chart: with consent off, no Job creates a read-only user of consent. On the wallet database they are hooks after the migration hook of the wallet (`ows-wallet-read-access-api`, `ows-wallet-read-access-consent`; see [Database](database.md#hooks-of-the-databases)). The passwords are in the Secret `<release>-read-access`, a hook that Helm creates before the other hooks (or your Secrets: `readAccess.<reader>.<owner>.passwordSecret`).

Without an admin user (an external server without the organisation wallet), a DBA creates the users with the SQL of the owner command `read-access print-sql` (for example `igrant-api read-access print-sql --config <file> --reader wallet --user wallet_api_reader`), and you set `readAccess.jobs.enabled: false` and the password Secrets.

The user gets `CONNECT`, `USAGE` on the schema of its views and `SELECT` on the views. The schema is `read_v1`, except for consent on the wallet database: it reads `read_v2` (the view `wallet_read_v2_presentation_event`). The views belong to the migration user of the owner (on the wallet database, the owner role `<prefix>_owner`; see [Database](database.md#database-roles-of-the-wallet)): do not drop it.

The wallet views read the tables in the data scopes of the wallet (see [Database](database.md#data-scopes-of-the-wallet)) with the rights of the owner role that owns the views. The views keep their names, columns and places, and the read-only users get no right on the data scopes.
