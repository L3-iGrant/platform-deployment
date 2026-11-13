# Network policies

This page explains the NetworkPolicy objects of the chart and their values.

[Back to the contents](../README.md#contents)

`networkPolicy.enabled: true` (default `false`) creates NetworkPolicy objects. Use them only when your cluster enforces NetworkPolicy (for example Calico, Cilium, OVN-Kubernetes, or the network policy controller of k3s). The rules come from `policies/network-matrix.yaml`: only your ingress controller or Gateway reaches the gateway, the wallet service and the dashboard; only the gateway reaches the API core, consent and the wallet config role; the database (port 5432), NATS and Valkey (ports 6379 and 26379: only the wallet roles, the gateway and the other Valkey pods) accept only their clients; the clock of the wallet reaches only the database and Valkey; only `networkPolicy.monitoring` reaches the metrics port 9190 of the service and config pods and the health ports of the workers and of the clock (the scrape of `/metrics`, see [Workers and clock](workers.md#probes-and-metrics)) and the exporter port 9121 of the Valkey pods (see [Redis](redis.md#metrics)); a default policy refuses all other traffic.

| Value | Description |
| --- | --- |
| `networkPolicy.ingressController` | The pods of your ingress controller or of your Gateway (namespace and pod selectors) |
| `networkPolicy.dns` | The DNS pods and ports; `cidrs`: DNS servers that are not pods of the cluster network |
| `networkPolicy.externalDatabases`, `.externalNats`, `.externalRedis` | The addresses (CIDR) of an external database, NATS, or Valkey or Redis (`redis.mode: external`, or the separate groups `redis.state` and `redis.cache` of the wallet; required then; default ports 6379 and 26379) |
| `networkPolicy.egress.profiles` | The external targets: `internet`, `internet-any-port`, `platform` (the public hosts of this platform), `metadata`, `kms` (an external OpenBao), `cloudKms` (a cloud KMS on a private address), `auditBucket` (the S3 store of the audit bucket on a private address; the workers only), `smtp`, `kubeApi` (required with the privacy dashboards) |
| `networkPolicy.egress.roles` | The profiles of each component (`wallet-worker`: all worker groups; `wallet-clock` has none) |
| `networkPolicy.monitoring` | The monitoring namespace: it reaches the NATS monitor port, the metrics ports of the servers and the health ports of the workers and the clock, and the exporter port of the Valkey pods |

## The values that you must set

The defaults are for a cluster with ingress-nginx in the namespace `ingress-nginx`, CoreDNS in `kube-system`, and the database, NATS, OpenBao and Valkey of the chart. Before you set `networkPolicy.enabled: true`, examine each line of this table for your cluster. A missing value does not stop the render: the connection is refused when the pods start. `examples/networkpolicy.yaml` shows the values. Helm merges your values with the defaults key by key: a selector of your file keeps the keys of the default selector that it does not set. For example, a `namespaceSelector` with only `matchExpressions` also keeps the default `matchLabels` (`kubernetes.io/metadata.name: ingress-nginx`), and a pod must match both. To remove a default key, set it to `null` (`matchLabels: null`), and check the policies with `helm template`.

| Item | Value | When | What to set |
| --- | --- | --- | --- |
| DNS | `networkPolicy.dns` | Always | The namespace and the labels of your DNS pods, and their ports (`kubectl -n kube-system get pods --show-labels`). OpenShift: namespace `openshift-dns`, pods `dns.operator.openshift.io/daemonset-dns: default`, port 5353. NodeLocal DNSCache: add its address to `cidrs` (usually `169.254.20.10/32`) and also select its pods (`podSelector: {matchExpressions: [{key: k8s-app, operator: In, values: [kube-dns, node-local-dns]}]}`). A resolver of the node or of your network: its address in `cidrs`. |
| The ingress controller | `networkPolicy.ingressController` | Always | The namespace and the labels of the pods of your ingress controller, or of the data plane of your Gateway. These pods are the only source of the public traffic, and the target of the profile `platform`. |
| The pod and Service ranges | `networkPolicy.clusterCidrs` | Always when a range is not private | The pod CIDR and the Service CIDR of your cluster. The `internet` profiles exclude them. The default `except` list already excludes the private ranges (10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 100.64.0.0/10, 169.254.0.0/16). |
| A database outside the cluster | `networkPolicy.externalDatabases` | `database.mode: external`, or a `readAccess.<reader>.<owner>.host` | The CIDR and the port of each server. A managed database can get a new address in its subnet after a failover (Cloud SQL, Amazon RDS, Azure Database): give the CIDR of the subnet. |
| The audit bucket | `networkPolicy.egress.profiles.auditBucket` | The store of the audit bucket has a private address (a store in your network, a private endpoint, an S3 store in the cluster) | The CIDR or the namespace and pod selectors of the store, and its port. A store with a public address (Google Cloud Storage, Amazon S3) needs no value: the workers have the profile `internet`. See [Audit log](audit-log.md). |
| The metadata server of your cloud | Add `metadata` to `networkPolicy.egress.roles.<role>`; `networkPolicy.egress.profiles.metadata.cidrs` | The pods get their cloud credentials from the metadata server (GKE Workload Identity for the audit bucket or a key store `gcp-kms`; the instance role on AWS or Azure) | The roles that use the cloud service (`wallet-worker` for the audit bucket; `wallet-service`, `wallet-config`, `wallet-worker` for a cloud key store). Default address `169.254.169.254/32`, port 80. EKS Pod Identity: `169.254.170.23/32`. |
| The public hosts of this platform | `networkPolicy.egress.profiles.platform` | Always with the wallet (default on for `wallet-service`, `wallet-config`, `wallet-worker`) | `ports`: the container ports of the pods of your ingress controller (ingress-nginx 80 and 443, the default; Traefik 8000 and 8443; Envoy Gateway 10080 and 10443). `cidrs`: the address of your load balancer when it is in a private range and the traffic of a pod goes to it (for example a load balancer with `ipMode: Proxy`). See [The public hosts of this platform](#the-public-hosts-of-this-platform). |
| SMTP | `networkPolicy.egress.profiles.smtp` | The api sends e-mail | The CIDR and the port of your mail relay (default port 587). |
| An external OpenBao | `networkPolicy.egress.profiles.kms` | `openbao.mode: external` | The CIDR, or the namespace and pod selectors, of OpenBao (default port 8200). |
| A cloud KMS on a private address | `networkPolicy.egress.profiles.cloudKms` | A key store `gcp-kms`, `aws-kms` or `azure-key-vault` through a private endpoint | The CIDR of the private endpoint (port 443). The public endpoints go through the profile `internet`. |
| An external NATS | `networkPolicy.nats` (in the cluster) or `networkPolicy.externalNats` | `nats.enabled: false` | The namespace and pod selectors, or the CIDR and the port (default 4222). |
| An external Valkey or Redis | `networkPolicy.externalRedis` | `redis.mode: external`, or `redis.state` or `redis.cache` | Required then. The CIDR and the ports (default 6379 and 26379). |
| The Kubernetes API | `networkPolicy.egress.profiles.kubeApi` | `privacyDashboard.enabled` | The addresses and the port of the endpoints of the API server, not the address of the Service `kubernetes` (`kubectl -n default get endpointslices -l kubernetes.io/service-name=kubernetes`; often port 6443). The policy sees the address after the Service translation. |
| Monitoring | `networkPolicy.monitoring` | You scrape the metrics | `enabled: true` and the namespace and pod selectors of your Prometheus. |

## The public hosts of this platform

A wallet role reads URLs on the public hosts of this platform: the status list of a credential that an organisation of this platform issued, the metadata of an issuer of this platform, a credential offer or a request of another organisation of this platform. In most clusters, the traffic of a pod to the address of a load balancer of the cluster does not leave the cluster: kube-proxy and Cilium send it directly to the pods of the ingress controller. The profile `internet` excludes the pod addresses, so the profile `platform` allows these pods (the selectors of `networkPolicy.ingressController`) on its `ports`. When your load balancer has a public address and the traffic goes to it, the profile `internet` also allows it.

## Jobs and new pods

A network policy controller applies the rules to a new pod after a short time (on k3s, some seconds). In that time, the first connection of a new pod can fail. The Jobs and the hooks of the chart use `restartPolicy: OnFailure` and a `backoffLimit` of 3 or more: the container starts again in the same pod, and then the rules are in place. With `restartPolicy: Never`, each retry is a new pod with the same delay.

## Objects outside the release

The policies select only the pods of this release (the label `app.kubernetes.io/instance` and a network role). The privacy dashboards that the api makes in `privacyDashboard.namespace` are not pods of the release: write their policies yourself. The chart does not make policies for the namespace of your ingress controller, your DNS or your monitoring.

## Checks

`tests/check_network_matrix.py` proves the policies of a render against `policies/network-matrix.yaml`: each connection of the matrix is allowed, each other connection between the pods of the release is denied (see [Tests](tests.md)).

Check first with `helm template` and your values. To turn the policies off: `networkPolicy.enabled: false` and `helm upgrade`.
