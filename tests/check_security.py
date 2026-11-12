#!/usr/bin/env python3
"""Checks the security settings of each container of "helm template" outputs.

Usage: check_security.py <render.yaml>...

The target of each container of each pod (Deployment, StatefulSet,
DaemonSet, ReplicaSet, Job, CronJob, Pod), the init containers too:

- a non-root user: runAsNonRoot true, and runAsUser and runAsGroup are
  numbers other than 0 (the container value, else the pod value);
- allowPrivilegeEscalation false and readOnlyRootFilesystem true (container);
- capabilities drop ALL, and no added capability (container);
- not privileged (container);
- seccompProfile RuntimeDefault (the container value, else the pod value);
- no host port (container);
- no host network, no host PID and no host IPC, only the volume types and
  the safe sysctls of the Pod Security Standard "restricted" (pod).

The script writes one line for each target that a pod or a container
misses, and a summary line. It exits 1 when a target is missed. It reads
only the pod specs: never a Secret value.
"""

import sys

import yaml

# The volume types of the Pod Security Standard "restricted".
VOLUME_TYPES = {"configMap", "csi", "downwardAPI", "emptyDir", "ephemeral", "persistentVolumeClaim", "projected", "secret"}
# The safe sysctls of the Pod Security Standard "baseline" in Kubernetes
# 1.25 (the lowest version of the chart).
SAFE_SYSCTLS = {"kernel.shm_rmid_forced", "net.ipv4.ip_local_port_range", "net.ipv4.ip_unprivileged_port_start",
                "net.ipv4.tcp_syncookies", "net.ipv4.ping_group_range"}


def pod_spec(doc: dict):
    """The pod spec of a workload, or None."""
    kind = doc.get("kind")
    spec = doc.get("spec") or {}
    if kind in ("Deployment", "StatefulSet", "DaemonSet", "ReplicaSet", "Job"):
        return (spec.get("template") or {}).get("spec")
    if kind == "CronJob":
        return (((spec.get("jobTemplate") or {}).get("spec") or {}).get("template") or {}).get("spec")
    if kind == "Pod":
        return spec
    return None


def problems_of(pod: dict, container: dict) -> list:
    """The targets that one container misses."""
    pod_context = pod.get("securityContext") or {}
    context = container.get("securityContext") or {}

    def effective(key):
        return context[key] if key in context else pod_context.get(key)

    found = []
    if effective("runAsNonRoot") is not True:
        found.append("runAsNonRoot is not true")
    for key in ("runAsUser", "runAsGroup"):
        value = effective(key)
        if not isinstance(value, int) or isinstance(value, bool) or value <= 0:
            found.append(f"{key} is {value!r}, not a number other than 0")
    if context.get("allowPrivilegeEscalation") is not False:
        found.append("allowPrivilegeEscalation is not false")
    if context.get("readOnlyRootFilesystem") is not True:
        found.append("readOnlyRootFilesystem is not true")
    capabilities = context.get("capabilities") or {}
    if "ALL" not in (capabilities.get("drop") or []):
        found.append("capabilities do not drop ALL")
    if capabilities.get("add"):
        found.append(f"capabilities add {capabilities['add']}")
    if context.get("privileged") is True:
        found.append("privileged")
    seccomp = (context.get("seccompProfile") or pod_context.get("seccompProfile") or {}).get("type")
    if seccomp != "RuntimeDefault":
        found.append(f"seccompProfile is {seccomp!r}, not RuntimeDefault")
    if any(port.get("hostPort") for port in container.get("ports") or []):
        found.append("a host port")
    return found


def pod_problems_of(pod: dict) -> list:
    """The targets that one pod misses."""
    found = [f"the pod has {key}" for key in ("hostNetwork", "hostPID", "hostIPC") if pod.get(key) is True]
    for volume in pod.get("volumes") or []:
        kinds = set(volume) - {"name"}
        if not kinds <= VOLUME_TYPES:
            found.append(f"the volume {volume.get('name')} has the type {sorted(kinds - VOLUME_TYPES)}")
    for sysctl in (pod.get("securityContext") or {}).get("sysctls") or []:
        if sysctl.get("name") not in SAFE_SYSCTLS:
            found.append(f"the sysctl {sysctl.get('name')} is not a safe sysctl")
    return found


def main() -> int:
    if len(sys.argv) < 2:
        print(__doc__.strip().splitlines()[2], file=sys.stderr)
        return 2
    containers = 0
    failures = []
    for path in sys.argv[1:]:
        with open(path, encoding="utf-8") as handle:
            docs = [d for d in yaml.safe_load_all(handle) if isinstance(d, dict)]
        for doc in docs:
            pod = pod_spec(doc)
            if not pod:
                continue
            for problem in pod_problems_of(pod):
                failures.append(f"{path.rsplit('/', 1)[-1]}: {doc['kind']}/{doc['metadata']['name']}: {problem}")
            for group in ("initContainers", "containers"):
                for container in pod.get(group) or []:
                    containers += 1
                    name = ("init:" if group == "initContainers" else "") + container.get("name", "?")
                    for problem in problems_of(pod, container):
                        failures.append(f"{path.rsplit('/', 1)[-1]}: {doc['kind']}/{doc['metadata']['name']}:{name}: {problem}")
    for failure in failures:
        print(f"  FAIL: {failure}")
    print(f"{len(sys.argv) - 1} renders, {containers} containers, {len(failures)} problems")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
