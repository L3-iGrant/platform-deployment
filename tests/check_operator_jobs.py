#!/usr/bin/env python3
"""Checks the api's operator Jobs in one "helm template" output.

Usage: check_operator_jobs.py <render.yaml> <case>

The cases:
  none       the default values: no operator Job
  bootstrap  api.jobs.bootstrapPlatform (a new installation)

For each Job: the command and arguments of each container, the order of
the init containers (migrate first), and the password, which must be a file
from its own Secret (--password-file), never an argument, a variable or a
ConfigMap value. The values have no password key (the schema refuses one).
"""

import json
import sys

import yaml

RELEASE = "t"
CONFIG = "--config=/etc/igrant-api/config.yaml"
PASSWORD_FILE = "--password-file=/run/secrets/onboard/password"
OPERATOR_JOBS = ("api-bootstrap-platform",)

# The expected Jobs of each case: name -> (init containers after migrate,
# arguments of the main container, password Secret and key or None).
CASES = {
    "none": {},
    "bootstrap": {
        "api-bootstrap-platform": ([], ["onboard", "bootstrap-platform", "--admin-email=admin@example.org",
                                        "--admin-name=First Admin", PASSWORD_FILE,
                                        "--organisation-name=Example Wallet Provider", "--type=Technology",
                                        "--location=Stockholm", "--policy-url=https://example.org/privacy", CONFIG],
                                   ("platform-admin", "first-password")),
    },
}


def main() -> int:
    path, case = sys.argv[1:3]
    with open(path, encoding="utf-8") as handle:
        text = handle.read()
    docs = [d for d in yaml.safe_load_all(text) if d]
    failures: list[str] = []

    def check(condition: bool, message: str) -> None:
        if not condition:
            failures.append(message)

    want = CASES[case]
    jobs = {}
    for doc in docs:
        if doc.get("kind") != "Job":
            continue
        for name in OPERATOR_JOBS:
            if doc["metadata"]["name"] == f"{RELEASE}-{name}-1":
                jobs[name] = doc
    check(sorted(jobs) == sorted(want), f"the operator Jobs are {sorted(jobs)}, not {sorted(want)}")
    for name, (before, args, password) in want.items():
        job = jobs.get(name)
        if not job:
            continue
        check("helm.sh/hook" not in (job["metadata"].get("annotations") or {}), f"{name} is a hook")
        pod = job["spec"]["template"]["spec"]
        check(pod.get("restartPolicy") == "OnFailure", f"{name}: restartPolicy {pod.get('restartPolicy')}")
        init = pod.get("initContainers") or []
        check([c["name"] for c in init] == ["migrate"] + [step for step, _ in before],
              f"{name}: the init containers are {[c['name'] for c in init]}")
        check(init and init[0].get("command") == ["/app/bin/igrant-api", "migrate", CONFIG], f"{name}: the migrate container runs {init[0].get('command') if init else None}")
        for container, (step, step_args) in zip(init[1:], before):
            check(container.get("command") == ["/app/bin/igrant-api"] and container.get("args") == step_args,
                  f"{name}: the init container {step} runs {container.get('args')}")
        containers = pod.get("containers") or []
        check(len(containers) == 1 and containers[0].get("command") == ["/app/bin/igrant-api"], f"{name}: the containers are {[c.get('command') for c in containers]}")
        check(containers and containers[0].get("args") == args, f"{name}: the arguments are {containers[0].get('args') if containers else None}")
        # The password: only as a file from its Secret, at the fixed path.
        volumes = {v["name"]: v for v in pod.get("volumes") or []}
        mounts = {m["name"]: m for m in (containers[0].get("volumeMounts") if containers else None) or []}
        if password:
            secret = (volumes.get("onboard-password") or {}).get("secret") or {}
            check(secret.get("secretName") == password[0] and secret.get("items") == [{"key": password[1], "path": "password"}],
                  f"{name}: the password volume is {secret}")
            mount = mounts.get("onboard-password") or {}
            check(mount.get("mountPath") == "/run/secrets/onboard" and mount.get("readOnly") is True, f"{name}: the password mount is {mount}")
        else:
            check("onboard-password" not in volumes and "onboard-password" not in mounts, f"{name} mounts a password")
        for container in init + containers:
            check(not container.get("env") and not container.get("envFrom"), f"{name}: the container {container['name']} has environment variables")
            for argument in container.get("args") or []:
                check("password" not in argument.lower() or argument == PASSWORD_FILE, f"{name}: the argument {argument.split('=')[0]} names a password")
    # No ConfigMap names the operator command or its password file.
    for doc in docs:
        if doc.get("kind") == "ConfigMap":
            for key, value in (doc.get("data") or {}).items():
                check("bootstrap-platform" not in str(value) and "/run/secrets/onboard" not in str(value),
                      f"the ConfigMap {doc['metadata']['name']} ({key}) names the operator command or its password file")
    if failures:
        print(f"{path} ({case}):")
        for failure in failures:
            print(f"  {failure}")
        return 1
    print(json.dumps({"case": case, "jobs": sorted(jobs)}))
    return 0


if __name__ == "__main__":
    sys.exit(main())
