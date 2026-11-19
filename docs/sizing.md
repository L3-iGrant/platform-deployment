# Sizing

The size profiles of the chart: for each size of the estimates in [Prerequisites](prerequisites.md#estimated-cluster-requirements) up to 250,000 wallet units, a values file with the replicas, the requests and limits, the database pools and the server settings.

[Back to the contents](../README.md#contents)

> **Estimates.** These values come from load tests on one computer and from the measured use of one installation. They are not a commitment. Your peak load (presentations, issuances and WIA requests), your retention rules and your HSM change them. For a production installation, iGrant.io confirms the sizing with a load test.

## The size profiles

| Size | Nodes | Capacity | Profile |
| --- | --- | --- | --- |
| Development and tests | 1 node with 8 vCPU and 32 GB RAM | Up to 10,000 wallet units, little traffic | `size-development.yaml` |
| Extra small production | 3 nodes with about 1 vCPU and 6 GB RAM each (for example GKE `e2-custom-medium-6144`) | Up to 10,000 wallet units and 100 organisations, little traffic | `size-extra-small.yaml` |
| Small production | 3 nodes with 16 vCPU and 64 GB RAM each; the bundled PostgreSQL | Up to 250,000 wallet units: 20 presentations and 30 WIA requests each second at peak | `size-small.yaml` |

This chart has no size profile above 250,000 wallet units: the larger sizes need the autoscaling, the disruption budgets and the HSM signers of the enterprise chart (see [Scaled deployments](scaled-deployments.md)).

The requests of each profile on one node (the pods spread over the nodes), against the allocatable of the node on GKE:

| Profile | Requests on a node | Share of the allocatable (CPU, memory) | Wallet service pods | Database connections |
| --- | --- | --- | --- | --- |
| `size-development.yaml` | 4.2 vCPU, 14 GiB | 53 %, 50 % | 1 | The bundled server (`max_connections` 250) |
| `size-extra-small.yaml` | 0.3 vCPU, 1.6 GiB (with your own OpenBao) | 31 %, 36 % | 2 | The bundled server (`max_connections` 250) |
| `size-small.yaml` | 8.3 vCPU, 20 GiB (with your own OpenBao) | 52 %, 34 % | 9 | The bundled server (`max_connections` 700) |

The requests stay at or below 80 % of the allocatable of a node. The rest is for the system pods, your ingress controller, your monitoring and spikes. The memory of the larger nodes that the pods do not request is the page cache of the database server.

## Use a size profile

Add one size profile to the values files of [install step 3](install.md#step-3-the-values-of-your-installation), after the other profiles and before your own changes. A size profile changes only sizes, replicas and pools, no function. For example:

```bash
helm install ows ./platform-deployment -n ows \
  -f ./ows-keys/values-keys.yaml -f my-site.yaml -f my-openbao.yaml \
  -f ./platform-deployment/profiles/exposure-envoy-gateway.yaml \
  -f ./platform-deployment/profiles/size-small.yaml \
  --timeout 15m
```

- A production size needs your own OpenBao with an HSM seal (`openbao-external.yaml`, see [OpenBao](openbao.md)).
- `organisationWallet.workers.groups` is a map with the group name as key: a value of your own values file changes only the fields that it names (see [Workers and clock](workers.md#queues-and-worker-groups)).
- `minimal.yaml` is the smallest installation for tests on a small computer. `size-development.yaml` uses a whole node of 8 vCPU and 32 GB RAM.

When the requests of a node pass about 80 %, or the CPU is often throttled, move to the next size or add nodes.

## How the values are made

- The CPU of each flow, measured in a load test on one computer: a presentation 0.13 core-seconds, a later WIA 0.044, a PID issuance (2 formats, 10 copies each) 0.88, summed over all pods with PostgreSQL. A wallet process uses one core at peak.
- The peak memory of each pod in that load test: a wallet service pod 0.94 GB, a config pod 0.72 GB, a worker pod 0.46 GB, an api pod 0.5 GB, a NATS server 0.28 GB.
- The load model of [Prerequisites](prerequisites.md#estimated-cluster-requirements): 20 presentations for each wallet unit each month, a peak of 10 times the average, and a WIA for each wallet unit each day. The pods run at about 60 % of their CPU at peak.
- `size-extra-small.yaml` comes from the measured use of an installation with about 9,000 wallet units.
- The pods of this chart have no autoscaler: `size-small.yaml` has 9 wallet service pods, enough for the peak with one node lost.
- The bundled PostgreSQL gets `shared_buffers` of about 25 % of its memory, and `max_connections` for the pools of the profile.
