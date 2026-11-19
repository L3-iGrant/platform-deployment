# Upgrade

How to upgrade an installation to a new release of the chart, and the values that changed in each release.

[Back to the contents](../README.md#contents)

## The steps

1. Read the section of each release after the release of your installation (below).
2. Run `scripts/upgrade-values.py` on each values file of your installation (each `-f` of your `helm` commands). It needs Python 3.9 or later and PyYAML. It writes the new values file, and on the terminal a report:

   ```bash
   python3 ./platform-deployment/scripts/upgrade-values.py my-site.yaml > my-site.new.yaml
   ```

   The report lists each change, and each action for you (`ACTION`), for example a Secret to make. The exit code is 1 when the report has an action. The new file has no comments: compare it with your old file, then use the new file.
3. Render the release with the new files and compare the result with the installed release, for example with `helm template` and `kubectl diff`, or with the helm-diff plugin.
4. Run `helm upgrade` with the same files.

## When a values file has an old value

The render (`helm template`, `helm install`, `helm upgrade`, `helm lint`) stops when a values file has a value that changed. One message names all old values of your files, each with its new value or what to do, for example:

```text
Error: execution error at (platform/templates/zz-first/renamed-values.yaml:8:4): 2 values of your values files changed after release 2026.11.7 (docs/upgrade.md, section "From 2026.11.7"):
- api.keyStorage.tokenSigning.activeKid: use keys.apiTokenSigning.activeKid
- gateway.internalToken.issuer: remove it (the chart writes the constant igrant-gateway)
Run scripts/upgrade-values.py <your values file> to write the new file, or change the values by hand.
```

The chart never reads an old value in place of the new value. The message stays for two releases after the change. After that, the chart refuses the old value as an unknown value, with a general message of the schema.
