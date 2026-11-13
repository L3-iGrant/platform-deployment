# Uninstall

How to remove the platform from the cluster, what stays, and how to install again with or without the data.

[Back to the contents](../README.md#contents)

```bash
helm uninstall ows -n ows
```

Helm keeps the platform data and the objects that belong to it:

| What stays | Why |
| --- | --- |
| The volumes (PersistentVolumeClaims) of the database server, NATS, OpenBao and Valkey, and the Secrets that the chart created for them (the database user passwords, the wallet's OpenBao login, the Valkey user passwords, and the TLS certificates of the database server, OpenBao and Valkey) | They hold the platform data (`helm.sh/resource-policy: keep`). |
| The Jobs and ConfigMaps of the hooks, and the Secret `<release>-wallet-database-roles` (the passwords of the wallet's database roles) | Helm does not delete hooks. |
| Your Secrets: registry access ([install step 1](install.md#step-1-the-namespace-and-the-registry-access)), keys ([install step 2](install.md#step-2-the-keys)) and the Secrets of [install step 3](install.md#step-3-the-values-of-your-installation) | You created them. Before you do [install step 7](install.md#step-7-the-platform-operator-organisation-and-the-first-platform-admin) again, delete a remaining `ows-platform-admin` Secret (or `ows-first-admin` of an earlier release): `kubectl create secret` refuses an existing Secret. |

Check: `helm -n ows list` does not show `ows`, and `kubectl -n ows get pods` shows no platform pods (finished Jobs stay for one day).

**Install again with the same data:** run [install step 4](install.md#step-4-install) with the same values files. The chart uses the kept Secrets and volumes. With the bundled OpenBao, unseal again (install step 5, item 2).

**Start again without data**: delete the kept objects of the release. This deletes all platform data: organisations, credentials and the wallet keys in OpenBao.

```bash
kubectl -n ows delete pvc,job,configmap,secret -l app.kubernetes.io/instance=ows,app.kubernetes.io/component!=keys
```

The key Secrets of install step 2 stay, so you can use them again. To create new keys in install step 2, delete them first:

```bash
kubectl -n ows delete secret -l app.kubernetes.io/instance=ows,app.kubernetes.io/component=keys
```

Check: `kubectl -n ows get pvc,job,configmap -l app.kubernetes.io/instance=ows` shows `No resources found`. Then install again from install step 3 (from install step 2 if you created new keys).

With an external database server (`database.mode: external`), these commands do not change your server. The databases `igrant_api`, `igrant_oidc`, `igrant_consent` and `igrant_wallet`, their owner users, the wallet's database roles (`igrant_wallet_*`) and the read-only users stay. For a start without data, your DBA drops them before the new install. Otherwise, the new installation uses the old databases.
