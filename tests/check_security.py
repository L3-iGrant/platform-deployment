#!/usr/bin/env python3
"""Checks the security settings of each container of "helm template" outputs.

Usage: check_security.py <render.yaml>...

The target of each container of each pod (Deployment, StatefulSet,
DaemonSet, ReplicaSet, Job, CronJob, Pod), the init containers and the
ephemeral containers too:

- a non-root user: runAsNonRoot true, and runAsUser and runAsGroup are
  numbers other than 0 (the container value, else the pod value);
- allowPrivilegeEscalation false and readOnlyRootFilesystem true (container);
- capabilities drop ALL, and no added capability (container);
- not privileged (container);
- seccompProfile RuntimeDefault (the container value, else the pod value);
- no host port (container);
- the SELinux options of the Pod Security Standard (the container value
  and the pod value): no user and no role, and the type empty or one of
  container_t, container_init_t, container_kvm_t, container_engine_t;
- the AppArmor profile (the container value, the pod value and the
  annotations container.apparmor.security.beta.kubernetes.io/<name> of the
  pod template): RuntimeDefault or Localhost (runtime/default, localhost/*);
- procMount Default or empty (container);
- no Windows hostProcess (the container value and the pod value);
- no host network, no host PID and no host IPC, only the volume types and
  the safe sysctls of the Pod Security Standard "restricted" (pod).

tests/psscheck (the upstream library k8s.io/pod-security-admission) checks
the same renders against the standard itself; tests/render-matrix.sh gives
it the count of the containers of this script, so that both read the same
containers.

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
# The SELinux types of the Pod Security Standard "baseline" (an empty type
# is allowed too).
SELINUX_TYPES = {"container_t", "container_init_t", "container_kvm_t", "container_engine_t"}
APPARMOR_TYPES = {"RuntimeDefault", "Localhost"}
APPARMOR_ANNOTATION = "container.apparmor.security.beta.kubernetes.io/"
CONTAINER_GROUPS = (("initContainers", "init:"), ("containers", ""), ("ephemeralContainers", "ephemeral:"))


def selinux_problems(options, where: str) -> list:
    """The SELinux options that the standard does not allow."""
    found = []
    options = options or {}
    if options.get("type") and options["type"] not in SELINUX_TYPES:
        found.append(f"{where}seLinuxOptions.type is {options['type']!r}")
    for key in ("user", "role"):
        if options.get(key):
            found.append(f"{where}seLinuxOptions.{key} is set")
    return found


def apparmor_problems(profile, where: str) -> list:
    """An AppArmor profile that the standard does not allow."""
    if profile and profile.get("type") not in APPARMOR_TYPES:
        return [f"{where}appArmorProfile.type is {profile.get('type')!r}, not RuntimeDefault or Localhost"]
    return []


def pod_of(doc: dict):
    """The pod spec and the pod annotations of a workload, or (None, None)."""
    kind = doc.get("kind")
    spec = doc.get("spec") or {}
    if kind in ("Deployment", "StatefulSet", "DaemonSet", "ReplicaSet", "ReplicationController", "Job"):
        template = spec.get("template") or {}
    elif kind == "CronJob":
        template = ((spec.get("jobTemplate") or {}).get("spec") or {}).get("template") or {}
    elif kind == "PodTemplate":
        template = doc.get("template") or {}
    elif kind == "Pod":
        template = doc
    else:
        return None, None
    return template.get("spec"), (template.get("metadata") or {}).get("annotations") or {}


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
    found += selinux_problems(context.get("seLinuxOptions"), "")
    found += apparmor_problems(context.get("appArmorProfile"), "")
    if context.get("procMount") not in (None, "", "Default"):
        found.append(f"procMount is {context['procMount']!r}, not Default")
    if (context.get("windowsOptions") or {}).get("hostProcess") is True:
        found.append("windowsOptions.hostProcess is true")
    return found


def pod_problems_of(pod: dict, annotations: dict) -> list:
    """The targets that one pod misses."""
    found = [f"the pod has {key}" for key in ("hostNetwork", "hostPID", "hostIPC") if pod.get(key) is True]
    pod_context = pod.get("securityContext") or {}
    found += selinux_problems(pod_context.get("seLinuxOptions"), "the pod ")
    found += apparmor_problems(pod_context.get("appArmorProfile"), "the pod ")
    if (pod_context.get("windowsOptions") or {}).get("hostProcess") is True:
        found.append("the pod has windowsOptions.hostProcess true")
    for key, value in (annotations or {}).items():
        if key.startswith(APPARMOR_ANNOTATION) and value != "runtime/default" and not str(value).startswith("localhost/"):
            found.append(f"the annotation {key} is {value!r}")
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
            pod, annotations = pod_of(doc)
            if not pod:
                continue
            for problem in pod_problems_of(pod, annotations):
                failures.append(f"{path.rsplit('/', 1)[-1]}: {doc['kind']}/{doc['metadata']['name']}: {problem}")
            for group, prefix in CONTAINER_GROUPS:
                for container in pod.get(group) or []:
                    containers += 1
                    name = prefix + container.get("name", "?")
                    for problem in problems_of(pod, container):
                        failures.append(f"{path.rsplit('/', 1)[-1]}: {doc['kind']}/{doc['metadata']['name']}:{name}: {problem}")
    for failure in failures:
        print(f"  FAIL: {failure}")
    print(f"{len(sys.argv) - 1} renders, {containers} containers, {len(failures)} problems")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
