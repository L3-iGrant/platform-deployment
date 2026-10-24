# Upgrade

This page upgrades an installation to a new release of the platform.

[Back to the contents](../README.md#contents)

1. Set `global.imageTag` in `my-site.yaml` to the release tag of the new version (from iGrant.io). The chart and the images of one release belong together: a new chart with the images of an older release can stop the pods (for example, the wallet refuses a configuration key that it does not know). Then read the `values.yaml` of the new chart version and adapt your files where necessary. MySQL: when the new release moves the tables of the wallet into data scopes, give the grant of [Data scopes of the wallet](#data-scopes-of-the-wallet-mysql) before step 3.
2. Check the render with the new chart (`helm template`, as in install step 3).
3. Upgrade:

   ```bash
   helm upgrade ows ./helmcharts -n ows \
     -f ./ows-keys/values-keys.yaml -f my-site.yaml \
     -f my-database.yaml -f my-openbao.yaml -f my-exposure.yaml \
     --wait --timeout 15m
   ```

   Before the pods change, the migration hooks (`ows-api-migrate`, `ows-consent-migrate`, `ows-wallet-migrate`) update the database schemas. When a hook fails, the upgrade stops and the old pods stay. After the upgrade, the hook `ows-consent-migrate-after` completes the data of consent: it needs `--wait`.

4. Bundled OpenBao: the OpenBao pods do not restart on their own (update strategy `OnDelete`), because a restarted pod stays sealed. Check whether the upgrade changed the OpenBao pods (for example a new release tag or a new OpenBao configuration):

   ```bash
   kubectl -n ows get statefulset ows-openbao -o go-template='{{or .status.updatedReplicas 0}}/{{.status.replicas}}{{"\n"}}'
   ```

   `3/3` means no change: go to the check below. Otherwise, restart and unseal the pods one at a time: first the two standby pods, then the active pod (`bao status` shows `HA Mode`: `standby` or `active`). For each pod:

   ```bash
   kubectl -n ows exec ows-openbao-2 -- bao status | grep 'HA Mode'   # standby: restart this pod first
   kubectl -n ows delete pod ows-openbao-2
   kubectl -n ows wait --for=jsonpath='{.status.phase}'=Running pod/ows-openbao-2 --timeout=5m
   kubectl -n ows exec -it ows-openbao-2 -- bao operator unseal   # 3 times, 3 different unseal keys
   ```

   Check: `kubectl -n ows exec ows-openbao-2 -- bao status` shows `Sealed false`. Continue with the next pod only when this check passes. After the third pod, the `updatedReplicas` command shows `3/3`.

5. Bundled OpenBao: run `bootstrap.sh` again (install step 5, item 3). It changes only what the new version needs, for example new Transit paths in the wallet policy. External OpenBao: compare your policy with [External OpenBao](openbao.md#external-openbao).

Check: `helm -n ows status ows` shows `STATUS: deployed`, and `kubectl -n ows get pods` shows all pods `Running` and `READY`.

## Data scopes of the wallet (MySQL)

The release that moves the tables of the wallet into data scopes (see [Database](database.md#data-scopes-of-the-wallet)) needs one more grant on MySQL. Give it before step 3. PostgreSQL needs nothing: the owner of the wallet database makes the schemas.

The new init Job gives this grant, but too late for an installation that exists: the migration hook `ows-wallet-migrate` is a `pre-upgrade` hook, and Helm applies the init Job, a normal object of the release, after the hooks. Without the grant, the wallet migration stops, the hook fails, the upgrade stops and the old pods stay. Then give the grant and run step 3 again.

The migration moves all tables of the wallet at once, with no compatibility views: the wallet pods of the release before fail from the start of the hook until the new wallet pods are ready. Do this upgrade in a maintenance window, on PostgreSQL too.

Bundled MariaDB (release `ows`, wallet database `igrant_wallet`):

```bash
kubectl -n ows exec -i ows-mysql-0 -c mysql -- \
  sh -c 'MYSQL_PWD="$MARIADB_ROOT_PASSWORD" exec mariadb --user=root' <<'SQL'
GRANT ALL PRIVILEGES ON `igrant\_wallet\_%`.* TO 'igrant_wallet'@'%';
SQL
```

External server: your DBA runs the same statement with the admin user. With another wallet database name, escape each `_` of the name. MySQL 8.0 with `partial_revokes=ON`: grant each data scope database by its name (see [Database](database.md#data-scopes-of-the-wallet)).

Check: `SHOW GRANTS FOR 'igrant_wallet'@'%'` shows the line with `` `igrant\_wallet\_%` ``.

A change of the hook weights cannot put the init Job before the migration: a weight sets only the order of the hooks, and the init Job is not a hook. The init Job cannot become a `pre-upgrade` hook either: a hook reads the Secrets of the release before (the password of a new component is not there yet), and the init Job must also run at a new installation, where Helm makes the bundled server only after the hooks. Only a separate `pre-upgrade` hook with this one grant, between the weights -10 and -5, could give it in time. The chart does not have one, because the grant is necessary only once for each installation that exists.
