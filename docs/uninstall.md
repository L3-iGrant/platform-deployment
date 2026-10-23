# Uninstall

This page removes the platform from the cluster. It also explains what stays, and how to install again with or without the data.

[Back to the contents](../README.md#contents)

```bash
helm uninstall ows -n ows
```

Helm keeps the data of the platform and the objects that belong to it:

| What stays | Why |
| --- | --- |
| The volumes (PersistentVolumeClaims) of the database server, NATS and OpenBao, and the Secrets that the chart created for them (the passwords of the database users, the OpenBao login of the wallet, the TLS certificates of the database server and OpenBao) | They hold the data of the platform (`helm.sh/resource-policy: keep`). |
| The Jobs and ConfigMaps of the migration hooks | Helm does not delete hooks. |
| Your Secrets: registry access ([install step 1](install.md#step-1-the-namespace-and-the-registry-access)), keys ([install step 2](install.md#step-2-the-keys)) and the Secrets of [install step 3](install.md#step-3-the-values-of-your-installation) | You created them. Delete a remaining `ows-first-admin` Secret before you do [install step 7](install.md#step-7-the-first-admin-and-the-organisation) again (`kubectl create secret` refuses an existing Secret). |

Check: `helm -n ows list` does not show `ows`, and `kubectl -n ows get pods` shows no pod of the platform (finished Jobs stay for one day).

**Install again with the same data:** run [install step 4](install.md#step-4-install) with the same values files (the same database engine). The chart uses the kept Secrets and volumes. With the bundled OpenBao, unseal again (install step 5, item 2).

**Start again without data** (for example with another database engine): delete the kept objects of the release. This deletes all data of the platform: organisations, credentials and the keys of the wallet in OpenBao.

```bash
kubectl -n ows delete pvc,job,configmap,secret -l app.kubernetes.io/instance=ows,app.kubernetes.io/component!=keys
```

The key Secrets of install step 2 stay, so you can use them again. To create new keys in install step 2, delete them first:

```bash
kubectl -n ows delete secret -l app.kubernetes.io/instance=ows,app.kubernetes.io/component=keys
```

Check: `kubectl -n ows get pvc,job,configmap -l app.kubernetes.io/instance=ows` shows `No resources found`. Then install again from install step 3 (from install step 2 when you created new keys).

With an external database server (`database.mode: external`), these commands do not change your server: the databases `igrant_api`, `igrant_oidc`, `igrant_consent` and `igrant_wallet`, their owner users and the read-only users stay. For a start without data, your DBA drops them before the new install. Otherwise, the new installation uses the old databases.
