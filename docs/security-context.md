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

Two checks of `tests/render-matrix.sh` read each render (see [Tests](tests.md)): `tests/check_security.py` checks these settings, and `tests/psscheck` checks the Pod Security Standard `restricted` (latest and v1.25) with the upstream library `k8s.io/pod-security-admission`, the code of the admission plugin of Kubernetes (also AppArmor, SELinux, `procMount`, `hostProcess` and the ephemeral containers).

## Users, writable paths and sysctls

| Component | Containers | User (UID:GID) | fsGroup | Writable paths | Sysctls |
| --- | --- | --- | --- | --- | --- |
| API core (`<release>-api`) | `migrate` (init), `api` | `65532:65532` | `65532` | `/tmp` (`emptyDir` in memory, `api.tmp.sizeLimit`, 64Mi) | `net.ipv4.ip_unprivileged_port_start=0` (port 80) |
| Webhook handler (`<release>-webhook`) | `webhook` | `65532:65532` | `65532` | `/tmp` (`emptyDir` in memory, `api.tmp.sizeLimit`, 64Mi) | `net.ipv4.ip_unprivileged_port_start=0` (port 80) |
| Jobs and hooks of the api (`api.jobs`) | `migrate`, the command | `65532:65532` | `65532` | `/tmp` (`emptyDir` in memory) | none |
| Auth gateway | `gateway` | `65532:65532` | `65532` | none | none |
| Consent, its Jobs and hooks | `consent`, the commands | `65532:65532` | `65532` | `/tmp` (`emptyDir`) | `net.ipv4.ip_unprivileged_port_start=0` (port 80) |
| Dashboard (`<release>-dashboard`) | `dashboard` | `101:101` | none | `/tmp` (`emptyDir`, 64Mi): the pid file and the temporary files of nginx, and `/tmp/dashboard` of the start scripts | `net.ipv4.ip_unprivileged_port_start=0` (port 80) |
| Wallet service and config roles | `wallet-service`, `wallet-config` | `65532:65532` | `65532` | `/tmp` (`emptyDir` in memory, 64Mi), `/run/ows-server` (`emptyDir` in memory, 64Mi: `server.metrics_directory`) | none |
| Wallet workers (each group) | `wallet-worker-<group>` | `65532:65532` | `65532` | `/tmp` (on disk: `organisationWallet.workers.tmp`, 10Gi), `/run/ows-worker` (`emptyDir` in memory, 64Mi: `worker.state_directory`) | none |
| Wallet clock | `wallet-clock` | `65532:65532` | `65532` | `/tmp` (`emptyDir` in memory, 64Mi) | none |
| Hooks of the wallet (`organisationWallet.jobs`) | the commands | `65532:65532` | `65532` | `/tmp` (`emptyDir` in memory, 64Mi) | none |
| Bundled PostgreSQL (`<release>-postgres`) | `postgres` | `999:999` (the user `postgres` of the image) | `999` | the data volume (`/var/lib/postgresql`), `/var/run/postgresql` (`emptyDir` in memory, 1Mi: the socket and the lock file), `/tmp` (`emptyDir`, 64Mi) | none |
| Init hook of the databases (`<release>-db-init`) | `create-databases` | `999:999` | `999` | `/tmp` (`emptyDir` in memory, 16Mi) | none |
| Bundled NATS (`<release>-nats`) | `store-check` (init), `nats`, `reloader` | `65532:65532` (the images have no user) | `65532` | the JetStream store (`/data`; `store-check` mounts it read-only), `/var/run/nats` (`emptyDir` in memory, 1Mi: the pid file) | none |
| Bundled OpenBao | `openbao` | `10001:10001` | `10001` | the data volume, `/tmp` (`emptyDir`, 64Mi) | none |
| Bundled Valkey | `valkey`, `sentinel`, `metrics` | `999:1000` | `1000` | the data volume, `/run/valkey` (`emptyDir` in memory), `/tmp` (`emptyDir`, 16Mi) | none |

Notes:

- `fsGroup` gives the group of the Secret files (mode `0440`) and of the data volumes. Without it, the non-root user cannot read the Secret files, and the process does not start. Your storage must support `fsGroup` (most block storage does).
- The api, the webhook handler, consent and the dashboard listen on port 80 as a non-root user. The sysctl `net.ipv4.ip_unprivileged_port_start=0` lets the pod open a port below 1024 without a capability. It is a safe sysctl (Kubernetes 1.22 or later): you do not need to allow it on the kubelet.
- The bundled PostgreSQL and NATS have `fsGroupChangePolicy: OnRootMismatch`: the kubelet changes the group of the files of the data volume only when the top folder does not have the group. The first start after the upgrade to this release changes all files of the NATS store (see [Upgrade](upgrade.md#the-non-root-containers)). For NATS the chart can give `Always` for one rollout: see [The JetStream store](#the-jetstream-store).
- The reloader sends `SIGHUP` to `nats-server` through the shared process namespace. Thus `nats` and `reloader` must have the same user.
- A size of an `emptyDir` is a limit, not a reservation. When a pod writes more than the limit, the kubelet evicts the pod. An `emptyDir` in memory counts against the memory limit of the container.
- The wallet files of the chart set `server.metrics_directory: /run/ows-server` (service and config) and `worker.state_directory: /run/ows-worker` (workers): each is an `emptyDir` of the pod. The render stops when `organisationWallet.extraConfig` gives such a folder outside the `emptyDir` volumes of the pod.
- No log file: each process logs to stdout and stderr, the container log, which the kubelet rotates (`containerLogMaxSize`, `containerLogMaxFiles`) and which your log agent collects. A log file in a pod has no reader, it is lost with the pod, and its rotation (by default 100 MB x 6 files) fills a `/tmp` of 64Mi: the pod is evicted or the process stops. Thus the render stops when `Log.file.path` of `api.extraConfig`, `gateway.extraConfig` or `consent.extraConfig`, or `log_file.path` of `organisationWallet.extraConfig`, is set, also to a path below `/tmp`.
- The api image has no shell. Each container, hook, Job and probe of the chart starts a program of the image directly (`/app/bin/igrant-api`, `/app/.venv/bin/<command>`), and the probes are HTTP probes. The only exec hook of the wallet pods is the `preStop` command `/bin/sleep` of the service and config pods. Your own commands in the pods (`kubectl exec`) must also call the program directly, for example `kubectl -n ows exec deploy/ows-api -c api -- /app/bin/igrant-api platform status --config=/etc/igrant-api/config.yaml`.

## The JetStream store

NATS, the reloader and the init container `store-check` run as the user 65532 and the group 65532, with `fsGroup` 65532. A NATS of a release before the non-root containers ran as root: each file that root writes has the mode 0600 (a folder 0700) and the owner root, so the user 65532 cannot read it. The kubelet gives each file of the store the group 65532 and the group rights (`fsGroup`), and two things make sure that NATS never starts on a store that it cannot read:

- The `fsGroupChangePolicy` of a rollout. With `OnRootMismatch` (the default of `nats.podSecurityContext`), the kubelet changes the files only when the top folder of the volume does not have the group. That is the case at the first start after the upgrade, but not after a rollback to a release before the non-root containers: the top folder keeps the group, and the files that root wrote during the rollback stay closed. Thus at `helm upgrade` the chart reads the NATS StatefulSet in the cluster (`lookup`), and it gives `fsGroupChangePolicy: Always` for this rollout when the StatefulSet runs NATS as root (no `runAsUser`, or 0) or when its last rollout is not complete. The notes of the release say so. The next upgrade after that rollout gives the value of `nats.podSecurityContext` again: one more rolling restart of NATS.
- The init container `store-check` (`files/nats/store-check.sh`). Before `nats-server` starts, it checks that the user of NATS can read and write each file and folder of the store: through the owner, or through a group of the process (`runAsGroup`, `fsGroup`, `supplementalGroups`). It reads only the metadata (one `stat` of each entry), it writes nothing (the volume is mounted read-only in it), and it stops at the first entry that is not good. When an entry is not good, the pod does not start, and the log names the entry and the repair. Without the check, `nats-server` starts without the streams of these files and logs only a warning: the messages that the services publish to these streams are lost. The check catches each path that does not go through `helm upgrade`, for example `helm rollback` to a revision of this chart, `kubectl rollout undo`, or a tool that renders the chart without a cluster (no `lookup`).

The repair when `store-check` stops a pod: one upgrade with `--set nats.podSecurityContext.fsGroupChangePolicy=Always`, then one more upgrade without it (see [Upgrade](upgrade.md#a-rollback-to-a-release-before-the-non-root-containers)). With `replicas` 3, the rollout stops at the first pod that does not start, and the other two servers keep the majority of the JetStream cluster.

Time at scale (`tests/nats-store.sh`, a store of files of root in 100 stream folders, on the local disk of the test computer, the metadata in the memory cache of the kernel):

| Files in the store | Kubelet change with `Always` (a write of each inode) | Start with `OnRootMismatch` | `store-check` (one `stat` of each entry) | Peak memory of `store-check` |
| --- | --- | --- | --- | --- |
| 200,000 | 2.3 s | 0.2 s | 0.5 s | 4.8 MiB |
| 1,000,000 | 10.2 s | 0.2 s | 2.0 to 2.2 s | not measured |
| 2,000,000 | 21.8 to 35.7 s (two runs) | 0.2 to 0.6 s | 3.6 to 5.9 s | 4.7 MiB |

A JetStream store has about one file for each 8 MiB of messages (the largest message block of NATS), so 10 TB is about 1,300,000 files. The time of `store-check` grows linearly with the files, and its memory stays flat (the walk keeps only the folders of the current path; limit 64Mi). On a volume whose metadata is not in the memory cache, each time is larger: the walk reads the inode tables from the disk. `store-check` thus delays each start of a NATS pod by one read-only walk, a fraction of the full write of `Always`, which happens only for one rollout after NATS ran as root.

## The /tmp folder of the api

The api and the webhook handler write to `/tmp` only the temporary files of the multipart parser of Go: it keeps a form of up to 32 MiB in memory, and it writes a larger file part whole to `/tmp`. With the default body limits of the gateway (`gateway.proxy.maxBodyBytes`: 1 MiB, and 5 MiB and 64 KiB for the file routes), no upload goes to `/tmp`.

`/tmp` is an `emptyDir` in memory of `api.tmp.sizeLimit` (default 64Mi). When it is full, the write of the upload that fills it fails (no space left): only that request fails, never the pod. An `emptyDir` on disk would be different: when its data is above `sizeLimit`, the kubelet evicts the pod, and each request of the pod fails. The files of `/tmp` count against the memory limit of the container.

The render stops when:

- the largest body that the gateway sends to the api (the larger of `gateway.proxy.maxBodyBytes.default` and `.file`; the class `large` goes only to the wallet) is above 32 MiB and above `api.tmp.sizeLimit`: give `api.tmp.sizeLimit` at least that size;
- the memory request and `api.tmp.sizeLimit` together are above the memory limit of the api or of the webhook container (`api.resources`, `api.webhook.resources`): raise the memory limit by the size of `/tmp`.

For example, for uploads of 100 MiB: `gateway.proxy.maxBodyBytes.file: 104857600` and `api.tmp.sizeLimit: 100Mi`. Each upload above 32 MiB then holds its size in `/tmp` while the request runs, so `/tmp` takes one such upload at a time; a second upload at the same time fails with an error, the pod stays.

## The /tmp folder of the workers

The monthly audit export of the wallet (`audit.export`, queue `maintenance`; only with `organisationWallet.audit.bucket.name`) writes one month of the audit log of one data scope two times to `/tmp/ows-audit-export-*`: the export and the download that checks it. Thus the `/tmp` of the workers is on disk, never in memory, and it has its own size (`organisationWallet.workers.tmp.sizeLimit`, default `10Gi`). Give at least two times the largest month of one data scope. A large installation can need tens to hundreds of GB (see [Workers and clock](workers.md#the-tmp-folder-of-the-workers)).

- `emptyDir` (default): the ephemeral storage of the node. The node must have the free disk space.
- `organisationWallet.workers.tmp.volume.enabled: true`: a generic ephemeral volume, a PersistentVolumeClaim of `sizeLimit` that Kubernetes makes with the pod and deletes with the pod (`.volume.storageClass`; empty: `global.storageClass`, else the default storage class).

A group can have its own `tmp` (the same keys), for example a large volume only for the group with the queue `maintenance`.

## Change the settings

Each component has its own `podSecurityContext` and `containerSecurityContext` in `values.yaml`. The hooks and Jobs of the api, consent and the wallet have their own values in `<component>.jobs` (an empty value: the value of the component).

`global.podSecurityContext` and `global.containerSecurityContext` apply to each pod and each container of the chart, under the value of the component: a key of the component replaces the same key of the global value as a whole (for example `seccompProfile` or `sysctls`), and each other key of the global value stays. Thus the keys of your cluster that no component sets, for example `seLinuxOptions` or `supplementalGroups`, go to each pod:

```yaml
global:
  podSecurityContext:
    seLinuxOptions:
      level: "s0:c123,c456"
    supplementalGroups: [4321]
```

A global key that a component also sets (for example `runAsUser`) does not apply to that component: the notes of the release name the components. To use the global key there, set the key of the component to `null`.

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
