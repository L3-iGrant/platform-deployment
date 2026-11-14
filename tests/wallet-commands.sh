#!/usr/bin/env bash
# Tests the commands of the wallet image. Each wallet container and Job of
# the chart (rendered with the operator Jobs) and each wallet service of
# docker-compose/ must be a full command that runs in the image, which has
# no shell and no entrypoint script (distroless, ENTRYPOINT []).
#
# For each command:
# 1. the command is explicit, and its program is an absolute path under
#    /app/.venv/bin (never a shell, never only arguments for an entrypoint);
# 2. the program starts in a container of the image, run as the pod runs it:
#    user 65532, a read-only root file system, no capabilities, no new
#    privileges, no network, /tmp in memory, and the rendered configuration
#    file at its path. Without a database or a secret file, the program then
#    stops with its own error (or still waits after 25 s): that is a pass. A
#    failure is a program that the runtime cannot start (exit 126 or 127,
#    "executable file not found", "no such file"), or a Python import error.
#
# Usage: tests/wallet-commands.sh <wallet image>
#   The image must be local (the script never pulls).
set -euo pipefail

image="${1:?usage: tests/wallet-commands.sh <wallet image>}"
here="$(cd "$(dirname "$0")" && pwd)"
chart="$(dirname "$here")"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
pass=0
fail=0
ok() { pass=$((pass + 1)); echo "ok   $1"; }
bad() { fail=$((fail + 1)); echo "FAIL $1"; }

# The wallet commands of the chart and of Compose, one JSON line each (where,
# command, environment, configuration file and its path).
values=(-f "$here/values/keys.yaml" -f "$chart/profiles/site.yaml" -f "$here/values/release.yaml" -f "$chart/profiles/consent.yaml" -f "$here/values/operator-jobs-bootstrap.yaml")
for extra in hsm-signer-local.yaml hsm-signer-dpod.yaml; do
  [ -f "$chart/profiles/$extra" ] && values+=(-f "$chart/profiles/$extra")
done
helm template t "$chart" --namespace ow "${values[@]}" > "$work/render.yaml"
# A copy of docker-compose/ with the example .env and the files that make
# configs writes (the services read their configuration files from generated/),
# with consent (CONSENT_ENABLED=true), so wallet-read-access-consent is there too.
compose="$work/docker-compose"
cp -R "$chart/docker-compose" "$compose"
rm -rf "$compose/generated" "$compose/secrets"
cp "$compose/.env.example" "$compose/.env"
(cd "$compose" && export CONSENT_ENABLED=true && python3 -I ./render-configs.py > /dev/null && HOST_UID=4242 HOST_GID=4243 docker compose config --format json) > "$work/compose.json"
python3 - "$work/render.yaml" "$work/compose.json" "$work" > "$work/commands.jsonl" <<'PY'
import json, os, sys, yaml
render, compose, work = sys.argv[1:4]
docs = [d for d in yaml.safe_load_all(open(render)) if isinstance(d, dict)]
config_maps = {d["metadata"]["name"]: d.get("data") or {} for d in docs if d.get("kind") == "ConfigMap"}
seen = set()
for doc in docs:
    if doc.get("kind") not in ("Deployment", "StatefulSet", "Job"):
        continue
    pod = doc["spec"]["template"]["spec"]
    volumes = {v["name"]: v for v in pod.get("volumes") or []}
    for group in ("initContainers", "containers"):
        for container in pod.get(group) or []:
            if "/eudi-wallet:" not in container["image"]:
                continue
            env = {e["name"]: e.get("value", "") for e in container.get("env") or [] if "value" in e}
            config_path = env.get("EUDI_WALLET_CONFIG", "/etc/eudi-wallet/config.yaml")
            # The rendered configuration file for this path.
            content = None
            for mount in container.get("volumeMounts") or []:
                volume = volumes.get(mount["name"], {})
                source = volume.get("configMap") or next((s.get("configMap") for s in (volume.get("projected") or {}).get("sources", []) if s.get("configMap")), None)
                if not source or not config_path.startswith(mount["mountPath"].rstrip("/") + "/"):
                    continue
                relative = config_path[len(mount["mountPath"].rstrip("/")) + 1:]
                data = config_maps.get(source["name"], {})
                key = next((i["key"] for i in source.get("items") or [] if i["path"] == relative), relative)
                content = data.get(key)
            file = None
            if content is not None:
                file = os.path.join(work, f"config-{len(seen)}.yaml")
                open(file, "w").write(content)
                os.chmod(file, 0o644)
            where = f"chart {doc['kind']}/{doc['metadata']['name']}:{container['name']}"
            line = json.dumps({"where": where, "command": (container.get("command") or []) + (container.get("args") or []),
                               "explicit": bool(container.get("command")), "env": env, "config": file, "config_path": config_path})
            if line not in seen:
                seen.add(line)
                print(line)
project = json.load(open(compose))
for name, service in sorted(project["services"].items()):
    if "/eudi-wallet:" not in service.get("image", ""):
        continue
    entrypoint = service.get("entrypoint") or []
    command = service.get("command") or []
    env = {k: v for k, v in (service.get("environment") or {}).items() if v is not None}
    print(json.dumps({"where": f"compose {name}", "command": entrypoint + command, "explicit": bool(entrypoint or command),
                      "env": env, "config": None, "config_path": env.get("EUDI_WALLET_CONFIG", "/etc/eudi-wallet/config.yaml")}))
PY
count="$(wc -l < "$work/commands.jsonl" | tr -d ' ')"
[ "$count" -ge 10 ] && ok "$count wallet commands in the chart and in Compose" || bad "only $count wallet commands"

while IFS= read -r line; do
  where="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["where"])' "$line")"
  mapfile -t command < <(python3 -c 'import json,sys; [print(a) for a in json.loads(sys.argv[1])["command"]]' "$line")
  explicit="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["explicit"])' "$line")"
  config="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["config"] or "")' "$line")"
  config_path="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["config_path"])' "$line")"
  if [ "$explicit" != True ] || [[ "${command[0]:-}" != /app/.venv/bin/* ]]; then
    bad "$where: not a full command under /app/.venv/bin: ${command[*]:-the image default}"
    continue
  fi
  run=(--rm --pull never --read-only --user 65532:65532 --cap-drop ALL --security-opt no-new-privileges:true --network none
    --tmpfs /tmp:size=64m -e "EUDI_WALLET_CONFIG=$config_path" --entrypoint "${command[0]}")
  [ -n "$config" ] && run+=(-v "$config:$config_path:ro")
  set +e
  output="$(timeout 25 docker run "${run[@]}" "$image" "${command[@]:1}" 2>&1)"
  status=$?
  set -e
  first="$(printf '%s' "$output" | grep -v '^\s*$' | tail -1 | cut -c1-110)"
  if [ "$status" = 126 ] || [ "$status" = 127 ] || grep -q -E "executable file not found|no such file or directory: unknown|exec format error" <<< "$output"; then
    bad "$where: the runtime cannot start ${command[0]} (exit $status): $first"
  elif grep -q -E "ModuleNotFoundError|ImportError" <<< "$output"; then
    bad "$where: ${command[0]} has an import error: $first"
  elif [ "$status" = 124 ]; then
    ok "$where: ${command[0]##*/} runs (still waiting after 25 s)"
  else
    ok "$where: ${command[0]##*/} starts and stops with its own message (exit $status): $first"
  fi
done < "$work/commands.jsonl"

echo "result: ${pass} passed, ${fail} failed"
[ "$fail" -eq 0 ]
