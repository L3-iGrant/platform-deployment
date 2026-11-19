#!/usr/bin/env python3
"""Write a new values file for this chart from a values file of an earlier
release (docs/upgrade.md).

The script reads the table files/renamed-values.yaml of the chart: the same
table that stops the render when a values file has an old value
(templates/_renamed.tpl). It moves each old value to its new path, removes
the values that are not values any more, and writes the new values file to
standard output. The report goes to standard error: each change, and what
you must do yourself (for example make a Secret for a plain password). The
new file has no comments: compare it with your old file.

Usage:
  scripts/upgrade-values.py <values file> > <new values file>
Run it on each values file of your installation (each -f of helm).

Exit code: 0 when the new file needs nothing more from you, 1 when the
report has an action for you, 2 for a usage error.
Needs Python 3.9 or later and PyYAML (pip install pyyaml).
"""
import copy
import os
import sys

try:
    import yaml
except ImportError:
    sys.stderr.write("upgrade-values: needs PyYAML (pip install pyyaml)\n")
    sys.exit(2)

CHART = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MISSING = object()


def go_text(value):
    """The text of a value as Helm prints it (toString): true, not True."""
    if isinstance(value, bool):
        return "true" if value else "false"
    if value is None:
        return "<nil>"
    return str(value)


def kind_of(value):
    """The Go kind of a YAML value, as kindIs of the template sees it."""
    if isinstance(value, bool):
        return "bool"
    if isinstance(value, str):
        return "string"
    if isinstance(value, list):
        return "slice"
    if isinstance(value, dict):
        return "map"
    if isinstance(value, (int, float)):
        return "float64"
    return "invalid"


def get(data, path):
    node = data
    for part in path.split("."):
        if not isinstance(node, dict) or part not in node:
            return MISSING
        node = node[part]
    return node


def delete(data, path):
    """Removes the value at path, and each parent that is then empty."""
    parts = path.split(".")
    chain = [data]
    for part in parts[:-1]:
        chain.append(chain[-1][part])
    del chain[-1][parts[-1]]
    for depth in range(len(parts) - 1, 0, -1):
        if chain[depth] == {}:
            del chain[depth - 1][parts[depth - 1]]
        else:
            break


class Report:
    def __init__(self):
        self.lines = []
        self.actions = 0

    def change(self, text):
        self.lines.append("  changed: " + text)

    def note(self, text):
        self.lines.append("  note:    " + text)

    def action(self, text):
        self.actions += 1
        self.lines.append("  ACTION:  " + text)


def put(data, path, value, report, source):
    """Sets the value at path. A different value there is a conflict."""
    parts = path.split(".")
    node = data
    for part in parts[:-1]:
        if not isinstance(node.get(part), dict):
            if part in node and node[part] is not None:
                report.action(f"{source}: {path} has a value of another type in your file; set {path} by hand")
                return
            node[part] = {}
        node = node[part]
    last = parts[-1]
    if last in node and node[last] != value:
        report.action(f"{source}: {path} already has another value in your file ({go_text(node[last])}); keep one value and set {path} by hand")
        return
    node[last] = copy.deepcopy(value)


def convert_worker_groups(data, entry, value, report, defaults):
    """organisationWallet.workers.groups: a list becomes a map with the group
    name as key. The default groups that the list did not have get null (a
    list replaced all default groups; a map keeps each default group that
    your file does not name)."""
    groups = {}
    for group in value or []:
        group = copy.deepcopy(group)
        name = group.pop("name", None)
        if not name:
            report.action("organisationWallet.workers.groups: a group without a name; add it to the map by hand")
            continue
        if "terminationGracePeriodSeconds" in group:
            group.pop("terminationGracePeriodSeconds")
            report.change(f"organisationWallet.workers.groups.{name}.terminationGracePeriodSeconds removed (the chart calculates it from shutdownTimeoutSeconds)")
        scaling = group.get("autoscaling")
        if isinstance(scaling, dict) and "keda" in scaling:
            keda = scaling.pop("keda") or {}
            names = {"minReplicaCount": "minReplicas", "maxReplicaCount": "maxReplicas"}
            for key, item in keda.items():
                scaling[names.get(key, key)] = item
            report.change(f"organisationWallet.workers.groups.{name}.autoscaling.keda is now organisationWallet.workers.groups.{name}.autoscaling (minReplicas, maxReplicas)")
        groups[name] = group
    default_groups = get(defaults, "organisationWallet.workers.groups")
    if isinstance(default_groups, dict):
        for name in default_groups:
            if name not in groups:
                groups[name] = None
                report.change(f"organisationWallet.workers.groups.{name}: null (your list did not have this default group)")
    put(data, "organisationWallet.workers.groups", groups, report, entry["old"])
    report.change("organisationWallet.workers.groups is now a map with the group name as key")


def convert_database_secret(data, entry, value, report, defaults):
    """database.auth.existingSecret: one Secret with one key for each
    database name and, for the bundled server, POSTGRES_PASSWORD."""
    for key in (get(defaults, "database.databases") or {}):
        name = get(data, f"database.databases.{key}.name")
        if name is MISSING:
            name = get(defaults, f"database.databases.{key}.name")
        put(data, f"database.databases.{key}.password", {"existingSecret": value, "key": name}, report, entry["old"])
        report.change(f"database.auth.existingSecret is now database.databases.{key}.password (existingSecret {value}, key {name})")
    if get(data, "database.mode") in (MISSING, "bundled"):
        put(data, "database.admin.password", {"existingSecret": value, "key": "POSTGRES_PASSWORD"}, report, entry["old"])
        report.change(f"database.auth.existingSecret is now database.admin.password (existingSecret {value}, key POSTGRES_PASSWORD)")


def convert_public_jwks_config_map(data, entry, value, report, defaults):
    """The ConfigMaps of the public JWKS are now one ConfigMap."""
    target = "keys.publicJwks.existingConfigMap"
    earlier = get(data, target)
    if earlier is not MISSING and earlier != value:
        report.action(f"{entry['old']} ({value}) and an earlier ConfigMap ({earlier}): the chart now reads all public JWKS from one ConfigMap {target}, with the keys gateway-jwks.json, token-verification-jwks.json, igrant-api.json and eudi-wallet.json. Make that ConfigMap and set {target}")
        return
    put(data, target, value, report, entry["old"])
    report.change(f"{entry['old']} is now {target} (one ConfigMap with the keys gateway-jwks.json, token-verification-jwks.json, igrant-api.json and eudi-wallet.json)")


def convert_limit(data, entry, value, report, defaults):
    """An installation limit: an empty text was the default of the service
    (100), now the default of the chart; a number moves as it is."""
    if value in ("", None):
        report.change(f"{entry['old']} removed (it was empty: the default {get(defaults, entry['new'])})")
        return
    try:
        number = int(value)
    except (TypeError, ValueError):
        report.action(f"{entry['old']} {value!r} is not a number: set {entry['new']} (1 to 100) by hand")
        return
    put(data, entry["new"], number, report, entry["old"])
    report.change(f"{entry['old']} is now {entry['new']}")


def convert_ssrf_switch(data, entry, value, report, defaults):
    """The SSRF switch of the api (ssrfProtectionDisabled: true is off) or
    of the wallet (ssrf_protection.enabled: false is off) is now one switch
    for both: outboundHttp.ssrfProtection.enabled."""
    off = (value is True) if entry["old"].endswith("ssrfProtectionDisabled") else (value is False)
    if not off:
        report.change(f"{entry['old']} removed (the guard is on: the default)")
        return
    put(data, "outboundHttp.ssrfProtection.enabled", False, report, entry["old"])
    report.note(f"{entry['old']} is now outboundHttp.ssrfProtection.enabled: false, which turns off the SSRF guards of the api and of the wallet")


CONVERSIONS = {
    "ssrfSwitch": convert_ssrf_switch,
    "limit": convert_limit,
    "workerGroups": convert_worker_groups,
    "databaseSecret": convert_database_secret,
    "publicJwksConfigMap": convert_public_jwks_config_map,
}


def matches(entry, value):
    if value is MISSING:
        return False
    if entry.get("kind") and kind_of(value) != entry["kind"]:
        return False
    if entry.get("values") and go_text(value) not in entry["values"]:
        return False
    return True


def upgrade(data, table, defaults, report):
    # The deepest paths first: an old value below another old value (a key
    # in the old extra configuration) changes before its parent moves.
    for entry in sorted(table, key=lambda e: -e["old"].count(".")):
        old = entry["old"]
        value = get(data, old)
        if not matches(entry, value):
            continue
        delete(data, old)
        if entry.get("convert"):
            CONVERSIONS[entry["convert"]](data, entry, value, report, defaults)
            continue
        if entry.get("values"):
            target = entry.get("new") or old
            put(data, target, entry["values"][go_text(value)], report, old)
            report.change(f"{old} {go_text(value)} is now {target} {go_text(entry['values'][go_text(value)])}")
            continue
        if entry.get("new"):
            targets = entry["new"] if isinstance(entry["new"], list) else [entry["new"]]
            for target in targets:
                put(data, target, value, report, old)
            report.change(f"{old} is now {' and '.join(targets)}")
            if entry.get("note"):
                report.note(f"{old}: {entry['note']}")
            continue
        empty = value in ("", None, [], {})
        if entry.get("secret") is True and not empty:
            report.action(f"{old}: a plain secret is not permitted in a values file. {entry['shape']}")
        elif entry.get("secret") == "kept" and not empty:
            report.note(f"{old} removed: {entry.get('removed') or entry.get('shape')}")
        elif entry.get("removed"):
            report.change(f"{old} removed ({entry['removed']})")
        elif not empty:
            report.action(f"{old}: {entry['shape']}")
        else:
            report.change(f"{old} removed (it was empty)")


def main(argv):
    if len(argv) != 2 or argv[1] in ("-h", "--help"):
        sys.stderr.write(__doc__)
        return 2
    with open(os.path.join(CHART, "files", "renamed-values.yaml")) as handle:
        table = yaml.safe_load(handle) or []
    with open(os.path.join(CHART, "values.yaml")) as handle:
        defaults = yaml.safe_load(handle)
    try:
        with open(argv[1]) as handle:
            data = yaml.safe_load(handle)
    except OSError as error:
        sys.stderr.write(f"upgrade-values: {error}\n")
        return 2
    if data is None:
        data = {}
    if not isinstance(data, dict):
        sys.stderr.write(f"upgrade-values: {argv[1]} is not a values file (a YAML map)\n")
        return 2
    report = Report()
    upgrade(data, table, defaults, report)
    if data:
        sys.stdout.write(yaml.safe_dump(data, sort_keys=False, default_flow_style=False, allow_unicode=True, width=120))
    sys.stderr.write(f"upgrade-values: {argv[1]}\n")
    if report.lines:
        sys.stderr.write("\n".join(report.lines) + "\n")
    else:
        sys.stderr.write("  no changed value\n")
    if report.actions:
        sys.stderr.write(f"upgrade-values: {report.actions} {'action' if report.actions == 1 else 'actions'} for you (ACTION above)\n")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
