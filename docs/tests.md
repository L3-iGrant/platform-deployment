# Tests

This page describes the tests of the chart. They run without a cluster.

[Back to the contents](../README.md#contents)

`tests/render-matrix.sh` checks the chart without a cluster:

- the text of the chart files and of the documentation (no em dash, British English, no name of other key store products), and the relative links of `README.md` and `docs/` (`tests/check_links.py`: each target file and each heading of an anchor exists);
- every combination of the examples (4 database files, 2 OpenBao files, 5 exposure files, with and without network policies): `helm template`, `kubeconform -strict` when it is installed, and `tests/check_render.py` (the engine, host, port and TLS of each configuration file, the server and the Jobs of the engine, the exposure objects, the OpenBao seal, the database port of the network policies);
- the render guards (wrong values stop the render with a clear message).

```bash
tests/render-matrix.sh            # or: tests/render-matrix.sh --keep /tmp/renders
```

`tests/compose-files.sh` checks the files of `docker-compose/` without a container: `docker compose config` for both engines, the configuration files of the components, the scripts, the NATS configuration, the same text rules and the relative links of its README.
