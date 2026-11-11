# Install

This page installs the platform in seven steps. Each step ends with a check: continue only when the check passes.

[Back to the contents](../README.md#contents)

The examples use the release name `ows`, the namespace `ows` and a clone of this repository in `./platform-deployment`.

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
./platform-deployment/scripts/make-keys.sh --release ows --namespace ows --tag <release tag> --out ./ows-keys
kubectl apply -n ows -f ./ows-keys/secrets.yaml
```

Check: `kubectl -n ows get secret -l app.kubernetes.io/instance=ows,app.kubernetes.io/component=keys -o name | wc -l` shows `13` (3 API keys, the gateway key, 3 service keys and 6 NATS users).

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
helm template ows ./platform-deployment -n ows \
  -f ./ows-keys/values-keys.yaml -f my-site.yaml \
  -f my-database.yaml -f my-openbao.yaml -f my-exposure.yaml > /tmp/ows.yaml
```

The command writes the manifests to `/tmp/ows.yaml` and shows no error. A wrong or missing value stops it with a message that names the value (for example `api.host is required`).

When you use optional files, add them to this command and to every `helm install` and `helm upgrade` command of this documentation (for example `-f my-networkpolicy.yaml`).

## Step 4: install

```bash
helm install ows ./platform-deployment -n ows \
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

Then check the hosts through your ingress controller or Gateway (an internal host from your internal network):

```bash
curl -s -o /dev/null -w '%{http_code}\n' https://api.example.org/healthz      # 200
curl -s -o /dev/null -w '%{http_code}\n' https://dashboard.example.org/       # 200
```

## Step 7: the platform operator organisation and the first platform admin

An installation has one platform operator organisation. The platform admins of this organisation add, suspend and delete the other organisations of the installation in the dashboard. Only the command line makes the platform operator organisation and gives the first platform admin right: no route of the API does this.

The Job `bootstrapPlatform` of the chart runs `igrant-api onboard bootstrap-platform`. In one command, it makes the organisation type (when no type has the name), the first admin, the organisation with the platform operator mark, the role Super Admin of the admin in it, and the platform admin right of the admin.

1. Create a Secret with the first password of the admin. The password of a platform admin must have 15 characters or more (at most 256) and at least one special character, for example `!`, `#` or `%`. A space is not a special character. It must not be a known password, and it must not have a part of the e-mail address, the name or the organisation name. The chart cannot check a password in a Secret: the Job fails when the API refuses the password, and its log names the rules that failed, never the password.

   ```bash
   kubectl -n ows create secret generic ows-platform-admin --from-file=password=./admin-password.txt
   ```

2. Write these values to a file `platform-operator.yaml` and run `helm upgrade` with all files of step 4 and this file:

   ```yaml
   api:
     jobs:
       bootstrapPlatform:
         enabled: true
         adminEmail: admin@example.org
         adminName: First Admin
         passwordSecret: ows-platform-admin
         organisationName: Example Wallet Provider
         type: Technology
         location: Stockholm
         policyUrl: https://example.org/privacy
   ```

   ```bash
   helm upgrade ows ./platform-deployment -n ows \
     -f ./ows-keys/values-keys.yaml -f my-site.yaml \
     -f my-database.yaml -f my-openbao.yaml -f my-exposure.yaml -f platform-operator.yaml
   ```

3. Check: `kubectl -n ows get jobs` shows `ows-api-bootstrap-platform-<revision>` as `Complete`, and its log has one JSON line with `organisationId`, `adminId` and `"created":true`:

   ```bash
   kubectl -n ows logs job/ows-api-bootstrap-platform-<revision> -c command
   ```

   When the Job is `Failed`, read this log, correct the cause (for example the password) and run the `helm upgrade` of item 2 again. A second run with the same values changes nothing and shows `"created":false`.

   The command `platform status` shows the platform operator organisation and its platform admins. It reads only, and it prints no secret:

   ```bash
   kubectl -n ows exec deploy/ows-api -c api -- /app/bin/igrant-api platform status --config=/etc/igrant-api/config.yaml
   ```

   The output has one JSON line with `operatorOrganisationId` (the id of your organisation) and one entry in `platformAdmins`.

4. Log in to `https://dashboard.example.org` with the e-mail address and the password. The account must change the password at the first login: the dashboard opens the page for the new password (15 characters or more, with at least one special character). This step needs no e-mail service. After the login you see the "Getting started" page of the organisation. The dashboard shows the functions of a platform admin in the group "Wallet Provider (Orgs)".

5. Run `helm upgrade` again without `platform-operator.yaml`: this turns the Job off. Then delete the password file and the Secret. The admin exists, and only the Job of item 2 reads the Secret.

   ```bash
   kubectl -n ows delete secret ows-platform-admin
   ```

Rules of the Job:

- Use it only for a new installation. For an installation that has organisations, see [Upgrade](upgrade.md#the-platform-operator): with an e-mail address that no admin has, the Job makes a new organisation with the platform operator mark, and then no organisation that exists can get the mark. When an admin with the e-mail address has a different organisation, or the installation has a platform operator organisation of which the admin is not an admin, the Job fails and changes nothing.
- It is safe to run again: when the admin is a platform admin of the platform operator organisation, the command changes nothing. The password of an account that exists does not change. But turn the Job off after the run: it fails at a later `helm upgrade` when the admin is no longer an admin of the organisation.
- There is no transfer and no removal of the platform operator mark.
- The wallet of the platform operator organisation is the wallet provider of the installation: the wallet gets this flag when an admin deploys it, and no route changes the flag later.

## After the installation: the other organisations and admins

A platform admin does these tasks in the dashboard, in the group "Wallet Provider (Orgs)". No Job and no command of the chart is necessary.

| Task | Where | What an operator of the installation must know |
| --- | --- | --- |
| Add an organisation with its first admin | Page "Wallet Units", the + button | The first admin gets an invitation by e-mail or a one-time password. An invitation needs the e-mail service (`api.smtp.host`): without it, use the one-time password. The API deploys the wallet of the new organisation. |
| Set the features of an organisation | Row menu, "Manage Features" | The panel has four switches: Issuer & Verifier, Wallet Unit (Holder), Consent Management and Data Marketplace. A new organisation has only Issuer & Verifier on: turn each other area on for the organisation that needs it. The platform operator organisation has the four on. Getting Started, Account, Webhooks and Activity Logs have no switch and are always available. The gateway refuses the routes of a feature that is off for the organisation (`gateway.features.enforce`, see [Values reference](values-reference.md#api-and-gateway)), and a change applies within one minute. See [Upgrade](upgrade.md#the-four-feature-switches). |
| Suspend and resume an organisation | Row menu | The gateway refuses each credential of a suspended organisation within 60 seconds. When the wallet did not get the state, the page shows a warning: send the request again. |
| Delete a suspended organisation | Row menu, "Delete Organisation" | The deletion cannot be undone. The API deletes its data of the organisation in steps, consent purges its data, and the wallet deactivates the wallets of the organisation and purges them after its retention period. No background job repeats a failed step of the API: when the page shows failed steps, use "Run Deletion Again" until none is left. Each failed step is one `ERROR` line in the log of the api pods. |
| Give and remove the platform admin right | Page "Platform Admins" | Only an admin of the platform operator organisation can get the right. A platform admin with a password of less than 15 characters sets a new password at the next login. |

Each other new password (an invitation, a one-time password change, a reset) must have 12 characters or more and at least one special character.

When no platform admin can log in (for example the only platform admin left), give the right to an admin of the platform operator organisation with the command line:

```bash
kubectl -n ows exec deploy/ows-api -c api -- /app/bin/igrant-api platform grant-admin --email admin2@example.org --config=/etc/igrant-api/config.yaml
```

## The Jobs of the earlier releases

The Jobs `api.jobs.registerAdmin`, `api.jobs.createOrganisationType` and `api.jobs.createOrganisation` stay in the chart, with the same values, for the values files that use them. They make an admin and an organisation without the platform operator mark and without the platform admin right: the functions of a platform admin stay hidden in the dashboard. Do not use them for the first organisation of a new installation. The render stops when `bootstrapPlatform` is enabled together with `registerAdmin` or `createOrganisation`.

An installation that got its first organisation from these Jobs makes that organisation the platform operator with the Job `api.jobs.platformOperator`: see [Upgrade](upgrade.md#the-platform-operator).
