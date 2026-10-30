# Install

This page installs the platform in seven steps. Each step ends with a check: continue only when the check passes.

[Back to the contents](../README.md#contents)

The examples use the release name `ows`, the namespace `ows` and a clone of this repository in `./helmcharts`.

## Step 1: the namespace and the registry access

```bash
kubectl create namespace ows
kubectl -n ows create secret docker-registry igrant-registry-creds \
  --docker-server=europe-docker.pkg.dev \
  --docker-username=_json_key \
  --docker-password="$(cat service-account-key.json)" \
  --docker-email=unused@example.org
```

Check: `kubectl -n ows get secret igrant-registry-creds` shows the Secret with the type `kubernetes.io/dockerconfigjson`.

Ask iGrant.io for the release tag of your version (for example `2026.10.1`). You set it as `global.imageTag` in step 3: the default `2026.10.x` is a placeholder, and no image has this tag. With your own mirror, also set `global.imageRegistry` and `global.imagePullSecrets`.

## Step 2: the keys

`scripts/make-keys.sh` creates all keys of the platform with the api image: the API keys, the gateway key, the keys that sign the NATS messages of each service, and one NATS user for each process. Run it on a trusted workstation that can pull the api image:

```bash
docker login -u _json_key --password-stdin https://europe-docker.pkg.dev < service-account-key.json
./helmcharts/scripts/make-keys.sh --release ows --namespace ows --tag <release tag> --out ./ows-keys
kubectl apply -n ows -f ./ows-keys/secrets.yaml
```

Check: `kubectl -n ows get secret -l app.kubernetes.io/instance=ows,app.kubernetes.io/component=keys -o name | wc -l` shows `14` (3 API keys, the gateway key, 3 service keys and 7 NATS users).

`./ows-keys/values-keys.yaml` has the public values of the keys (key ids, public keys and Secret names, no secrets): you give it to Helm in step 4. `./ows-keys/secrets.yaml` and `./ows-keys/files/` hold private keys: keep a copy in your password safe, then delete the folder. See [Keys](keys.md).

## Step 3: the values of your installation

Copy `examples/site.yaml` to `my-site.yaml` and set the release tag (`global.imageTag`) and your host names. Then choose one file from each group of `examples/`:

| Group | Files | Read first |
| --- | --- | --- |
| Database | `postgresql-bundled.yaml`, `postgresql-external.yaml` | [Database](database.md) |
| OpenBao | `openbao-shamir.yaml` (the bundled OpenBao, manual unseal), `openbao-external.yaml` (your OpenBao) | [OpenBao](openbao.md) |
| Exposure | `exposure-ingress-nginx.yaml`, `exposure-ingress-nginx-cert-manager.yaml`, `exposure-envoy-gateway.yaml`, `exposure-kgateway.yaml`, `exposure-none.yaml` | [Exposure](exposure.md) |
| Redis (optional) | `redis-external.yaml` (your Valkey or Redis). Without it, the chart runs Valkey with Sentinel | [Redis](redis.md) |
| Network policies (optional) | `networkpolicy.yaml` | [Network policies](network-policies.md) |

Copy the files that you use (for example to `my-database.yaml`, `my-openbao.yaml` and `my-exposure.yaml`) and adapt their values (for example the Gateway name or the TLS Secret names). Each file names the Secrets to create before the install, for example the database admin password. Create these Secrets now. For an HSM or a larger installation, see [Connect your on-premise HSM](on-premise-hsm.md) and [Scaled deployments](scaled-deployments.md).

Check: the render has no error:

```bash
helm template ows ./helmcharts -n ows \
  -f ./ows-keys/values-keys.yaml -f my-site.yaml \
  -f my-database.yaml -f my-openbao.yaml -f my-exposure.yaml > /tmp/ows.yaml
```

The command writes the manifests to `/tmp/ows.yaml` and shows no error. A wrong or missing value stops it with a message that names the value (for example `api.host is required`).

When you use optional files, add them to this command and to every `helm install` and `helm upgrade` command of this documentation (for example `-f my-networkpolicy.yaml`).

## Step 4: install

```bash
helm install ows ./helmcharts -n ows \
  -f ./ows-keys/values-keys.yaml -f my-site.yaml \
  -f my-database.yaml -f my-openbao.yaml -f my-exposure.yaml \
  --timeout 15m
```

Do not add `--wait`: the OpenBao pods become ready only after step 5.

After Helm creates the resources, the command waits for the hooks of the databases (Helm `post-install`): the init hook waits until the database server is ready and creates the databases and the users, the roles hook creates the database roles of the wallet, the migration hook creates the schema of the wallet database, and the read access hooks of the wallet create the read-only users with which the api and consent read the wallet database (see [Database](database.md#hooks-of-the-databases)). This can take some minutes; `--timeout 15m` gives each hook enough time.

Check: `helm -n ows status ows` shows `STATUS: deployed`, and the output of the install shows the next steps.

When a hook fails, the install stops. Read the log of its Job (for example `kubectl -n ows logs job/ows-db-init` or `job/ows-wallet-database-roles`) and correct the cause, for example the admin user of an external database server. Then uninstall (Helm keeps the data, see [Uninstall](uninstall.md)) and do this step again.

## Step 5: initialise OpenBao (bundled OpenBao only)

With an external OpenBao (`openbao-external.yaml`), go to step 6.

1. Initialise OpenBao once. The keys and the root token appear only in your terminal: keep them outside the cluster, for example in a password safe, with the keys held by different persons.

   ```bash
   kubectl -n ows exec -it ows-openbao-0 -- bao operator init -key-shares=5 -key-threshold=3
   ```

2. Unseal each pod (`ows-openbao-0`, `ows-openbao-1`, `ows-openbao-2`) with 3 different unseal keys (the command asks for one key at a time). Do this again after each restart of a pod.

   ```bash
   kubectl -n ows exec -it ows-openbao-0 -- bao operator unseal
   ```

3. Run the bootstrap of the key store of the wallet. It asks for the root token (the input is hidden) and does not keep it:

   ```bash
   kubectl -n ows exec -it ows-openbao-0 -- /openbao/scripts/bootstrap.sh
   ```

Check: `kubectl -n ows exec ows-openbao-0 -- bao status` shows `Initialized true` and `Sealed false`, and the bootstrap ends with `bootstrap: done. The wallet logs in as wallet and uses transit/.`

## Step 6: wait for the platform

```bash
kubectl -n ows get pods,jobs
```

Check: after some minutes, all pods are `Running` and `READY` (the Valkey pods `ows-redis-0`, `ows-redis-1` and `ows-redis-2` show `2/2`), and the Jobs `ows-db-init`, `ows-api-read-access-*`, `ows-consent-read-access-*`, `ows-wallet-database-roles`, `ows-wallet-migrate` and `ows-wallet-read-access-*` are `Complete`.

Some restarts are usual at the first start (`RESTARTS` 3 to 5). The Jobs try again while the database starts, the wallet pods wait until the migration hook has created the schema of the wallet database, and a service that reads the views of another service (the API, consent and the wallet config role) is ready only when its read-only database user exists. Until then, a process stops when the database, its read-only user or the OpenBao login of the wallet (step 5) is not ready yet, and its log shows the reason. When a pod still restarts after 10 minutes, read its log (`kubectl -n ows logs <pod> --previous`).

Then check the public hosts through your ingress controller or Gateway:

```bash
curl -s -o /dev/null -w '%{http_code}\n' https://api.example.org/healthz      # 200
curl -s -o /dev/null -w '%{http_code}\n' https://dashboard.example.org/       # 200
```

## Step 7: the first admin and the organisation

The dashboard does not accept an admin without an organisation. Three Jobs of the chart create the organisation type, the first admin and the organisation of this admin.

1. Create a Secret with the password of the first admin:

   ```bash
   kubectl -n ows create secret generic ows-first-admin --from-file=password=./admin-password.txt
   ```

2. Write these values to a file `first-admin.yaml` and run `helm upgrade` with all files of step 4 and this file:

   ```yaml
   api:
     jobs:
       createOrganisationType:
         enabled: true
         type: Technology
       registerAdmin:
         enabled: true
         email: admin@example.org
         name: First Admin
         phone: "+4612345678"
         passwordSecret: ows-first-admin
       createOrganisation:
         enabled: true
         name: Example Organisation
         location: Stockholm
         policyUrl: https://example.org/privacy
         description: The organisation of the first admin.
   ```

   ```bash
   helm upgrade ows ./helmcharts -n ows \
     -f ./ows-keys/values-keys.yaml -f my-site.yaml \
     -f my-database.yaml -f my-openbao.yaml -f my-exposure.yaml -f first-admin.yaml
   ```

   The Jobs run at the same time. `ows-api-create-organisation-<revision>` tries again until the admin and the organisation type exist.

3. Check: `kubectl -n ows get jobs` shows `ows-api-register-admin-<revision>`, `ows-api-create-organisation-type-<revision>` and `ows-api-create-organisation-<revision>` as `Complete`. Then log in to `https://dashboard.example.org` with the e-mail address and the password. You see the "Getting started" page of the organisation.

4. Run `helm upgrade` again without `first-admin.yaml`: this turns the three Jobs off. Then delete the password file and the Secret. The admin exists, and only the Job of item 2 reads the Secret.

   ```bash
   kubectl -n ows delete secret ows-first-admin
   ```

An admin without an organisation sees the message "Your account has no organisation" at the login. To create the organisation of such an admin, use the Job `createOrganisation` with `adminEmail` set to the e-mail address of the admin.
