#!/usr/bin/env python3
"""Checks the order of the hooks of one install or upgrade, without a cluster.

Usage:
  check_hook_order.py install <render.yaml>
  check_hook_order.py upgrade <before.yaml> <after.yaml>

The render files are "helm template" outputs of the chart: before has the
values of the earlier release, after the values of the new release. The
script replays the steps of Helm 3.16:

- install (pkg/action/install.go, performInstall): the pre-install hooks,
  then the resources of the release, then the post-install hooks;
- upgrade (pkg/action/upgrade.go, releasingUpgrade): the objects of the
  earlier release exist (its resources, and its hooks: Helm does not delete
  a hook). Then the pre-upgrade hooks, then the resources of the new
  release (pkg/kube/client.go, Update: a resource of the earlier release
  that the new release does not have is deleted, unless the live object has
  helm.sh/resource-policy keep), then the post-upgrade hooks.

Helm runs the hooks of one event one after the other, in the order of
their weight, then of their name (pkg/action/hooks.go, execHook), and waits
until each Job is complete. A Job of the resources (not a hook) runs at the
same time as the other resources and the post-install hooks, so no hook
can expect its result.

For each hook Job, the script checks that, when the Job starts:
- each Secret key and each ConfigMap that it reads exists (a Secret or a
  ConfigMap that the chart does not render is yours: it exists);
- each database that it connects to exists, with its user (the database
  sections of its configuration files). The init Job makes the databases
  and their owner users (DATABASES), the roles hook of the wallet makes the
  database roles of the wallet, and the databases and users of the earlier
  release exist.
At the end, each Secret key and ConfigMap that a Deployment or a
StatefulSet of the new release reads exists.

It writes one line for each problem and exits 1 when there is one. It
prints only names and keys, never a Secret value.
"""

import sys

import yaml

READS_WORKLOADS = ("Deployment", "StatefulSet", "Job")


def load(path: str) -> list:
    with open(path, encoding="utf-8") as handle:
        return [doc for doc in yaml.safe_load_all(handle) if doc]


def annotations(doc: dict) -> dict:
    return doc["metadata"].get("annotations") or {}


def events(doc: dict) -> list:
    hook = annotations(doc).get("helm.sh/hook")
    return [event.strip() for event in hook.split(",")] if hook else []


def key(doc: dict) -> tuple:
    return doc["kind"], doc["metadata"]["name"]


def object_keys(doc: dict) -> set:
    return set(doc.get("data") or {}) | set(doc.get("stringData") or {})


def pod_spec(doc: dict) -> dict:
    return doc["spec"]["template"]["spec"]


def containers(spec: dict) -> list:
    return spec.get("initContainers", []) + spec.get("containers", [])


def reads(doc: dict) -> tuple:
    """The Secrets and ConfigMaps that a workload reads: sets of (name, key or None)."""
    spec = pod_spec(doc)
    secrets, config_maps = set(), set()

    def add(target: set, name: str, items) -> None:
        target.update({(name, item["key"]) for item in items} if items else {(name, None)})

    for volume in spec.get("volumes", []):
        if "secret" in volume and not volume["secret"].get("optional"):
            add(secrets, volume["secret"]["secretName"], volume["secret"].get("items"))
        if "configMap" in volume and not volume["configMap"].get("optional"):
            add(config_maps, volume["configMap"]["name"], volume["configMap"].get("items"))
        for source in (volume.get("projected") or {}).get("sources", []):
            if "secret" in source and not source["secret"].get("optional"):
                add(secrets, source["secret"]["name"], source["secret"].get("items"))
            if "configMap" in source and not source["configMap"].get("optional"):
                add(config_maps, source["configMap"]["name"], source["configMap"].get("items"))
    for container in containers(spec):
        for env in container.get("env", []):
            source = env.get("valueFrom") or {}
            if "secretKeyRef" in source and not source["secretKeyRef"].get("optional"):
                secrets.add((source["secretKeyRef"]["name"], source["secretKeyRef"]["key"]))
            if "configMapKeyRef" in source and not source["configMapKeyRef"].get("optional"):
                config_maps.add((source["configMapKeyRef"]["name"], source["configMapKeyRef"]["key"]))
        for source in container.get("envFrom", []):
            if "secretRef" in source:
                secrets.add((source["secretRef"]["name"], None))
            if "configMapRef" in source:
                config_maps.add((source["configMapRef"]["name"], None))
    return secrets, config_maps


def database_sections(value) -> list:
    """The database sections (a dict with "name") in a configuration file: database, DataBase, Extensions.oidc.database."""
    found = []
    if isinstance(value, dict):
        for name, item in value.items():
            if name in ("database", "DataBase") and isinstance(item, dict) and "name" in item:
                found.append(item)
            else:
                found.extend(database_sections(item))
    return found


def env_value(doc: dict, name: str):
    for container in containers(pod_spec(doc)):
        for env in container.get("env", []):
            if env["name"] == name and "value" in env:
                return env["value"]
    return None


def option(command: list, name: str):
    return command[command.index(name) + 1] if name in command and command.index(name) + 1 < len(command) else None


def admin_users(doc: dict) -> set:
    """The admin users of the server that a Job names (PGUSER, --admin-user)."""
    users = {env_value(doc, "PGUSER")}
    for container in containers(pod_spec(doc)):
        users.add(option((container.get("command") or []) + (container.get("args") or []), "--admin-user"))
    return users - {None}


class Cluster:
    """The objects, databases and users of the namespace and its server, as the replay goes."""

    def __init__(self, rendered: list):
        # A Secret or ConfigMap that the chart renders is made by the chart;
        # any other one is yours, and exists.
        self.rendered = {key(doc) for doc in rendered if doc.get("kind") in ("Secret", "ConfigMap")}
        self.objects: dict = {}
        self.databases: set = set()
        # The admin user of the server exists with the server: the user of
        # the init Job (PGUSER) and the --admin-user of the hook commands.
        self.users: set = set()
        for doc in rendered:
            if doc.get("kind") == "Job":
                self.users.update(admin_users(doc))
        self.problems: list = []

    def apply(self, doc: dict) -> None:
        self.objects[key(doc)] = doc

    def exists(self, kind: str, name: str, item) -> bool:
        if (kind, name) not in self.objects:
            return (kind, name) not in self.rendered
        return item is None or item in object_keys(self.objects[(kind, name)])

    def check_reads(self, doc: dict, when: str) -> None:
        secrets, config_maps = reads(doc)
        for kind, refs in (("Secret", secrets), ("ConfigMap", config_maps)):
            for name, item in sorted(refs, key=str):
                if not self.exists(kind, name, item):
                    what = f"the key {item} of the {kind} {name}" if item else f"the {kind} {name}"
                    self.problems.append(f"{when}: {doc['kind']} {doc['metadata']['name']} reads {what}, which does not exist yet")

    def config_files(self, doc: dict) -> list:
        files = []
        for name, _ in reads(doc)[1]:
            config_map = self.objects.get(("ConfigMap", name))
            for text in ((config_map or {}).get("data") or {}).values():
                try:
                    files.append(yaml.safe_load(text))
                except yaml.YAMLError:
                    continue
        return files

    def run_job(self, doc: dict, when: str) -> None:
        """Checks the inputs of a Job, then records what it makes."""
        self.check_reads(doc, when)
        name = doc["metadata"]["name"]
        for config in self.config_files(doc):
            for section in database_sections(config):
                if section["name"] not in self.databases:
                    self.problems.append(f"{when}: Job {name} connects to the database {section['name']}, which does not exist yet")
                user = section.get("user") or section.get("username")
                if user and user not in self.users:
                    self.problems.append(f"{when}: Job {name} connects as the user {user}, which does not exist yet")
        self.record(doc)

    def record(self, doc: dict) -> None:
        """The databases, users and database roles that a Job makes when it is complete."""
        made = env_value(doc, "DATABASES")
        if made:
            self.databases.update(made.split())
            self.users.update(made.split())
        for container in containers(pod_spec(doc)):
            command = (container.get("command") or []) + (container.get("args") or [])
            if command[:2] == ["/app/.venv/bin/database-roles", "apply"]:
                prefixes = [section.get("role_prefix") or section["name"] for config in self.config_files(doc)
                            for section in database_sections(config)]
                mount = option(command, "--password-dir")
                volume = next((m["name"] for m in container.get("volumeMounts", []) if m["mountPath"] == mount), None)
                items = next((v["secret"].get("items", []) for v in pod_spec(doc).get("volumes", [])
                              if v["name"] == volume and "secret" in v), [])
                self.users.update(f"{prefix}_{item['path']}" for prefix in prefixes for item in items)

    def run_hooks(self, docs: list, event: str) -> None:
        hooks = [doc for doc in docs if event in events(doc)]
        # The weight, then the name (hookByWeight); a stable sort keeps the
        # order of the kinds (the render order) for the same weight and name.
        hooks.sort(key=lambda doc: (int(annotations(doc).get("helm.sh/hook-weight", "0")), doc["metadata"]["name"]))
        for doc in hooks:
            if doc["kind"] == "Job":
                self.run_job(doc, event)
            self.apply(doc)

    def check_workloads(self, docs: list, when: str) -> None:
        for doc in docs:
            if doc.get("kind") in READS_WORKLOADS and not events(doc):
                self.check_reads(doc, when)


def resources(docs: list) -> list:
    return [doc for doc in docs if not events(doc)]


def install(after: list) -> list:
    cluster = Cluster(after)
    cluster.run_hooks(after, "pre-install")
    for doc in resources(after):
        cluster.apply(doc)
    # A Job of the resources runs at the same time as the post-install
    # hooks: its databases do not count for them.
    cluster.run_hooks(after, "post-install")
    cluster.check_workloads(after, "after the install")
    return cluster.problems


def upgrade(before: list, after: list) -> list:
    cluster = Cluster(after + before)
    # The earlier release: its resources and its hooks, and what its Jobs made.
    for doc in before:
        cluster.apply(doc)
        if doc["kind"] == "Job":
            cluster.record(doc)
    cluster.run_hooks(after, "pre-upgrade")
    new = {key(doc) for doc in resources(after)}
    for doc in resources(before):
        live = cluster.objects.get(key(doc))
        if key(doc) not in new and live is not None and annotations(live).get("helm.sh/resource-policy") != "keep":
            del cluster.objects[key(doc)]
    for doc in resources(after):
        cluster.apply(doc)
    cluster.run_hooks(after, "post-upgrade")
    cluster.check_workloads(after, "after the upgrade")
    return cluster.problems


def main() -> int:
    if len(sys.argv) == 3 and sys.argv[1] == "install":
        problems = install(load(sys.argv[2]))
    elif len(sys.argv) == 4 and sys.argv[1] == "upgrade":
        problems = upgrade(load(sys.argv[2]), load(sys.argv[3]))
    else:
        print(__doc__.split("\n\n")[1], file=sys.stderr)
        return 2
    for problem in problems:
        print(f"  FAIL: {problem}")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
