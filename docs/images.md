# Images

This page lists the images of the chart, for your own mirror.

[Back to the contents](../README.md#contents)

The images of iGrant.io come from the registry of iGrant.io (`global.imageRegistry`) with the release tag of your version (`global.imageTag`). The images of other projects come from Docker Hub (`docker.io`) with a fixed tag in `values.yaml`. Their licences are in [THIRD-PARTY-NOTICES.md](../THIRD-PARTY-NOTICES.md).

| Values key | Image | Tag | When |
| --- | --- | --- | --- |
| `api.image` | `api` (iGrant.io) | `global.imageTag` | always (the API core, the webhook handler and their Jobs) |
| `gateway.image` | `gateway` (iGrant.io) | `global.imageTag` | always |
| `consent.image` | `consent-management-backend` (iGrant.io) | `global.imageTag` | `consent.enabled` |
| `organisationWallet.image` | `eudi-wallet` (iGrant.io) | `global.imageTag` | `organisationWallet.enabled` |
| `enterpriseDashboard.image` | `dashboard` (iGrant.io) | `global.imageTag` | `enterpriseDashboard.enabled` |
| `openbao.image` | `openbao` (iGrant.io) | `global.imageTag` | `openbao.mode: bundled` |
| `database.postgresql.image` | `docker.io/library/postgres` | `18.6` | `database.mode: bundled` |
| `nats.image` | `docker.io/library/nats` | `2.12.3-alpine` | `nats.enabled` |
| `nats.reloader.image` | `docker.io/natsio/nats-server-config-reloader` | `0.21.1` | `nats.reloader.enabled` |
| `redis.image` | `docker.io/valkey/valkey` | `8.1.10-alpine`, with its digest | `redis.mode: bundled` |
| `redis.metrics.image` | `docker.io/oliver006/redis_exporter` | `v1.94.0`, with its digest | `redis.metrics.enabled` |

The chart runs each image as a non-root user with a read-only root file system (see [Security settings of the containers](security-context.md)). A mirror must keep the images as they are.

With your own mirror:

1. Copy each image with all its platforms and its digest, for example with skopeo:

   ```bash
   skopeo copy --all docker://docker.io/valkey/valkey:8.1.10-alpine \
     docker://registry.example.org/valkey/valkey:8.1.10-alpine
   ```

   Keep the licence text of each image of another project with the image (see [THIRD-PARTY-NOTICES.md](../THIRD-PARTY-NOTICES.md)).
2. Set `global.imageRegistry` for the images of iGrant.io, and `<values key>.registry` for each image of another project (for example `redis.image.registry: registry.example.org`). The images `redis.image` and `redis.metrics.image` have a digest: the chart uses `<repository>@<digest>`, so the copy must keep the digest (`skopeo copy --all` copies the image index as it is).
3. Set `global.imagePullSecrets` for your registry.
