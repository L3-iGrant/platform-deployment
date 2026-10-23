# Organisation Wallet Suite by iGrant.io: Helm chart

This Helm chart installs the Organisation Wallet Suite by iGrant.io on Kubernetes. With the suite, an organisation issues, holds and verifies verifiable credentials under eIDAS 2.0 (OpenID4VCI, OpenID4VP and the EU Architecture and Reference Framework).

The chart installs the platform and the services that it depends on: a database server (or it uses yours), NATS and OpenBao (or it uses yours). Your cluster provides the ingress controller or Gateway, the certificates and the monitoring.

This documentation is for the developers and IT operations teams who install and run the platform, and for the architects and CIOs who plan an installation. To run the suite on a single Docker host (development, tests or a small installation), use [Docker Compose](docker-compose/README.md).

## Contents

### Get started

- [Components](docs/components.md): what the chart installs, and how your values files describe an installation.
- [Prerequisites](docs/prerequisites.md): what your cluster, your network and your workstation need.
- [Install](docs/install.md): the installation in seven steps, each with a check.

### Operate

- [Upgrade](docs/upgrade.md): move an installation to a new release.
- [Uninstall](docs/uninstall.md): remove the platform, see what stays, and install again with or without the data.
- [Scaled deployments](docs/scaled-deployments.md): disruption budgets, pod spread, Google Cloud KMS auto-unseal and HSM signer groups for large installations.

### Configure

- [Exposure](docs/exposure.md): the three public hosts, and the settings of your ingress controller or Gateway.
- [Database](docs/database.md): one engine for the whole platform, on a bundled or an external server.
- [OpenBao](docs/openbao.md): the bundled OpenBao and its Shamir seal, or your own OpenBao.
- [Key stores](docs/key-stores.md): the local key store, and the key stores that organisations can add.
- [Network policies](docs/network-policies.md): limit the traffic between the components.
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

## Licence

Copyright (c) 2026 iGrant Technologies AB (iGrant.io), Sweden

Licensed under the Apache License 2.0. You may not use this file except in compliance with the licence. Unless required by applicable law or agreed to in writing, software distributed under the licence is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the [LICENSE](LICENSE) file for the specific language governing permissions and limitations under the licence.
