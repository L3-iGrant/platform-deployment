# Tests

This page describes the tests of the chart. They run without a cluster.

[Back to the contents](../README.md#contents)

`tests/render-matrix.sh` checks the chart without a cluster:

- the text of the chart files and of the documentation (no em dash, British English, no name of other key store products), and the relative links of `README.md` and `docs/` (`tests/check_links.py`: each target file and each heading of an anchor exists);
- every combination of the examples (2 database files, 2 OpenBao files, 5 exposure files, with and without network policies): `helm template`, `kubeconform -strict` when it is installed, and `tests/check_render.py` (the engine, host, port and TLS of each configuration file, the server and the Jobs of the engine, the exposure objects, the OpenBao seal, the database port of the network policies, the parameters of the bundled server (each name once, and the DDL and connection logs), the init script (psql `\password`, no password in a statement), the kinds and weights of the hooks of the databases (the Secrets, the init hook, the roles hook, the migration hooks and the read access hooks), the migration of the api and consent when their pods start, and the database roles of the wallet: the user and the Secret key of each wallet process, and no password of the database owner user in a wallet pod or Job; the retention of the audit log and the retention purge in each wallet file and the migration hook, and no audit bucket by default), and `tests/check_hook_order.py install` (see below), and one more render of the bundled server with the DDL and connection logs off;
- the render guards (wrong values stop the render with a clear message, for example `database.engine: mysql`);
- install and upgrade: `tests/check_hook_order.py` replays the steps of Helm on the renders, without a cluster: the hooks in the order of their weights, the resources of the release, and on an upgrade the objects of the earlier release and the delete of the resources that the new release does not have (except the objects with `helm.sh/resource-policy: keep`). When each hook Job starts, the Secrets, ConfigMaps, databases and users that it needs must exist. The cases: each render of the matrix as an install; on both database files, an upgrade with the same values, upgrades that turn the organisation wallet, consent or the api on, and the first upgrade from a release in which the database Secret, the read access Secret and the init Job were resources. A copy of the chart reads earlier Secrets from a file in place of `lookup`: the Secrets that are hooks keep the values of the earlier Secrets;
- the audit log of the wallet: the bucket only in the configuration and the pods of the scheduler, with its service account or the Google default credentials, the retention in each wallet file and the migration hook, and the guards of the audit values.

```bash
tests/render-matrix.sh            # or: tests/render-matrix.sh --keep /tmp/renders
```

`tests/compose-files.sh` checks the files of `docker-compose/` without a container: `docker compose config` for the engine, the configuration files of the components, the DDL and connection logs of the database server, the passwords of `database-init` (psql `\password`), the scripts, the NATS configuration, the same text rules and the relative links of its README.
