# Install

Install the platform in seven steps. Each step ends with a check: go on only when the check passes.

[Back to the contents](../README.md#contents)

The examples use the release name `ows`, the namespace `ows` and a clone of this repository in `./platform-deployment`.

## Step 1: the namespace and the registry access

The iGrant.io images are in `europe-docker.pkg.dev/jenkins-189019/igrant-customers`, the default of `global.imageRegistry`. Ask support@igrant.io for read access and for the release tag of your version (for example `2026.10.1`). You get a service account key file, `service-account-key.json`.

On your workstation, check the access and let Docker pull the api image for step 2. Use one of the two ways.

With the Google Cloud CLI:

```bash
gcloud auth activate-service-account --key-file=service-account-key.json
gcloud auth configure-docker europe-docker.pkg.dev
gcloud artifacts docker tags list europe-docker.pkg.dev/jenkins-189019/igrant-customers/api
```

The last command lists the release tags of the api image: your tag must be in the list. `gcloud auth activate-service-account` makes the key the active gcloud account; switch back later with `gcloud config set account <your account>`.

Without the Google Cloud CLI, with Docker only:

```bash
docker login -u _json_key --password-stdin https://europe-docker.pkg.dev < service-account-key.json
docker pull europe-docker.pkg.dev/jenkins-189019/igrant-customers/api:<release tag>
```

In both cases, the cluster pulls with an image pull Secret that you create from the same key file. The chart gives it to every pod, also to the Jobs and hooks: `global.imagePullSecrets` (default `[igrant-registry-creds]`). If you give the Secret another name, set `global.imagePullSecrets` in `my-site.yaml` in step 3.

```bash
kubectl create namespace ows
kubectl -n ows create secret docker-registry igrant-registry-creds \
  --docker-server=europe-docker.pkg.dev \
  --docker-username=_json_key \
  --docker-password="$(cat service-account-key.json)" \
  --docker-email=unused@example.org
```

Check: `kubectl -n ows get secret igrant-registry-creds` shows the Secret with the type `kubernetes.io/dockerconfigjson`.

You set the release tag as `global.imageTag` in step 3; the render stops without it. If you use your own mirror, also set `global.imageRegistry` and `global.imagePullSecrets`.

## Step 2: the keys

`scripts/make-keys.sh` uses the api image to create every key of the platform: the API keys, the gateway key, the keys that sign each service's NATS messages, and one NATS user per process. Run it on a trusted workstation that can pull the api image (step 1):

```bash
./platform-deployment/scripts/make-keys.sh --release ows --namespace ows --tag <release tag> --out ./ows-keys
kubectl apply -n ows -f ./ows-keys/secrets.yaml
```

Check: `kubectl -n ows get secret -l app.kubernetes.io/instance=ows,app.kubernetes.io/component=keys -o name | wc -l` shows `13` (3 API keys, the gateway key, 3 service keys and 6 NATS users).

`./ows-keys/values-keys.yaml` holds only public values (key ids, public keys and Secret names). You pass it to Helm in step 4. `./ows-keys/secrets.yaml` and `./ows-keys/files/` hold private keys: keep a copy in your password safe, then delete the folder. See [Keys](keys.md).

## Step 3: the values of your installation

Copy `./platform-deployment/profiles/site.yaml` to `my-site.yaml`. Set `global.imageTag` to your release tag, and set your three host names.

Then pick the profiles in `./platform-deployment/profiles/` that fit your cluster. If you leave a profile out, the chart default applies.

| Profile | Use it for | Read first |
| --- | --- | --- |
| `exposure-ingress-nginx.yaml`, `exposure-ingress-nginx-cert-manager.yaml`, `exposure-envoy-gateway.yaml`, `exposure-kgateway.yaml`, `exposure-on-premise.yaml`, `exposure-none.yaml` | How traffic reaches the hosts (one is required) | [Exposure](exposure.md) |
| `database-external.yaml` | Your own PostgreSQL server. Without it, the chart runs one PostgreSQL 18 server. | [Database](database.md) |
| `openbao-external.yaml` | Your own OpenBao. Without it, the chart runs OpenBao with the Shamir seal (manual unseal). | [OpenBao](openbao.md) |
| `redis-external.yaml` | Your own Valkey or Redis. Without it, the chart runs Valkey with Sentinel. | [Redis](redis.md) |
| `network-policies.yaml` | NetworkPolicies for every pod | [Network policies](network-policies.md) |
| `minimal.yaml` | A test or development installation: one replica of each service | [Components](components.md) |

By default, an installation has consent management and the organisation wallet. To leave one out, set `consent.enabled: false` or `organisationWallet.enabled: false` in `my-site.yaml` (see [Components](components.md#the-services-of-the-installation)). Without the wallet, the chart runs no OpenBao: the OpenBao profiles have no effect, and you skip step 5.

To change a profile, copy it first (for example to `my-exposure.yaml` for other TLS Secret names or another Gateway). Each profile names the Secrets that you must create before the install, for example the database admin password. Create them now. For an HSM or a larger installation, see [Connect your on-premise HSM](on-premise-hsm.md) and [Scaled deployments](scaled-deployments.md).

Check: the render has no error:

```bash
helm template ows ./platform-deployment -n ows \
  -f ./ows-keys/values-keys.yaml -f my-site.yaml \
  -f ./platform-deployment/profiles/exposure-ingress-nginx.yaml > /tmp/ows.yaml
```

The command writes the manifests to `/tmp/ows.yaml`. A wrong or missing value stops it with a message that names the value (for example `global.imageTag is required: the release tag of your version`).

Add every other profile that you use to this command, and to every `helm install` and `helm upgrade` command in these docs (for example `-f ./platform-deployment/profiles/network-policies.yaml`).

## Step 4: install

```bash
helm install ows ./platform-deployment -n ows \
  -f ./ows-keys/values-keys.yaml -f my-site.yaml \
  -f ./platform-deployment/profiles/exposure-ingress-nginx.yaml \
  --timeout 15m
```

Do not add `--wait`: the OpenBao pods become ready only after step 5.

When Helm has created the resources, the command waits for the database hooks (Helm `post-install`):

- the init hook waits for the database server, then creates the databases and the users;
- the roles hook creates the wallet's database roles;
- the migration hook creates the schema of the wallet database;
- the wallet's read access hooks create the read-only users that the api and consent use to read the wallet database.

See [Database](database.md#hooks-of-the-databases). This can take a few minutes; `--timeout 15m` gives each hook enough time.

Check: `helm -n ows status ows` shows `STATUS: deployed`, and the install output shows the next steps.

If a hook fails, the install stops. Read the log of its Job (for example `kubectl -n ows logs job/ows-db-init` or `job/ows-wallet-database-roles`) and fix the cause, for example the admin user of an external database server. Then uninstall (Helm keeps the data, see [Uninstall](uninstall.md)) and do this step again.

## Step 5: initialise OpenBao (bundled OpenBao only)

With an external OpenBao (`openbao-external.yaml`), or without the organisation wallet, go to step 6.

1. Initialise OpenBao once. The unseal keys and the root token appear only in your terminal. Keep them outside the cluster, for example in a password safe, and give the keys to different people.

   ```bash
   kubectl -n ows exec -it ows-openbao-0 -- bao operator init -key-shares=5 -key-threshold=3
   ```

2. Unseal each pod (`ows-openbao-0`, `ows-openbao-1`, `ows-openbao-2`) with 3 different unseal keys. The command asks for one key at a time. Do this again after every restart of a pod.

   ```bash
   kubectl -n ows exec -it ows-openbao-0 -- bao operator unseal
   ```

3. Run the bootstrap of the wallet's key store. It asks for the root token (the input is hidden) and does not keep it:

   ```bash
   kubectl -n ows exec -it ows-openbao-0 -- /openbao/scripts/bootstrap.sh
   ```

Check: `kubectl -n ows exec ows-openbao-0 -- bao status` shows `Initialized true` and `Sealed false`, and the bootstrap ends with `bootstrap: done. The wallet logs in as wallet and uses transit/.`

## Step 6: wait for the platform

```bash
kubectl -n ows get pods,jobs
```

Check: after a few minutes, all pods are `Running` and `READY` (the Valkey pods `ows-redis-0`, `ows-redis-1` and `ows-redis-2` show `2/2`), and the Jobs `ows-db-init`, `ows-api-read-access-*`, `ows-consent-read-access-*`, `ows-wallet-database-roles`, `ows-wallet-migrate` and `ows-wallet-read-access-*` are `Complete`.

A few restarts at the first start are normal (`RESTARTS` 3 to 5):

- The Jobs retry while the database starts.
- The wallet pods wait until the migration hook has created the schema of the wallet database.
- A service that reads another service's views (the API, consent and the wallet config role) becomes ready only when its read-only database user exists.

Until then, a process exits when the database, its read-only user or the wallet's OpenBao login (step 5) is not ready yet, and its log says why. If a pod still restarts after 10 minutes, read its log (`kubectl -n ows logs <pod> --previous`).

Then check the hosts through your ingress controller or Gateway (check an internal host from your internal network):

```bash
curl -s -o /dev/null -w '%{http_code}\n' https://api.example.org/healthz      # 200
curl -s -o /dev/null -w '%{http_code}\n' https://dashboard.example.org/       # 200
```

## Step 7: the platform operator organisation and the first platform admin

An installation has one platform operator organisation. Its platform admins add, suspend and delete the other organisations in the dashboard. Only the command line can create the platform operator organisation and give the first platform admin right: no API route does this.

The chart's `bootstrapPlatform` Job runs `igrant-api onboard bootstrap-platform`. In one command, it creates:

- the organisation type (if no type has that name);
- the first admin;
- the organisation, with the platform operator mark;
- the admin's Super Admin role in the organisation;
- the admin's platform admin right.

1. Create a Secret with the admin's first password. The password of a platform admin must:

   - have 15 to 256 characters;
   - have at least one special character, for example `!`, `#` or `%` (a space does not count);
   - not be a known password;
   - not contain a part of the e-mail address, the name or the organisation name.

   The chart cannot check a password in a Secret. If the API refuses the password, the Job fails, and its log names the rules that failed (never the password).

   ```bash
   kubectl -n ows create secret generic ows-platform-admin --from-file=password=./admin-password.txt
   ```

2. Write these values to a file `platform-operator.yaml`, and run `helm upgrade` with all the files of step 4 plus this file:

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
     -f ./platform-deployment/profiles/exposure-ingress-nginx.yaml -f platform-operator.yaml
   ```

3. Check: `kubectl -n ows get jobs` shows `ows-api-bootstrap-platform-<revision>` as `Complete`, and its log has one JSON line with `organisationId`, `adminId` and `"created":true`:

   ```bash
   kubectl -n ows logs job/ows-api-bootstrap-platform-<revision> -c command
   ```

   If the Job is `Failed`, read this log, fix the cause (for example the password) and run the `helm upgrade` of item 2 again. A second run with the same values changes nothing and shows `"created":false`.

   `platform status` shows the platform operator organisation and its platform admins. It only reads, and it prints no secret:

   ```bash
   kubectl -n ows exec deploy/ows-api -c api -- /app/bin/igrant-api platform status --config=/etc/igrant-api/config.yaml
   ```

   The output is one JSON line with `operatorOrganisationId` (the id of your organisation) and one entry in `platformAdmins`.

4. Log in to `https://dashboard.example.org` with the e-mail address and the password. You must change the password at the first login: the dashboard opens the page for the new password (15 characters or more, with at least one special character). This step needs no e-mail service. After the login, you see the organisation's "Getting started" page. The platform admin functions are in the dashboard group "Wallet Provider (Orgs)".

5. Run `helm upgrade` again without `platform-operator.yaml` to turn the Job off. Then delete the password file and the Secret: the admin exists now, and only the Job of item 2 reads the Secret.

   ```bash
   kubectl -n ows delete secret ows-platform-admin
   ```

Rules of the Job:

- Use it only for a new installation. With an e-mail address that no admin has, the Job creates a new organisation with the platform operator mark, and after that no existing organisation can get the mark. The Job fails and changes nothing when an admin with that e-mail address belongs to another organisation, or when a platform operator organisation exists and the admin is not one of its admins.
- It is safe to run again: when the admin is already a platform admin of the platform operator organisation, the command changes nothing, and an existing account keeps its password. Still, turn the Job off after the run: a later `helm upgrade` fails when the admin is no longer an admin of the organisation.
- You cannot transfer or remove the platform operator mark.
- The wallet of the platform operator organisation is the installation's wallet provider. The wallet gets this flag when an admin deploys it, and no route changes the flag later.

## After the installation: the other organisations and admins

A platform admin does these tasks in the dashboard, in the group "Wallet Provider (Orgs)". You need no Job and no chart command.

| Task | Where | What an operator of the installation must know |
| --- | --- | --- |
| Add an organisation with its first admin | Page "Wallet Units", the + button | The first admin gets an e-mail invitation or a one-time password. An invitation needs the e-mail service (`api.smtp.host`); without it, use the one-time password. The API deploys the new organisation's wallet. |
| Set the features of an organisation | Row menu, "Manage Features" | Four switches: Issuer & Verifier, Wallet Unit (Holder), Consent Management and Data Marketplace. A new organisation has only Issuer & Verifier on: turn on each other area that the organisation needs. The platform operator organisation has all four on. Getting Started, Account, Webhooks and Activity Logs have no switch and are always available. The gateway refuses the routes of a feature that is off for the organisation (`gateway.features.enforce`, see [Values reference](values-reference.md#api-and-gateway)). A change applies within one minute. |
| Suspend and resume an organisation | Row menu | The gateway refuses every credential of a suspended organisation within 60 seconds. If the wallet did not get the new state, the page shows a warning: send the request again. |
| Delete a suspended organisation | Row menu, "Delete Organisation" | You cannot undo a deletion. The API deletes its data of the organisation in steps, consent purges its data, and the wallet deactivates the organisation's wallets and purges them after its retention period. No background job retries a failed API step: if the page shows failed steps, use "Run Deletion Again" until none is left. Each failed step is one `ERROR` line in the log of the api pods. |
| Give and remove the platform admin right | Page "Platform Admins" | Only an admin of the platform operator organisation can get the right. A platform admin whose password has fewer than 15 characters must set a new password at the next login. |

Every other new password (an invitation, a one-time password change, a reset) needs 12 characters or more and at least one special character.

If no platform admin can log in (for example, the only platform admin left), give the right to an admin of the platform operator organisation from the command line:

```bash
kubectl -n ows exec deploy/ows-api -c api -- /app/bin/igrant-api platform grant-admin --email admin2@example.org --config=/etc/igrant-api/config.yaml
```
