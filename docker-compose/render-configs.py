#!/usr/bin/env python3
"""make configs: writes the components' configuration files to generated/.

Usage: python3 -I render-configs.py [--check | --print]

Compose fills the templates in compose.configs.yaml with the values of
.env. This script reads the result with "docker compose -f
compose.render.yaml --profile render config --format json", which uses the
same values files as docker-compose.yaml and the same rules
(${VAR:-default}, ${VAR:?message}, ${VAR:+value}, $$). So Compose stays
the platform's only template engine. The script writes:

- generated/<name> for each template <name> (mode 0644, because the
  services read the files as "file" configs, as non-root users);
- generated/configs.env: CONFIG_SHA256_<NAME>=<SHA-256 of the file> for
  each file. Each service has its file's hash in a label, so "docker
  compose up" restarts the service when its file changes.

Each file is written to a temporary file in generated/ and then renamed,
so a stop at any point leaves every file complete (the old or the new
version). configs.env is written last. A run after a stop writes all files
again. Files in generated/ that are not templates are removed.

--check: write nothing; exit 1 when generated/ is not the render of the
current values (for example after a change to .env without make configs).
--print: write nothing; print the files as JSON (name: text), for the
tests (tests/compose-files.sh).

The templates hold no secret values (the configurations name secret
files), so the files in generated/ hold no secrets. "docker compose
config" escapes each $ in a value as $$; the script writes $. Needs Docker
Compose 2.24 or later and Python 3.8 or later (standard library only).
"""

import hashlib
import json
import os
import re
import shlex
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "generated")
HASHES = "configs.env"
NAME = re.compile(r"^[a-z0-9][a-z0-9-]*\.(yaml|json)$")


def fail(message: str) -> None:
    print(f"configs: ERROR: {message}", file=sys.stderr)
    sys.exit(1)


def variable(name: str) -> str:
    """Name of the hash variable of the file <name>: CONFIG_SHA256_<NAME>."""
    return "CONFIG_SHA256_" + re.sub(r"[^A-Z0-9]", "_", name.rsplit(".", 1)[0].upper())


def render() -> dict:
    """The files (name: bytes) rendered from the templates with the values from Compose."""
    compose = shlex.split(os.environ.get("COMPOSE") or "docker compose")
    command = compose + ["-f", os.path.join(HERE, "compose.render.yaml"), "--profile", "render", "config", "--format", "json"]
    result = subprocess.run(command, cwd=HERE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, universal_newlines=True)
    if result.returncode != 0:
        fail(f"docker compose config of the templates: {result.stderr.strip()}")
    project = json.loads(result.stdout)
    used = {entry["source"] for entry in project["services"]["render"].get("configs") or []}
    files = {}
    for name, config in sorted((project.get("configs") or {}).items()):
        if not NAME.match(name):
            fail(f"the template name {name!r} is not <name>.yaml or <name>.json")
        if "content" not in config:
            fail(f"the template {name} has no content")
        if name not in used:
            fail(f"the service render does not name the template {name}")
        files[name] = config["content"].replace("$$", "$").encode("utf-8")
    if not files:
        fail("no template")
    return files


def hashes_of(files: dict) -> bytes:
    lines = [f"{variable(name)}={hashlib.sha256(data).hexdigest()}" for name, data in sorted(files.items())]
    header = "# Written by make configs (render-configs.py): the SHA-256 of each file of\n# generated/. Do not change it.\n"
    return (header + "\n".join(lines) + "\n").encode("utf-8")


def write(path: str, data: bytes) -> None:
    """Write data to path atomically: a temporary file in the same folder, then a rename."""
    handle, temporary = tempfile.mkstemp(dir=os.path.dirname(path), prefix=".render-")
    try:
        with os.fdopen(handle, "wb") as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        os.chmod(temporary, 0o644)
        os.replace(temporary, path)
    except BaseException:
        if os.path.exists(temporary):
            os.unlink(temporary)
        raise


def main() -> int:
    mode = sys.argv[1] if len(sys.argv) == 2 else ""
    if len(sys.argv) > 2 or mode not in ("", "--check", "--print"):
        print(__doc__.strip().splitlines()[2], file=sys.stderr)
        return 2
    check = mode == "--check"
    files = render()
    if mode == "--print":
        json.dump({name: data.decode("utf-8") for name, data in files.items()}, sys.stdout, indent=1, sort_keys=True)
        print()
        return 0
    wanted = dict(files)
    wanted[HASHES] = hashes_of(files)
    if check:
        stale = []
        for name, data in sorted(wanted.items()):
            path = os.path.join(OUT, name)
            if not os.path.isfile(path) or open(path, "rb").read() != data:
                stale.append(name)
        extra = sorted(set(os.listdir(OUT)) - set(wanted)) if os.path.isdir(OUT) else []
        if stale or extra:
            print("configs: generated/ is not the render of the current values: " + ", ".join(stale + extra), file=sys.stderr)
            return 1
        print(f"configs: generated/ is the render of the current values ({len(files)} files)")
        return 0
    os.makedirs(OUT, exist_ok=True)
    os.chmod(OUT, 0o755)
    for name, data in sorted(files.items()):
        write(os.path.join(OUT, name), data)
    for name in sorted(set(os.listdir(OUT)) - set(wanted)):
        path = os.path.join(OUT, name)
        if os.path.isfile(path) or os.path.islink(path):
            os.unlink(path)
    write(os.path.join(OUT, HASHES), wanted[HASHES])
    print(f"configs: wrote {len(files)} files and {HASHES} to generated/ (no secret value in them)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
