#!/usr/bin/env python3
"""The old values in values.schema.json (docs/upgrade.md).

values.schema.json closes its objects, so Helm would refuse an old value
with a general message before the chart can say what changed. This tool
keeps each old path of files/renamed-values.yaml in the schema, with
"deprecated": true and any type, so that the render reaches the stop of
templates/_renamed.tpl. When the path stays and only the type changes
(kind in the table), the tool adds the old JSON type to the "type" of the
new node and notes it in "x-old-type": the rules of the new type still
give their own messages, and a value of the old type reaches the stop.
For an old word of a value (values in the table), the enum of the node
has the old words, noted in "x-old-values".

Usage (from the chart folder):
  python3 tests/renamed_schema.py --write   add the missing entries
  python3 tests/renamed_schema.py --check   exit 1 when the schema and the
                                            table are different
--check also refuses a deprecated schema entry that is in no table entry
(remove both together, two releases after the change).
"""
import json
import os
import sys

import yaml

CHART = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCHEMA = os.path.join(CHART, "values.schema.json")
TABLE = os.path.join(CHART, "files", "renamed-values.yaml")
JSON_TYPES = {"string": "string", "bool": "boolean", "slice": "array", "map": "object", "float64": "number"}


def object_branch(node):
    """The object schema of a node (also inside an anyOf of an old type)."""
    for branch in node.get("anyOf", []):
        if branch.get("type") == "object" or "properties" in branch:
            return branch
    return node


def expected(table):
    """The deprecated paths that the schema must have: each old path, and
    each parent object that only old paths have. Output: dict path ->
    (the JSON type of the old value at a path that stays, or None; the old
    words, or None)."""
    out = {}
    for entry in table:
        old_type = JSON_TYPES[entry["kind"]] if entry.get("kind") else None
        old_values = sorted(entry["values"]) if entry.get("values") and not entry.get("new") else None
        out[entry["old"]] = (old_type, old_values)
    return out


def apply(schema, table, write):
    problems = []
    wanted = expected(table)
    for path, (old_type, old_values) in wanted.items():
        parts = path.split(".")
        node = schema
        for depth, part in enumerate(parts):
            node = object_branch(node)
            properties = node.setdefault("properties", {}) if write else node.get("properties", {})
            last = depth == len(parts) - 1
            if part not in properties:
                if not write:
                    problems.append(f"{path}: not in values.schema.json (run tests/renamed_schema.py --write)")
                    break
                if last:
                    properties[part] = {"deprecated": True}
                else:
                    properties[part] = {"type": "object", "additionalProperties": False, "deprecated": True, "properties": {}}
            child = properties[part]
            if last and old_type and not child.get("deprecated"):
                types = child.get("type")
                types = types if isinstance(types, list) else ([types] if types else [])
                if old_type not in types or child.get("x-old-type") != old_type:
                    if not write:
                        problems.append(f"{path}: values.schema.json does not accept the old type {old_type} (run tests/renamed_schema.py --write)")
                    else:
                        if old_type not in types:
                            child["type"] = types + [old_type]
                        child["x-old-type"] = old_type
            if last and old_values and not child.get("deprecated"):
                enum = child.get("enum")
                if enum is not None and not all(v in enum for v in old_values):
                    if not write:
                        problems.append(f"{path}: the enum of values.schema.json does not have the old words {old_values} (run tests/renamed_schema.py --write)")
                    else:
                        child["enum"] = enum + [v for v in old_values if v not in enum]
                if enum is not None or write:
                    if child.get("x-old-values") != old_values:
                        if not write:
                            problems.append(f"{path}: values.schema.json has no x-old-values {old_values} (run tests/renamed_schema.py --write)")
                        else:
                            child["x-old-values"] = old_values
            node = child
    # A deprecated entry that is in no table entry.
    def walk(node, prefix):
        node = object_branch(node)
        for key, child in node.get("properties", {}).items():
            path = f"{prefix}.{key}" if prefix else key
            if child.get("deprecated") or child.get("x-old-type") or child.get("x-old-values"):
                if path not in wanted and not any(p.startswith(path + ".") for p in wanted):
                    problems.append(f"{path}: deprecated in values.schema.json, but not in files/renamed-values.yaml")
            walk(child, path)
    walk(schema, "")
    return problems


def main(argv):
    if len(argv) != 2 or argv[1] not in ("--write", "--check"):
        sys.stderr.write(__doc__)
        return 2
    with open(TABLE) as handle:
        table = yaml.safe_load(handle) or []
    with open(SCHEMA) as handle:
        schema = json.load(handle)
    write = argv[1] == "--write"
    problems = apply(schema, table, write)
    if write:
        with open(SCHEMA, "w") as handle:
            handle.write(json.dumps(schema, indent=2) + "\n")
        problems = apply(schema, table, False)
    for problem in problems:
        print(problem)
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
