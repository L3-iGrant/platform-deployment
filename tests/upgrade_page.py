#!/usr/bin/env python3
"""The tables of docs/upgrade.md from files/renamed-values.yaml.

Each release has a section "From <release>" in docs/upgrade.md, with one
table for each group of the table file. A group starts with a comment line
"# --- <title>" in files/renamed-values.yaml; the next comment lines are the
text of the group.

Usage (from the chart folder):
  python3 tests/upgrade_page.py --write   write the sections
  python3 tests/upgrade_page.py --check   exit 1 when the page is different
"""
import os
import re
import sys

import yaml

CHART = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TABLE = os.path.join(CHART, "files", "renamed-values.yaml")
PAGE = os.path.join(CHART, "docs", "upgrade.md")
START = "<!-- The sections below: tests/upgrade_page.py --write (from files/renamed-values.yaml). -->"


def groups():
    """The groups of the table: [(title, text, [entries])], in order."""
    out = []
    title, text, lines = None, [], []

    def close():
        if title is not None:
            entries = yaml.safe_load("\n".join(lines)) or []
            out.append((title, " ".join(text), entries))

    for line in open(TABLE):
        line = line.rstrip("\n")
        if line.startswith("# --- "):
            close()
            title, text, lines = line[6:].strip(), [], []
        elif title is not None and line.startswith("#") and not lines:
            text.append(line.lstrip("#").strip())
        elif title is not None and not line.startswith("#"):
            lines.append(line)
    close()
    return out


def code(path):
    return f"`{path}`"


PATH = re.compile(r"(?<![`\w./<-])((?:[a-z][A-Za-z0-9]*\.)+[A-Za-z0-9<>-]*[A-Za-z0-9>])(?![`\w/])")


def prose(text):
    """Free text with each values path in code."""
    def wrap(match):
        path = match.group(1)
        if path.endswith((".md", ".yaml", ".json", ".io", ".org", ".sh", ".py")):
            return path
        return code(path)
    text = PATH.sub(wrap, text)
    # A name with a placeholder, for example <fullname>-api.
    return re.sub(r"(?<!`)(<[a-z]+>[A-Za-z0-9_.-]*)", lambda m: code(m.group(1)), text)


def action(entry):
    if entry.get("new"):
        targets = entry["new"] if isinstance(entry["new"], list) else [entry["new"]]
        text = " and ".join(code(t) for t in targets)
        if entry.get("values"):
            pairs = ", ".join(f"`{k}`: `{v}`" for k, v in entry["values"].items())
            text += f" ({pairs})"
    elif entry.get("values"):
        pairs = ", ".join(f"`{k}`: `{v}`" for k, v in entry["values"].items())
        text = f"The same value, with the new words ({pairs})"
    elif entry.get("removed"):
        text = "Remove it: " + prose(entry["removed"])
    else:
        text = prose(entry["shape"])
    if entry.get("note"):
        text += f" ({prose(entry['note'])})"
    return text[0].upper() + text[1:]


def sections():
    by_release = {}
    for title, text, entries in groups():
        for entry in entries:
            by_release.setdefault(str(entry["after"]), [])
        releases = sorted({str(e["after"]) for e in entries})
        for release in releases:
            rows = [e for e in entries if str(e["after"]) == release]
            by_release[release].append((title, text, rows))
    out = [START, ""]
    for release in sorted(by_release):
        out.append(f"## From {release}")
        out.append("")
        out.append(f"The values that changed after release {release}. `scripts/upgrade-values.py` does each change of these tables, except the actions in the report.")
        out.append("")
        for title, text, rows in by_release[release]:
            out.append(f"### {title}")
            out.append("")
            if text:
                out.append(text)
                out.append("")
            out.append("| Old value | New value, or what to do |")
            out.append("| --- | --- |")
            for entry in rows:
                old = code(entry["old"])
                if entry.get("kind"):
                    old += f" ({ {'string': 'a text', 'bool': 'true or false', 'slice': 'a list', 'map': 'a map', 'float64': 'a number'}[entry['kind']] })"
                out.append(f"| {old} | {action(entry)} |")
            out.append("")
    return "\n".join(out).rstrip("\n") + "\n"


def main(argv):
    if len(argv) != 2 or argv[1] not in ("--write", "--check"):
        sys.stderr.write(__doc__)
        return 2
    page = open(PAGE).read()
    head = page.split(START)[0].rstrip("\n") + "\n\n"
    new = head + sections()
    if argv[1] == "--write":
        open(PAGE, "w").write(new)
        return 0
    if new != page:
        print("docs/upgrade.md is not the same as files/renamed-values.yaml (run tests/upgrade_page.py --write)")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
