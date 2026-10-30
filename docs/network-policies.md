# Network policies

This page explains the NetworkPolicy objects of the chart and their values.

[Back to the contents](../README.md#contents)

`networkPolicy.enabled: true` (default `false`) creates NetworkPolicy objects. Use them only when your cluster enforces NetworkPolicy (for example Calico, Cilium, OVN-Kubernetes). The rules come from `policies/network-matrix.yaml`: only your ingress controller or Gateway reaches the gateway, the wallet service and the dashboard; only the gateway reaches the API core, consent and the wallet config role; the database (port 5432), NATS and Valkey (ports 6379 and 26379: only the wallet roles, the gateway and the other Valkey pods) accept only their clients; a default policy refuses all other traffic.

| Value | Description |
| --- | --- |
| `networkPolicy.ingressController` | The pods of your ingress controller or of your Gateway (namespace and pod selectors) |
| `networkPolicy.dns` | The DNS pods and ports |
| `networkPolicy.externalDatabases`, `.externalNats`, `.externalRedis` | The addresses (CIDR) of an external database, NATS, or Valkey or Redis (`redis.mode: external`; required then; default ports 6379 and 26379) |
| `networkPolicy.egress.profiles` | The external targets: `internet`, `internet-any-port`, `metadata`, `kms` (an external OpenBao), `cloudKms` (a cloud KMS on a private address), `auditBucket` (the S3 store of the audit bucket on a private address; scheduler only), `smtp`, `kubeApi` (required with the privacy dashboards) |
| `networkPolicy.egress.roles` | The profiles of each component |


`tests/check_network_matrix.py` proves the policies of a render against `policies/network-matrix.yaml`: each connection of the matrix is allowed, each other connection between the pods of the release is denied (see [Tests](tests.md)).

`examples/networkpolicy.yaml` shows the values. Check first with `helm template` and your values. To turn the policies off: `networkPolicy.enabled: false` and `helm upgrade`.
