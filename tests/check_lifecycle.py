#!/usr/bin/env python3
"""Checks the probes, hooks, rollout and stop of "helm template" outputs.

Usage: check_lifecycle.py <render.yaml>...

For each container of each workload:
- no exec probe and no exec hook in an image without a shell (the
  iGrant.io images api, gateway, consent-management-backend and eudi-wallet
  are distroless: they have no /bin/sh and no /bin/sleep). There, a hook or
  probe must be an HTTP or TCP action, the Kubernetes sleep action, or the
  program itself (only images that contain the program may exec it:
  nats-server in NATS, the Valkey scripts, pg_isready in PostgreSQL);
- no preStop exec of /bin/sleep in any image (the Kubernetes sleep action
  needs no program);
- no initialDelaySeconds on a liveness or readiness probe when the
  container has a startup probe (they start after it).

For each Deployment of an HTTP component (the api, the webhook handler,
the gateway, consent, the dashboard, the wallet service and config roles):
- RollingUpdate with maxUnavailable 0 and maxSurge 25%, and
  minReadySeconds 30 or more;
- a preStop sleep action of 1 second or more;
- terminationGracePeriodSeconds of at least the preStop sleep + the server
  stop time + 5 (the stop time comes from the config files: Server/Gateway
  drainSeconds and gracefulShutdownSeconds for the Go servers;
  server.graceful_shutdown_seconds and background_shutdown_seconds for the
  wallet; 10 s for nginx);
- a readiness probe timeout of 2 s or more, and a startup probe budget
  (periodSeconds x failureThreshold) of 180 s or more.

The script prints one line per problem and a summary line, and exits 1 if
there is a problem. It reads only the pod specs and the ConfigMaps with the
server settings, never a Secret value.
"""

import sys

import yaml

NO_SHELL = ("/api:", "/gateway:", "/consent-management-backend:", "/eudi-wallet:")
HTTP = {
    "api": "go", "webhook": "go", "gateway": "go", "consent": "go",
    "dashboard": "nginx", "wallet-service": "wallet", "wallet-config": "wallet",
}
GO_DEFAULTS = (5, 20)


def pod_of(doc):
    kind = doc.get("kind")
    spec = doc.get("spec") or {}
    if kind in ("Deployment", "StatefulSet", "DaemonSet", "ReplicaSet", "Job"):
        return (spec.get("template") or {}).get("spec")
    if kind == "CronJob":
        return (((spec.get("jobTemplate") or {}).get("spec") or {}).get("template") or {}).get("spec")
    if kind == "Pod":
        return spec
    return None


def component_of(doc):
    labels = ((doc.get("spec") or {}).get("template") or {}).get("metadata", {}).get("labels") or {}
    return labels.get("app.kubernetes.io/component", "")


def server_stop(docs, component):
    """The seconds that the server needs to stop after its stop signal."""
    kind = HTTP[component]
    if kind == "nginx":
        return 10
    for doc in docs:
        if doc.get("kind") != "ConfigMap":
            continue
        for key, text in (doc.get("data") or {}).items():
            if not key.endswith(".yaml"):
                continue
            wanted = {"api": "api.yaml", "webhook": "webhook.yaml", "gateway": "config.yaml", "consent": "config.yaml",
                      "wallet-service": "service.yaml", "wallet-config": "config.yaml"}[component]
            owner = {"api": "-api", "webhook": "-api", "gateway": "-gateway", "consent": "-consent",
                     "wallet-service": "-wallet", "wallet-config": "-wallet"}[component]
            if key != wanted or not doc["metadata"]["name"].endswith(owner):
                continue
            config = yaml.safe_load(text) or {}
            if kind == "wallet":
                server = config.get("server") or {}
                return int(server.get("graceful_shutdown_seconds", 20)) + int(server.get("background_shutdown_seconds", 10))
            section = config.get("Gateway") if component == "gateway" else config.get("Server")
            section = section or {}
            return int(section.get("drainSeconds") or GO_DEFAULTS[0]) + int(section.get("gracefulShutdownSeconds") or GO_DEFAULTS[1])
    return None


def main():
    problems, containers, deployments = [], 0, 0
    for path in sys.argv[1:]:
        docs = [d for d in yaml.safe_load_all(open(path, encoding="utf-8")) if isinstance(d, dict)]
        name_of_file = path.rsplit("/", 1)[-1]
        for doc in docs:
            pod = pod_of(doc)
            if not pod:
                continue
            where = f"{name_of_file}: {doc['kind']}/{doc['metadata']['name']}"
            for group in ("initContainers", "containers"):
                for container in pod.get(group) or []:
                    containers += 1
                    image = container.get("image", "")
                    no_shell = any(part in image for part in NO_SHELL)
                    actions = {f"{probe}": container.get(probe) for probe in ("startupProbe", "readinessProbe", "livenessProbe")}
                    for hook in ("preStop", "postStart"):
                        actions[hook] = (container.get("lifecycle") or {}).get(hook)
                    for name, action in actions.items():
                        if not action:
                            continue
                        command = (action.get("exec") or {}).get("command")
                        if command and no_shell:
                            problems.append(f"{where}:{container['name']}: {name} exec {command} in an image without a shell")
                        if command and command[:1] in (["/bin/sleep"], ["sleep"]):
                            problems.append(f"{where}:{container['name']}: {name} exec {command}: use the sleep action")
                    if container.get("startupProbe"):
                        for probe in ("readinessProbe", "livenessProbe"):
                            if (container.get(probe) or {}).get("initialDelaySeconds"):
                                problems.append(f"{where}:{container['name']}: {probe} has initialDelaySeconds with a startup probe")
            component = component_of(doc)
            if doc.get("kind") != "Deployment" or component not in HTTP:
                continue
            deployments += 1
            spec = doc["spec"]
            strategy = spec.get("strategy") or {}
            rolling = strategy.get("rollingUpdate") or {}
            if strategy.get("type") != "RollingUpdate" or str(rolling.get("maxUnavailable")) not in ("0", "0%") or str(rolling.get("maxSurge")) != "25%":
                problems.append(f"{where}: strategy {strategy}, not RollingUpdate with maxSurge 25% and maxUnavailable 0")
            if int(spec.get("minReadySeconds") or 0) < 30:
                problems.append(f"{where}: minReadySeconds {spec.get('minReadySeconds')}, not 30 or more")
            container = pod["containers"][0]
            sleep = (((container.get("lifecycle") or {}).get("preStop") or {}).get("sleep") or {}).get("seconds")
            if not isinstance(sleep, int) or sleep < 1:
                problems.append(f"{where}: no preStop sleep action of 1 or more seconds")
                sleep = 0
            stop = server_stop(docs, component)
            if stop is None:
                problems.append(f"{where}: no config file with the server's stop settings")
            elif int(pod.get("terminationGracePeriodSeconds") or 30) < sleep + stop + 5:
                problems.append(f"{where}: terminationGracePeriodSeconds {pod.get('terminationGracePeriodSeconds')} is below preStop {sleep} s + server stop {stop} s + 5")
            readiness = container.get("readinessProbe") or {}
            if int(readiness.get("timeoutSeconds") or 1) < 2:
                problems.append(f"{where}: readiness timeout {readiness.get('timeoutSeconds', 1)} s, not 2 s or more")
            startup = container.get("startupProbe") or {}
            if int(startup.get("periodSeconds") or 10) * int(startup.get("failureThreshold") or 3) < 180:
                problems.append(f"{where}: startup probe budget below 180 s")
    for problem in problems:
        print(f"  FAIL: {problem}")
    print(f"{len(sys.argv) - 1} renders, {containers} containers, {deployments} HTTP Deployments, {len(problems)} problems")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
