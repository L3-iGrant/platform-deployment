# iGrant.io platform deployment

This repository holds the Helm chart and the Docker Compose files that install the iGrant.io platform. With the platform, an organisation issues, holds and verifies verifiable credentials under eIDAS 2.0 (OpenID4VCI, OpenID4VP and the EU Architecture and Reference Framework).

The Helm chart installs the platform on Kubernetes, with the services that it depends on: a database server (or it uses yours), NATS, OpenBao (or it uses yours) and Valkey with Sentinel (or it uses your Valkey or Redis). Your cluster provides the ingress controller or Gateway, the certificates and the monitoring.

The name of the Helm chart is `platform`. A release that was installed from the chart `organisationwallet` sets `nameOverride: organisationwallet` before its next upgrade: see [The chart name platform](docs/upgrade.md#the-chart-name-platform).

This is the community installation of the platform: use it for development, tests and evaluation, and as the reference architecture and setup. For production, use the enterprise installation: the enterprise Helm chart and its installation guide, with your HSM, the automatic unseal of OpenBao, high availability and sizing for your load. iGrant.io gives access on request: contact support@igrant.io.

This documentation is for the developers and IT operations teams who install and run the platform, and for the architects and CIOs who plan an installation. To run the platform on a single Docker host, use the [Docker Compose files](docker-compose/README.md).

## Contents

### Get started

- [Components](docs/components.md): what the chart installs, how your values files describe an installation, and an installation without consent or without the organisation wallet.
- [Prerequisites](docs/prerequisites.md): what your cluster, your network and your workstation need.
- [Install](docs/install.md): the installation in seven steps, each with a check.

### Operate

- [Upgrade](docs/upgrade.md): move an installation to a new release.
- [Uninstall](docs/uninstall.md): remove the platform, see what stays, and install again with or without the data.
- [Scaled deployments](docs/scaled-deployments.md): disruption budgets, pod spread, Google Cloud KMS auto-unseal and HSM signer groups for large installations.

### Configure

- [Exposure](docs/exposure.md): the three hosts, the hosts that are public on premise (only the wallet host), and the settings of your ingress controller or Gateway.
- [Database](docs/database.md): PostgreSQL for the whole platform, on a bundled or an external server, the database roles and hooks of the wallet, and the logs of the server.
- [Audit log](docs/audit-log.md): the audit log of the wallet, its write-once bucket, the check of the log, and the retention purge of the wallet data.
- [Workers and clock](docs/workers.md): the background work of the wallet: the worker groups and their queues, the clock, the stops, the probes and the metrics.
- [OpenBao](docs/openbao.md): the bundled OpenBao and its Shamir seal, or your own OpenBao.
- [Redis](docs/redis.md): Valkey with Sentinel for the work queue, the single-use values and the caches of the wallet, or your own Valkey or Redis.
- [Key stores](docs/key-stores.md): the local key store, and the key stores that organisations can add.
- [Network policies](docs/network-policies.md): limit the traffic between the components.
- [Security settings of the containers](docs/security-context.md): the non-root user, the writable paths and the sysctls of each container, and the Pod Security Standard `restricted`.
- [Values reference](docs/values-reference.md): the main values and their defaults.

### Keys and HSM

- [Connect your on-premise HSM](docs/on-premise-hsm.md): use a Thales Luna Network HSM for the OpenBao seal and for the local keys of the organisations.
- [Thales Luna Cloud HSM (DPoD)](docs/dpod.md): use a DPoD partition for the same purposes.
- [DPoD key stores](docs/dpod-key-stores.md): let organisations use their own DPoD partitions.
- [Keys](docs/keys.md): the keys of the platform and the Secrets that hold them.

### Reference

- [Chart objects](docs/chart-objects.md): the objects that the chart creates for OpenBao.
- [NATS users](docs/nats-users.md): the NATS users of the processes, and an external NATS server.
- [Read access](docs/read-access.md): the read-only database users of the services.
- [Privacy dashboard](docs/privacy-dashboard.md): the status of this feature in the chart.
- [Tests](docs/tests.md): the tests of the chart, which run without a cluster.
- [Images](docs/images.md): the images of the chart, for your own mirror.

## Licence

Copyright (c) 2026 iGrant Technologies AB (iGrant.io), Sweden

Licensed under the Apache License 2.0. You may not use this file except in compliance with the licence. Unless required by applicable law or agreed to in writing, software distributed under the licence is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the [LICENSE](LICENSE) file for the specific language governing permissions and limitations under the licence. The chart runs software of other projects under their own licences: see [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md).
