#!/usr/bin/env python3
"""Checks the relative links of the chart documentation.

Usage: check_links.py <file.md> [<file.md> ...]

For each link [text](target) that is not a URL (http, https, mailto), the
target file or folder must exist (relative to the folder of the file), and
an anchor (#name) must be the name of a heading of the target file, as
GitHub makes it. The script writes one line per broken link and exits 1
when a link is broken.
"""

import os
import re
import sys

LINK = re.compile(r"(?<!!)\[[^\]]*\]\(([^)\s]+)\)")
HEADING = re.compile(r"^(#{1,6})\s+(.*?)\s*#*\s*$")
FENCE = re.compile(r"^\s*(```|~~~)")


def lines_outside_code(path):
    """The lines of a Markdown file, without the fenced code blocks."""
    fenced = False
    with open(path, encoding="utf-8") as file:
        for number, line in enumerate(file, 1):
            if FENCE.match(line):
                fenced = not fenced
                continue
            if not fenced:
                yield number, line


def slug(text):
    """The anchor name that GitHub gives a heading."""
    text = re.sub(r"\[([^\]]*)\]\([^)]*\)", r"\1", text)  # a link: its text
    text = text.strip().lower()
    text = re.sub(r"[^\w\- ]", "", text)
    return text.replace(" ", "-")


def anchors(path):
    names = set()
    counts = {}
    for _, line in lines_outside_code(path):
        match = HEADING.match(line)
        if not match:
            continue
        name = slug(match.group(2))
        count = counts.get(name, 0)
        counts[name] = count + 1
        names.add(name if count == 0 else f"{name}-{count}")
    return names


def main(paths):
    broken = 0
    cache = {}
    for path in paths:
        for number, line in lines_outside_code(path):
            # Inline code is not a link.
            for target in LINK.findall(re.sub(r"`[^`]*`", "", line)):
                if re.match(r"^(https?|mailto):", target):
                    continue
                file_part, _, anchor = target.partition("#")
                target_path = (
                    os.path.normpath(os.path.join(os.path.dirname(path), file_part))
                    if file_part
                    else path
                )
                if not os.path.exists(target_path):
                    print(f"{path}:{number}: {target}: no file {target_path}")
                    broken += 1
                    continue
                if not anchor:
                    continue
                if not target_path.endswith(".md"):
                    print(f"{path}:{number}: {target}: an anchor in a file that is not Markdown")
                    broken += 1
                    continue
                if target_path not in cache:
                    cache[target_path] = anchors(target_path)
                if anchor not in cache[target_path]:
                    print(f"{path}:{number}: {target}: no heading #{anchor} in {target_path}")
                    broken += 1
    return 1 if broken else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
