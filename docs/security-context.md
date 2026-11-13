# Security settings of the containers

The security settings of each container that the chart runs: the user, the paths that the process writes, the sysctls, and the limits that you must know.

[Back to the contents](../README.md#contents)

## The settings of each container

With the default values, every container of the chart (also each init container and each hook Job container) has these settings:

- A non-root user with a fixed UID and GID: `runAsNonRoot: true`, `runAsUser` and `runAsGroup` (not 0).
- `allowPrivilegeEscalation: false`: a setuid or setgid program gives no extra rights.
- `readOnlyRootFilesystem: true`: the process writes only to volumes (an `emptyDir`, a generic ephemeral volume or the component's data volume).
- `capabilities: {drop: ["ALL"]}`, and no added capability.
- `seccompProfile: {type: RuntimeDefault}`.

The pods use no host network, no host PID, no host IPC, no host port and no `hostPath` volume. So the pods meet the Pod Security Standard `restricted`, and you can enforce it on the release namespace:

```bash
kubectl label namespace ows pod-security.kubernetes.io/enforce=restricted
```

Two checks of `tests/render-matrix.sh` read each render (see [Tests](tests.md)): `tests/check_security.py` checks these settings, and `tests/psscheck` checks the Pod Security Standard `restricted` (latest and v1.25) with the upstream library `k8s.io/pod-security-admission`, the code of the Kubernetes admission plugin (it also covers AppArmor, SELinux, `procMount`, `hostProcess` and ephemeral containers).

## Users, writable paths and sysctls

| Component | Containers | User (UID:GID) | fsGroup | Writable paths | Sysctls |
| --- | --- | --- | --- | --- | --- |
| API core (`<release>-api`) | `migrate` (init), `api` | `65532:65532` | `65532` | `/tmp` (`emptyDir` in memory, `api.tmp.sizeLimit`, 64Mi) | `net.ipv4.ip_unprivileged_port_start=0` (port 80) |
| Webhook handler (`<release>-webhook`) | `webhook` | `65532:65532` | `65532` | `/tmp` (`emptyDir` in memory, `api.tmp.sizeLimit`, 64Mi) | `net.ipv4.ip_unprivileged_port_start=0` (port 80) |
| Jobs and hooks of the api (`api.jobs`) | `migrate`, the command | `65532:65532` | `65532` | `/tmp` (`emptyDir` in memory) | none |
| Auth gateway | `gateway` | `65532:65532` | `65532` | none | none |
| Consent, its Jobs and hooks | `consent`, the commands | `65532:65532` | `65532` | `/tmp` (`emptyDir`) | `net.ipv4.ip_unprivileged_port_start=0` (port 80) |
| Dashboard (`<release>-dashboard`) | `dashboard` | `101:101` | none | `/tmp` (`emptyDir`, 64Mi): the nginx pid file and temporary files, and `/tmp/dashboard` of the start scripts | `net.ipv4.ip_unprivileged_port_start=0` (port 80) |
| Wallet service and config roles | `wallet-service`, `wallet-config` | `65532:65532` | `65532` | `/tmp` (`emptyDir` in memory, 64Mi), `/run/ows-server` (`emptyDir` in memory, 64Mi: `server.metrics_directory`) | none |
| Wallet workers (each group) | `wallet-worker-<group>` | `65532:65532` | `65532` | `/tmp` (`emptyDir` in memory, 64Mi), `/run/ows-worker` (`emptyDir` in memory, 64Mi: `worker.state_directory`) | none |
| Wallet clock | `wallet-clock` | `65532:65532` | `65532` | `/tmp` (`emptyDir` in memory, 64Mi) | none |
| Hooks of the wallet (`organisationWallet.jobs`) | the commands | `65532:65532` | `65532` | `/tmp` (`emptyDir` in memory, 64Mi) | none |
| Bundled PostgreSQL (`<release>-postgres`) | `postgres` | `999:999` (the image's user `postgres`) | `999` | the data volume (`/var/lib/postgresql`), `/var/run/postgresql` (`emptyDir` in memory, 1Mi: the socket and the lock file), `/tmp` (`emptyDir`, 64Mi) | none |
| Init hook of the databases (`<release>-db-init`) | `create-databases` | `999:999` | `999` | `/tmp` (`emptyDir` in memory, 16Mi) | none |
| Bundled NATS (`<release>-nats`) | `nats`, `reloader` | `65532:65532` (the images have no user) | `65532` | the JetStream store (`/data`), `/var/run/nats` (`emptyDir` in memory, 1Mi: the pid file) | none |
| Bundled OpenBao | `openbao` | `10001:10001` | `10001` | the data volume, `/tmp` (`emptyDir`, 64Mi) | none |
| Bundled Valkey | `valkey`, `sentinel`, `metrics` | `999:1000` | `1000` | the data volume, `/run/valkey` (`emptyDir` in memory), `/tmp` (`emptyDir`, 16Mi) | none |

Notes:

- `fsGroup` sets the group of the Secret files (mode `0440`) and of the data volumes. Without it, the non-root user cannot read the Secret files, and the process does not start. Your storage must support `fsGroup` (most block storage does).
- The api, the webhook handler, consent and the dashboard listen on port 80 as a non-root user. The sysctl `net.ipv4.ip_unprivileged_port_start=0` lets the pod open a port below 1024 without a capability. It is a safe sysctl (Kubernetes 1.22 or later): you do not need to allow it on the kubelet.
- The bundled PostgreSQL and NATS have `fsGroupChangePolicy: OnRootMismatch`: the kubelet sets the group of the files on the data volume only when the top folder does not have the group (the first start), so a later start does not walk the volume.
- The reloader sends `SIGHUP` to `nats-server` through the shared process namespace. So `nats` and `reloader` must have the same user.
- The size of an `emptyDir` is a limit, not a reservation. When a pod writes more than the limit, the kubelet evicts the pod. An `emptyDir` in memory counts against the memory limit of the container.
- The chart's wallet files set `server.metrics_directory: /run/ows-server` (service and config) and `worker.state_directory: /run/ows-worker` (workers): each is an `emptyDir` of the pod. The render stops when `organisationWallet.extraConfig` puts such a folder outside the pod's `emptyDir` volumes.
- No log files: each process logs to stdout and stderr (the container log), which the kubelet rotates (`containerLogMaxSize`, `containerLogMaxFiles`) and your log agent collects. A log file in a pod has no reader and is lost with the pod, and its rotation (by default 100 MB x 6 files) fills a `/tmp` of 64Mi: the pod is evicted or the process stops. So the render stops when `Log.file.path` of `api.extraConfig`, `gateway.extraConfig` or `consent.extraConfig`, or `log_file.path` of `organisationWallet.extraConfig`, is set, even to a path below `/tmp`.
- The images of the api, the gateway, consent and the wallet have no shell and no `sleep` program (distroless), and the wallet image has no entrypoint script. Each container, Job and probe of the chart starts a program of the image directly (`/app/bin/igrant-api`, `/app/.venv/bin/<command>`, for example `/app/.venv/bin/start-server`). The probes are HTTP probes, and each preStop hook is the Kubernetes sleep action (`tests/check_lifecycle.py` checks it). Exec probes and hooks are only in the images that have the program: `nats-server` (NATS), the Valkey scripts, and `pg_isready` (PostgreSQL). Your own commands in the pods (`kubectl exec`) must also call the program directly, for example `kubectl -n ows exec deploy/ows-api -c api -- /app/bin/igrant-api platform status --config=/etc/igrant-api/config.yaml`.

## The SSRF guards

The api core, the webhook handler, consent and the wallet call URLs that an organisation or another vendor gives: the webhooks (`payloadUrl`), the organisations' OIDC providers, an organisation's Data Space, and the issuers, verifiers, trust lists, status lists, JWKS and metadata of other vendors. Each of them has an SSRF guard in its code. The guard refuses a connection to a private, loopback, link-local or cloud metadata address (for example 127.0.0.1, 10.0.0.0/8, fc00::/7 or 169.254.169.254), also after a DNS answer or a redirect. The guards are on by default, and the chart does not turn them off. They also protect a cluster without network policies.

| Role | The guard | Off with |
| --- | --- | --- |
| api core, webhook handler | `OutboundHttp.ssrfProtectionDisabled` of the api file (default `false`) | `api.extraConfig.OutboundHttp.ssrfProtectionDisabled: true` |
| consent | `OutboundHttp.ssrfProtectionDisabled` of the consent file (default `false`) | `consent.extraConfig.OutboundHttp.ssrfProtectionDisabled: true` |
| wallet service, config, workers | `ssrf_protection.enabled` of the wallet files (default `true`) | `organisationWallet.extraConfig.ssrf_protection.enabled: false` |

A guard that is off lets an organisation's URL reach every private, loopback and metadata address that the pod reaches: the services of your network, the services of the cluster, and the credentials on the metadata server of your cloud. The notes of `helm install` and `helm upgrade` then show a warning that names the role. Do not turn a guard off in production. If a host that the platform must call has a private address (on premise), allow only that host:

- the wallet: `organisationWallet.ssrf.allowedPrivate` (host names, addresses or CIDRs; never loopback, link-local or the metadata addresses);
- the api core, the webhook handler and consent: an allow list of private hosts comes with a later release of these services. Until then, an OIDC provider of the admins in your network can use `allowPrivateNetwork` of its entry in `Iam.providers`.

With network policies, also give the address to the egress profile `platform` (the public hosts of this platform) or to a profile of your own (see [Network policies](network-policies.md)).

## The stop of a pod

A rolling update or a node drain stops pods while clients still send them requests. Kubernetes removes a stopping pod from the endpoints of its Services at once, but kube-proxy, the ingress controller or the Gateway learn it some time later, and until then they still send new requests to the pod. So each HTTP component (the api, the webhook handler, the gateway, consent, the dashboard, the wallet service and config roles) stops in three steps:

1. The preStop hook: the Kubernetes sleep action for `preStopSeconds` (default 10 s; `api.server.preStopSeconds`, `gateway.preStopSeconds`, `consent.server.preStopSeconds`, `enterpriseDashboard.preStopSeconds`, `organisationWallet.server.preStopSeconds`). The pod keeps serving while the endpoints and the proxies forget it. The sleep must be longer than this time on your cluster.
2. The stop signal: the Go servers (api, webhook handler, gateway, consent) answer 503 on `/readyz` and still accept requests for `drainSeconds`, then wait at most `gracefulShutdownSeconds` for the requests in progress. nginx (the dashboard, `SIGQUIT`) finishes the requests in progress. The wallet waits for its requests (`gracefulShutdownSeconds`) and its background tasks (`backgroundShutdownSeconds`).
3. Kubernetes kills the process after `terminationGracePeriodSeconds`, counted from the start of the preStop. The render stops when it is too short: at least preStop + drain + graceful + 5 s for a Go server (default 10 + 5 + 20 + 5 = 40 s), at least preStop + 10 s for the dashboard, and more than preStop + graceful + background for the wallet.

The rollout of each HTTP Deployment (`strategy`, `minReadySeconds` of the component):

- `RollingUpdate` with `maxSurge: 25%` and `maxUnavailable: 0`: the old pods stop only when the new pods are available, so the capacity never drops;
- `minReadySeconds: 30`: a pod that fails just after its start stops the rollout before an old pod stops.

The probes:

- a startup probe with a budget of 180 s (90 x 2 s; the wallet servers: 650 s, the wait for the schema head);
- a readiness probe with a timeout of 2 s or more;
- a liveness probe without `initialDelaySeconds` (it starts after the startup probe).

The api core, the gateway and consent check the database every 2 s on one connection outside their pools, and `/readyz` fails when no check passed for 10 s. Their readiness probe runs every 2 s, with a timeout of 2 s and 2 failures. So a pod with a broken path to the database leaves its Service after about 14 s (10 s without a passed check, then 2 failed probes), and an interruption of up to 6 s changes nothing. A database outage of more than 10 s takes all these pods out of their Services, by design: then no pod can answer. NATS and the readers' views are start gates: `/readyz` waits for them only at the start. The webhook handler has the same check, with a probe of 5 s x 2 (it answers no client). The other readiness probes (the wallet, the dashboard) check no dependency of the chart: `/readyz` checks only the service itself.

A measurement on a single-node Kubernetes 1.36 cluster (kube-proxy with iptables, network policies on), with 2 pods of each component and 8 clients that open a new TCP connection for each request (about 390 requests per second) during `kubectl rollout restart`: with the default preStop of 10 s, the gateway answered 34 300 of 34 300 requests and the dashboard 34 880 of 34 880 (0 refused connections). Without the preStop hook, the dashboard refused 12 connections: nginx stops listening at the stop signal, before kube-proxy removes the pod. The gateway refused none, because its drain (5 s) also covers this time on one node. The EndpointSlice showed the stopping pod as not ready in the same second as its deletion, and on one node the proxies took less than 0.1 s more. On a cluster with many nodes, kube-proxy on each node, the ingress controller or the Gateway can need a few seconds: keep `preStopSeconds` above that time.

## The /tmp folder of the api

The api and the webhook handler write to `/tmp` only the temporary files of the Go multipart parser: it keeps a form of up to 32 MiB in memory, and writes a larger file part whole to `/tmp`. With the default body limits of the gateway (`gateway.proxy.maxBodyBytes`: 1 MiB, and 5 MiB and 64 KiB for the file routes), no upload goes to `/tmp`.

`/tmp` is an `emptyDir` in memory of `api.tmp.sizeLimit` (default 64Mi). When it is full, the write of the upload that fills it fails (no space left): only that request fails, never the pod. An `emptyDir` on disk is different: when its data goes above `sizeLimit`, the kubelet evicts the pod, and every request of the pod fails. The files in `/tmp` count against the memory limit of the container.

The render stops when:

- the largest body that the gateway sends to the api (the larger of `gateway.proxy.maxBodyBytes.default` and `.file`; the class `large` goes only to the wallet) is above 32 MiB and above `api.tmp.sizeLimit`: set `api.tmp.sizeLimit` to at least that size;
- the memory request plus `api.tmp.sizeLimit` is above the memory limit of the api or the webhook container (`api.resources`, `api.webhook.resources`): raise the memory limit by the size of `/tmp`;
- the api's memory request plus `Uploads.maxInProgress` x the largest upload file (the larger of `ImageUpload.maxBytes` and `Uploads.individualImportMaxFileBytes` of `api.extraConfig`) is above the api's memory limit (`api.resources`): each upload in progress holds its file in memory (8 x 5 MiB = 40 MiB with the defaults). Lower `Uploads.maxInProgress` or the file limits, or raise the memory limit;
- `gateway.proxy.maxBodyBytes.file` is below `ImageUpload.maxBytes` + 65536 or below `Uploads.individualImportMaxFileBytes` + 65536: the gateway would refuse an upload that the api accepts.

For example, for uploads of 100 MiB: `gateway.proxy.maxBodyBytes.file: 104857600` and `api.tmp.sizeLimit: 100Mi`. Each upload above 32 MiB then holds its size in `/tmp` while the request runs, so `/tmp` takes one such upload at a time: a second one at the same time fails with an error, and the pod stays.

## The /tmp folder of the workers

The `/tmp` of the workers is an `emptyDir` in memory of 64Mi, as in the other wallet pods, for the temporary files of Python only. The monthly audit export writes no local file (it sends its parts to the bucket; see [Workers and clock](workers.md#the-tmp-folder-of-the-workers)).

## Change the settings

Each component has its own `podSecurityContext` and `containerSecurityContext` in `values.yaml`. The hooks and Jobs of the api, consent and the wallet have their own values in `<component>.jobs` (empty: the value of the component).

`global.podSecurityContext` and `global.containerSecurityContext` apply to every pod and container of the chart, under the value of the component. A key of the component replaces the same global key as a whole (for example `seccompProfile` or `sysctls`), and every other global key stays. So keys of your cluster that no component sets, for example `seLinuxOptions` or `supplementalGroups`, go to every pod:

```yaml
global:
  podSecurityContext:
    seLinuxOptions:
      level: "s0:c123,c456"
    supplementalGroups: [4321]
```

A global key that a component also sets (for example `runAsUser`) does not apply to that component: the release notes name these components. To use the global key there, set the key of the component to `null`.

Helm merges your keys into the default of a component. To remove a default key, set it to `null`. For example, on OpenShift the security context constraints (SCC) give the UID and the groups:

```yaml
api:
  podSecurityContext:
    runAsUser: null
    runAsGroup: null
    fsGroup: null
```

Do the same for each component, and test the installation on your cluster first.

Do not remove `readOnlyRootFilesystem`, the `sysctls` or `fsGroup` of a component without a test: the images of this release expect them.
