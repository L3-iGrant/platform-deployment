#!/usr/bin/env python3
"""Tests of the stop for changed values (templates/_renamed.tpl).

1. values.schema.json has each old path of files/renamed-values.yaml
   (tests/renamed_schema.py --check), and docs/upgrade.md names each one.
2. One values file with every old value: the render stops with ONE message
   that names each old value with its new value or what to do.
3. Each old value alone: the render stops with the line of that value.
4. scripts/upgrade-values.py on the old values file of the tests
   (tests/values/old-values.yaml: values of release 2026.11.7, in the old
   shape) writes a file that renders the same objects as the same values in
   the new shape (tests/values/new-values.yaml), except the random values.
   Both renders also use tests/values/release.yaml and
   profiles/openbao-shamir.yaml.

Usage: python3 tests/check_renamed.py <helm values args of the base render>
Exit code 1 when a check fails.
"""
import json
import os
import re
import subprocess
import sys
import tempfile

import yaml

HERE = os.path.dirname(os.path.abspath(__file__))
CHART = os.path.dirname(HERE)
TABLE = os.path.join(CHART, "files", "renamed-values.yaml")

failures = []


def fail(text):
    failures.append(text)
    print(f"FAIL {text}")


def ok(text):
    print(f"ok   {text}")


def sample(entry):
    """A value of the old shape for one entry."""
    if entry.get("values"):
        first = next(iter(entry["values"]))
        if entry.get("kind") == "bool":
            return first == "true"
        return first
    kind = entry.get("kind")
    if kind == "slice":
        return [{"name": "old"}]
    if kind == "map":
        return {"old": "old"}
    if kind == "bool":
        return True
    if kind == "float64":
        return 1
    return "old"


def nest(values, path, value):
    parts = path.split(".")
    node = values
    for part in parts[:-1]:
        child = node.setdefault(part, {})
        if not isinstance(child, dict):
            return False
        node = child
    node[parts[-1]] = value
    return True


def render(base, files):
    args = ["helm", "template", "ows", CHART, "-n", "ows"] + base
    for path in files:
        args += ["-f", path]
    return subprocess.run(args, capture_output=True, text=True)


def documents(text):
    """The rendered objects, without the random values: Secret data, the
    checksums of the pods and the certificates."""
    out = {}
    for doc in yaml.safe_load_all(text):
        if not doc:
            continue
        if doc.get("kind") == "Secret":
            doc.pop("data", None)
        meta = doc.get("spec", {}).get("template", {}).get("metadata", {})
        annotations = meta.get("annotations") or {}
        for key in [k for k in annotations if k.startswith("checksum/")]:
            annotations.pop(key)
        name = f"{doc.get('kind')}/{doc.get('metadata', {}).get('name')}"
        out[name] = doc
    return out


def main(base):
    with open(TABLE) as handle:
        table = yaml.safe_load(handle) or []
    # 1. The schema and the upgrade page.
    check = subprocess.run([sys.executable, os.path.join(HERE, "renamed_schema.py"), "--check"], capture_output=True, text=True)
    if check.returncode:
        fail("renamed values: values.schema.json\n" + check.stdout)
    else:
        ok("renamed values: values.schema.json keeps each old path")
    page = subprocess.run([sys.executable, os.path.join(HERE, "upgrade_page.py"), "--check"], capture_output=True, text=True)
    if page.returncode:
        fail("renamed values: docs/upgrade.md\n" + page.stdout)
    else:
        ok("renamed values: the tables of docs/upgrade.md are the table of files/renamed-values.yaml")
    with open(os.path.join(CHART, "docs", "upgrade.md")) as handle:
        upgrade_page = handle.read()
    missing = [e["old"] for e in table if f"`{e['old']}`" not in upgrade_page]
    if missing:
        fail("renamed values: docs/upgrade.md does not name " + ", ".join(missing))
    else:
        ok("renamed values: docs/upgrade.md names each old value")
    with tempfile.TemporaryDirectory() as tmp:
        # 2. All old values in one file: one message.
        if table:
            values = {}
            for entry in table:
                if not nest(values, entry["old"], sample(entry)):
                    fail(f"renamed values: {entry['old']} is below another old value of the table")
            path = os.path.join(tmp, "all-old.yaml")
            with open(path, "w") as handle:
                yaml.safe_dump(values, handle)
            result = render(base, [path])
            message = result.stderr
            head = re.search(r"(\d+) values? of your values files changed after release", message)
            if result.returncode == 0 or not head:
                fail("renamed values: the render with all old values does not stop with the message of templates/_renamed.tpl:\n" + message[:2000])
            else:
                lines = [line for line in message.splitlines() if line.startswith("- ")]
                named = {line[2:].split(":", 1)[0] for line in lines}
                absent = [e["old"] for e in table if e["old"] not in named]
                if int(head.group(1)) != len(table) or absent:
                    fail(f"renamed values: the message names {head.group(1)} of {len(table)} old values; missing: {', '.join(absent)}")
                else:
                    ok(f"renamed values: one message names all {len(table)} old values")
        # 3. Each old value alone.
        alone = 0
        for entry in table:
            values = {}
            nest(values, entry["old"], sample(entry))
            path = os.path.join(tmp, "one-old.yaml")
            with open(path, "w") as handle:
                yaml.safe_dump(values, handle)
            result = render(base, [path])
            if result.returncode == 0 or f"\n- {entry['old']}: " not in result.stderr:
                fail(f"renamed values: {entry['old']} alone does not stop the render with its line:\n{result.stderr[:600]}")
            else:
                alone += 1
        if alone == len(table):
            ok(f"renamed values: each of {alone} old values alone stops the render")
        # 4. The upgrade script on the old values of the tests.
        old_file = os.path.join(HERE, "values", "old-values.yaml")
        if os.path.exists(old_file):
            new_path = os.path.join(tmp, "upgraded.yaml")
            run = subprocess.run([sys.executable, os.path.join(CHART, "scripts", "upgrade-values.py"), old_file], capture_output=True, text=True)
            if run.returncode not in (0, 1):
                fail("renamed values: scripts/upgrade-values.py failed:\n" + run.stderr)
            else:
                with open(new_path, "w") as handle:
                    handle.write(run.stdout)
                # The actions of the old file: the plain secrets (they need
                # a Secret). The new file of the tests has these Secrets.
                expected_actions = len(re.findall(r"ACTION", run.stderr))
                minimal = ["-f", os.path.join(HERE, "values", "release.yaml"), "-f", os.path.join(CHART, "profiles", "openbao-shamir.yaml")]
                upgraded = render(minimal, [new_path])
                new = render(minimal, [os.path.join(HERE, "values", "new-values.yaml")])
                if upgraded.returncode or new.returncode:
                    fail("renamed values: a render of the upgraded file or of tests/values/new-values.yaml failed:\n" + upgraded.stderr[:1500] + new.stderr[:1500])
                else:
                    a, b = documents(upgraded.stdout), documents(new.stdout)
                    diff = sorted(set(a) ^ set(b)) + sorted(k for k in set(a) & set(b) if a[k] != b[k])
                    if diff:
                        first = diff[0]
                        detail = ""
                        if first in a and first in b:
                            detail = "\n" + json.dumps(a[first], indent=1, sort_keys=True)[:1500] + "\n---\n" + json.dumps(b[first], indent=1, sort_keys=True)[:1500]
                        fail(f"renamed values: the upgraded old values render other objects than the new values: {', '.join(diff[:10])}{detail}")
                    else:
                        ok(f"renamed values: scripts/upgrade-values.py writes a file with the same render as the new values ({expected_actions} actions for the plain secrets)")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
