# Read access

The read-only database users that the services use to read the data of other services.

[Back to the contents](../README.md#contents)

A service reads another service's data from read-only views in that service's database, with its own read-only user:

| Reader | Owner database | Values |
| --- | --- | --- |
| api | wallet | `readAccess.api.wallet` |
| consent | api, wallet | `readAccess.consent.api`, `readAccess.consent.wallet` |
| wallet | api, consent | `readAccess.wallet.api`, `readAccess.wallet.consent` |

A service that is not installed has no reader of its views: without consent, the wallet reads only the api; without the organisation wallet, the api and consent read no wallet views. You then do not set the values of these readers (see [Components](components.md#the-services-of-the-installation)).

The read access Jobs (`readAccess.jobs.enabled`, default `true`) create the users with the admin user of the database server at each install and upgrade (for example `ows-api-read-access-wallet-<revision>`). There is one Job for each reader and owner that are both on in this chart: with consent off, no Job creates a read-only user of consent. On the wallet database, the Jobs are hooks that run after the wallet's migration hook (`ows-wallet-read-access-api`, `ows-wallet-read-access-consent`; see [Database](database.md#hooks-of-the-databases)). The passwords are in the Secret `<release>-read-access`, a hook that Helm creates before the other hooks (or in your Secrets: `readAccess.<reader>.<owner>.passwordSecret`).

Without an admin user (an external server without the organisation wallet), a DBA creates the users with the SQL of the owner's command `read-access print-sql` (for example `igrant-api read-access print-sql --config <file> --reader wallet --user wallet_api_reader`). Then you set `readAccess.jobs.enabled: false` and the password Secrets.

The user gets `CONNECT`, `USAGE` on the schema of its views, and `SELECT` on the views. The schema is `read_v1`, except for consent on the wallet database: it reads `read_v2` (the view `wallet_read_v2_presentation_event`). The views belong to the owner's migration user (on the wallet database, the owner role `<prefix>_owner`; see [Database](database.md#database-roles-of-the-wallet)): do not drop it.

The wallet views read the tables in the wallet's data scopes (see [Database](database.md#data-scopes-of-the-wallet)) with the rights of the owner role that owns the views. The views keep their names, columns and places, and the read-only users get no rights on the data scopes.
