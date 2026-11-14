# iGrant.io platform deployment

This repository holds the Helm chart and the Docker Compose files of the iGrant.io platform. Organisations use the platform to issue, hold and verify verifiable credentials under eIDAS 2.0 (OpenID4VCI, OpenID4VP and the EU Architecture and Reference Framework).

The Helm chart installs the platform on Kubernetes, together with the services it depends on: a database server, NATS, OpenBao, and Valkey with Sentinel. You can use your own database server, your own OpenBao, and your own Valkey or Redis instead. Your cluster provides the ingress controller or Gateway, the certificates and the monitoring.

The Helm chart is called `platform`.

This is the community installation. Use it for development, testing and evaluation, and as the reference architecture. For production, use the enterprise installation: the enterprise Helm chart and its installation guide, with your HSM, automatic OpenBao unseal, high availability and sizing for your load. To get access, contact support@igrant.io.

These docs are for the developers and operations teams who install and run the platform, and for the architects and CIOs who plan an installation. To run the platform on a single Docker host, use the [Docker Compose files](docker-compose/README.md).

## Contents

### Get started

- [Components](docs/components.md): what the chart installs, how your values files describe an installation, and how to add consent or leave out the organisation wallet.
- [Prerequisites](docs/prerequisites.md): what your cluster, network and workstation need, and the Envoy Gateway setup of the default exposure (`manifests/envoy-gateway/`).
- [Get the charts](docs/install.md#get-the-charts): clone this repository, or the enterprise repository with your access token, and check out your release.
- [Install](docs/install.md): seven steps, each with a check.

### Operate

- [Upgrade](docs/upgrade.md): move an installation to a new release.
- [Uninstall](docs/uninstall.md): remove the platform, see what stays, and install again with or without the data.
- [Scaled deployments](docs/scaled-deployments.md): disruption budgets, pod spread, Google Cloud KMS auto-unseal and HSM signer groups for large installations.

### Configure

- [Exposure](docs/exposure.md): the three hosts, which host is public on premise (only the wallet host), and what your ingress controller or Gateway must do.
- [Database](docs/database.md): PostgreSQL for the whole platform (bundled or external), the wallet's database roles and hooks, and the server logs.
- [Audit log](docs/audit-log.md): the wallet's audit log, its write-once bucket, how to verify the log, and the retention purge of wallet data.
- [Workers and clock](docs/workers.md): the wallet's background work: worker groups and queues, the clock, shutdowns, probes and metrics.
- [OpenBao](docs/openbao.md): the bundled OpenBao with its Shamir seal, or your own OpenBao.
- [Redis](docs/redis.md): Valkey with Sentinel for the wallet's work queue, single-use values and caches, or your own Valkey or Redis.
- [Key stores](docs/key-stores.md): the local key store, and the key stores that organisations can add.
- [Network policies](docs/network-policies.md): limit the traffic between the components.
- [Security settings of the containers](docs/security-context.md): the non-root user, writable paths and sysctls of each container, and the Pod Security Standard `restricted`.
- [Values reference](docs/values-reference.md): every value and its default.

### Keys and HSM

- [Connect your on-premise HSM](docs/on-premise-hsm.md): use a Thales Luna Network HSM for the OpenBao seal and for the organisations' local keys.
- [Thales Luna Cloud HSM (DPoD)](docs/dpod.md): use a DPoD partition for the same purposes.
- [DPoD key stores](docs/dpod-key-stores.md): let organisations use their own DPoD partitions.
- [Keys](docs/keys.md): the platform keys and the Secrets that hold them.

### Reference

- [Chart objects](docs/chart-objects.md): the objects that the chart creates for OpenBao, Valkey, NATS and the wallet's workers and clock.
- [NATS users](docs/nats-users.md): the NATS user of each process, and how to use an external NATS server.
- [Read access](docs/read-access.md): the read-only database users of the services.
- [Privacy dashboard](docs/privacy-dashboard.md): the status of this feature in the chart.
- [Tests](docs/tests.md): the chart tests, which run without a cluster.
- [Images](docs/images.md): the chart's images, for your own mirror.

## Licence

Copyright (c) 2026 iGrant Technologies AB (iGrant.io), Sweden

Licensed under the Apache License 2.0. You may not use this file except in compliance with the licence. Unless required by applicable law or agreed to in writing, software distributed under the licence is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the [LICENSE](LICENSE) file for the specific language governing permissions and limitations under the licence. The chart runs software of other projects under their own licences: see [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md).
