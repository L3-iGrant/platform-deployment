# Security settings of the containers

This page gives the security settings of each container that the chart runs: the user, the paths that the process writes, the sysctls and the limits that you must know.

[Back to the contents](../README.md#contents)

## The settings of each container

With the default values, each container of the chart (also each init container and each container of a hook Job) has these settings:

- A non-root user with a fixed UID and GID: `runAsNonRoot: true`, `runAsUser` and `runAsGroup` (not 0).
- `allowPrivilegeEscalation: false`: a setuid or setgid program does not give more rights.
- `readOnlyRootFilesystem: true`: the process writes only to volumes (an `emptyDir`, a generic ephemeral volume or the data volume of the component).
- `capabilities: {drop: ["ALL"]}`, and no added capability.
- `seccompProfile: {type: RuntimeDefault}`.

The pods use no host network, no host PID, no host IPC, no host port and no `hostPath` volume. Thus the pods meet the Pod Security Standard `restricted`. You can enforce it on the release namespace:

```bash
kubectl label namespace ows pod-security.kubernetes.io/enforce=restricted
```

The test `tests/check_security.py` checks these settings in each render of `tests/render-matrix.sh` (see [Tests](tests.md)).

## Users, writable paths and sysctls

| Component | Containers | User (UID:GID) | fsGroup | Writable paths | Sysctls |
| --- | --- | --- | --- | --- | --- |
| API core (`<release>-api`) | `migrate` (init), `api` | `65532:65532` | `65532` | `/tmp` (`emptyDir`, 64Mi) | `net.ipv4.ip_unprivileged_port_start=0` (port 80) |
| Webhook handler (`<release>-webhook`) | `webhook` | `65532:65532` | `65532` | `/tmp` (`emptyDir`, 64Mi) | `net.ipv4.ip_unprivileged_port_start=0` (port 80) |
| Jobs and hooks of the api (`api.jobs`) | `migrate`, the command | `65532:65532` | `65532` | `/tmp` (`emptyDir` in memory) | none |
| Auth gateway | `gateway` | `65532:65532` | `65532` | none | none |
| Consent, its Jobs and hooks | `consent`, the commands | `65532:65532` | `65532` | `/tmp` (`emptyDir`) | `net.ipv4.ip_unprivileged_port_start=0` (port 80) |
| Dashboard (`<release>-dashboard`) | `dashboard` | `101:101` | none | `/tmp` (`emptyDir`, 64Mi): the pid file and the temporary files of nginx, and `/tmp/dashboard` of the start scripts | `net.ipv4.ip_unprivileged_port_start=0` (port 80) |
| Wallet service and config roles | `wallet-service`, `wallet-config` | `65532:65532` | `65532` | `/tmp` (`emptyDir` in memory, 64Mi), `/run/ows-server` (`emptyDir` in memory, 64Mi: `server.metrics_directory`) | none |
| Wallet workers (each group) | `wallet-worker-<group>` | `65532:65532` | `65532` | `/tmp` (`emptyDir` in memory, 64Mi), `/run/ows-worker` (`emptyDir` in memory, 64Mi: `worker.state_directory`) | none |
| Wallet clock | `wallet-clock` | `65532:65532` | `65532` | `/tmp` (`emptyDir` in memory, 64Mi) | none |
| Hooks of the wallet (`organisationWallet.jobs`) | the commands | `65532:65532` | `65532` | `/tmp` (`emptyDir` in memory, 64Mi) | none |
| Bundled PostgreSQL (`<release>-postgres`) | `postgres` | `999:999` (the user `postgres` of the image) | `999` | the data volume (`/var/lib/postgresql`), `/var/run/postgresql` (`emptyDir` in memory, 1Mi: the socket and the lock file), `/tmp` (`emptyDir`, 64Mi) | none |
| Init hook of the databases (`<release>-db-init`) | `create-databases` | `999:999` | `999` | `/tmp` (`emptyDir` in memory, 16Mi) | none |
| Bundled NATS (`<release>-nats`) | `nats`, `reloader` | `1000:1000` (the images have no user) | `1000` | the JetStream store (`/data`), `/var/run/nats` (`emptyDir` in memory, 1Mi: the pid file) | none |
| Bundled OpenBao | `openbao` | `10001:10001` | `10001` | the data volume, `/tmp` (`emptyDir`, 64Mi) | none |
| Bundled Valkey | `valkey`, `sentinel`, `metrics` | `999:1000` | `1000` | the data volume, `/run/valkey` (`emptyDir` in memory), `/tmp` (`emptyDir`, 16Mi) | none |

Notes:

- `fsGroup` gives the group of the Secret files (mode `0440`) and of the data volumes. Without it, the non-root user cannot read the Secret files, and the process does not start. Your storage must support `fsGroup` (most block storage does).
- The api, the webhook handler, consent and the dashboard listen on port 80 as a non-root user. The sysctl `net.ipv4.ip_unprivileged_port_start=0` lets the pod open a port below 1024 without a capability. It is a safe sysctl (Kubernetes 1.22 or later): you do not need to allow it on the kubelet.
- The bundled PostgreSQL and NATS have `fsGroupChangePolicy: OnRootMismatch`: the kubelet changes the group of the files of the data volume only when the top folder does not have the group. The first start after the upgrade to this release changes all files of the NATS store (see [Upgrade](upgrade.md#the-non-root-containers)).
- The reloader sends `SIGHUP` to `nats-server` through the shared process namespace. Thus `nats` and `reloader` must have the same user.
- A size of an `emptyDir` is a limit, not a reservation. When a pod writes more than the limit, the kubelet evicts the pod. An `emptyDir` in memory counts against the memory limit of the container.
- The wallet files of the chart set `server.metrics_directory: /run/ows-server` (service and config) and `worker.state_directory: /run/ows-worker` (workers): each is an `emptyDir` of the pod. A log file must also be on an `emptyDir`: the render stops when `log_file.path` of `organisationWallet.extraConfig` is not below `/tmp` (or below the folder of the role), or when `Log.file.path` of `api.extraConfig` is not below `/tmp/`.
- The api image has no shell. Each container, hook, Job and probe of the chart starts a program of the image directly (`/app/bin/igrant-api`, `/app/.venv/bin/<command>`), and the probes are HTTP probes. The only exec hook of the wallet pods is the `preStop` command `/bin/sleep` of the service and config pods. Your own commands in the pods (`kubectl exec`) must also call the program directly, for example `kubectl -n ows exec deploy/ows-api -c api -- /app/bin/igrant-api platform status --config=/etc/igrant-api/config.yaml`.

## The /tmp folder of the workers

The `/tmp` of the workers is an `emptyDir` in memory of 64Mi, as in the other wallet pods: only the temporary files of Python. The monthly audit export writes no local file (it sends its parts to the bucket; see [Workers and clock](workers.md#the-tmp-folder-of-the-workers)).

## Change the settings

Each component has its own `podSecurityContext` and `containerSecurityContext` in `values.yaml`. The hooks and Jobs of the api, consent and the wallet have their own values in `<component>.jobs`. `global.podSecurityContext` and `global.containerSecurityContext` apply only to a component whose own value is empty (`{}`).

Helm merges your keys into the default of a component. To remove a key of the default, set it to `null`. For example, on OpenShift the security context constraints (SCC) give the UID and the groups:

```yaml
api:
  podSecurityContext:
    runAsUser: null
    runAsGroup: null
    fsGroup: null
```

Do the same for each component, and test the installation on your cluster first.

Do not remove `readOnlyRootFilesystem`, the `sysctls` or `fsGroup` of a component without a test: the images of this release expect them.
