# Upgrade

This page upgrades an installation to a new release of the platform.

[Back to the contents](../README.md#contents)

1. Set `global.imageTag` in `my-site.yaml` to the release tag of the new version (from iGrant.io). The chart and the images of one release belong together: a new chart with the images of an older release can stop the pods (for example, the wallet refuses a configuration key that it does not know). Then read the `values.yaml` of the new chart version and adapt your files where necessary.
2. Check the render with the new chart (`helm template`, as in install step 3).
3. Upgrade:

   ```bash
   helm upgrade ows ./helmcharts -n ows \
     -f ./ows-keys/values-keys.yaml -f my-site.yaml \
     -f my-database.yaml -f my-openbao.yaml -f my-exposure.yaml \
     --wait --timeout 15m
   ```

   Before the pods change, the hooks of the release run in this order:

   1. The roles hook of the wallet (`ows-wallet-database-roles`) creates the database roles of the wallet, sets their passwords and gives their grants, with the admin user of the database server.
   2. The migration hooks (`ows-api-migrate`, `ows-consent-migrate`, `ows-wallet-migrate`) update the database schemas. The wallet hook connects as the migrator role of the wallet.
   3. The read access hooks of the wallet (`ows-wallet-read-access-api`, `ows-wallet-read-access-consent`) update the read-only users with which the api and consent read the wallet database.

   When a hook fails, the upgrade stops and the old pods stay. Read the log of its Job, for example `kubectl -n ows logs job/ows-wallet-migrate`. After the upgrade, the hook `ows-consent-migrate-after` completes the data of consent: it needs `--wait`. The new wallet pods start their work only when the database schema is at the head of their release: they wait up to 600 seconds, then stop, and Kubernetes starts them again. See [Database](database.md#hooks-of-the-wallet).

   The exit code of the wallet migration hook (`migrate-database`):

   | Exit code | Meaning | Action |
   | --- | --- | --- |
   | 0 | The schema is at the head of the release, with all grants | None |
   | 1 | A revision failed | The log names the revision and the error. Correct the cause, or contact iGrant.io with the log, then run the upgrade again. |
   | 2 | A configuration or connection error | Check the database values and the database roles of the wallet (the roles hook ran before), then run the upgrade again. |
   | 3 | The grant step failed: the schema is at the head, but the grants are not complete | Run the upgrade again: the hook gives the missing grants. |

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
