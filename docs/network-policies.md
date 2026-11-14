# Network policies

The NetworkPolicy objects of the chart and their values.

[Back to the contents](../README.md#contents)

`networkPolicy.enabled: true` (default `false`) creates NetworkPolicy objects. Use them only if your cluster enforces NetworkPolicy (for example Calico, Cilium, OVN-Kubernetes, or the k3s network policy controller). The rules come from `policies/network-matrix.yaml`:

- only your ingress controller or Gateway reaches the gateway, the wallet service and the dashboard;
- only the gateway reaches the API core, consent and the wallet config role;
- the database (port 5432), NATS and Valkey (ports 6379 and 26379: only the wallet roles, the gateway and the other Valkey pods) accept only their clients;
- the wallet clock reaches only the database and Valkey;
- only `networkPolicy.monitoring` reaches the metrics port 9190 of the service and config pods, the health ports of the workers and the clock (the scrape of `/metrics`, see [Workers and clock](workers.md#probes-and-metrics)), and the exporter port 9121 of the Valkey pods (see [Redis](redis.md#metrics));
- a default policy refuses all other traffic.

| Value | Description |
| --- | --- |
| `networkPolicy.ingressController` | The pods of your ingress controller or Gateway (namespace and pod selectors) |
| `networkPolicy.dns` | The DNS pods and ports; `cidrs`: DNS servers that are not pods of the cluster network |
| `networkPolicy.externalDatabases`, `.externalNats`, `.externalRedis` | The addresses (CIDR) of an external database, NATS, or Valkey or Redis (`redis.mode: external`, or the wallet's separate groups `redis.state` and `redis.cache`; required then; default ports 6379 and 26379) |
| `networkPolicy.egress.profiles` | The external targets: `internet`, `internet-any-port`, `platform` (the public hosts of this platform), `metadata`, `kms` (an external OpenBao), `cloudKms` (a cloud KMS on a private address), `auditBucket` (the S3 store of the audit bucket on a private address; the workers only), `smtp`, `kubeApi` (required with the privacy dashboards) |
| `networkPolicy.egress.roles` | The profiles of each component (`wallet-worker`: all worker groups; `wallet-clock` has none) |
| `networkPolicy.monitoring` | The monitoring namespace: it reaches the NATS monitor port, the metrics ports of the servers, the health ports of the workers and the clock, and the exporter port of the Valkey pods |

## The values that you must set

The defaults suit a cluster with the Gateway `platform` of Envoy Gateway in the namespace `envoy-gateway-system` (see [Envoy Gateway](#envoy-gateway)), CoreDNS in `kube-system`, and the chart's own database, NATS, OpenBao and Valkey. Before you set `networkPolicy.enabled: true`, go through each row of this table for your cluster. A missing value does not stop the render: the connection is refused when the pods start. `profiles/network-policies.yaml` shows the values.

Helm merges your values with the defaults key by key: a selector in your file keeps the keys of the default selector that it does not set. For example, a `namespaceSelector` with only `matchExpressions` keeps the default `matchLabels` (`kubernetes.io/metadata.name: envoy-gateway-system`): a pod must match both. To remove a default key, set it to `null` (`matchLabels: null`, as the on-premise profile does), and check the policies with `helm template`.

| Item | Value | When | What to set |
| --- | --- | --- | --- |
| DNS | `networkPolicy.dns` | Always | The namespace, labels and ports of your DNS pods (`kubectl -n kube-system get pods --show-labels`). OpenShift: namespace `openshift-dns`, pods `dns.operator.openshift.io/daemonset-dns: default`, port 5353. NodeLocal DNSCache: add its address to `cidrs` (usually `169.254.20.10/32`) and also select its pods (`podSelector: {matchExpressions: [{key: k8s-app, operator: In, values: [kube-dns, node-local-dns]}]}`). A resolver on the node or in your network: its address in `cidrs`. |
| The ingress controller | `networkPolicy.ingressController` | Always | The namespace and labels of the pods of your ingress controller, or of your Gateway's data plane. Default: all pods of the namespace `envoy-gateway-system` (see [Envoy Gateway](#envoy-gateway)); the other exposure profiles set their controller. These pods are the only source of public traffic, and the target of the profile `platform`. |
| The pod and Service ranges | `networkPolicy.clusterCidrs` | Always when a range is not private | The pod CIDR and the Service CIDR of your cluster, including the IPv6 ranges of a dual-stack cluster. The `internet` profiles exclude them (each all-addresses block, `0.0.0.0/0` and `::/0`, excludes the entries of its family). The default `except` list already excludes the private ranges (10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 100.64.0.0/10, 169.254.0.0/16, fc00::/7, fe80::/10). |
| A database outside the cluster | `networkPolicy.externalDatabases` | `database.mode: external`, or a `readAccess.<reader>.<owner>.host` | The CIDR and port of each server. A managed database can get a new address in its subnet after a failover (Cloud SQL, Amazon RDS, Azure Database): give the CIDR of the subnet. |
| The audit bucket | `networkPolicy.egress.profiles.auditBucket` | The store of the audit bucket has a private address (a store in your network, a private endpoint, an S3 store in the cluster) | The CIDR, or the namespace and pod selectors, of the store, and its port. A store with a public address (Google Cloud Storage, Amazon S3) needs no value: the workers have the profile `internet-any-port`. See [Audit log](audit-log.md). |
| The metadata server of your cloud | Add `metadata` to `networkPolicy.egress.roles.<role>`; `networkPolicy.egress.profiles.metadata.cidrs` | The pods get their cloud credentials from the metadata server (GKE Workload Identity for the audit bucket or a key store `gcp-kms`; the instance role on AWS or Azure) | The roles that use the cloud service (`wallet-worker` for the audit bucket; `wallet-service`, `wallet-config`, `wallet-worker` for a cloud key store). Default address `169.254.169.254/32`, port 80. EKS Pod Identity: `169.254.170.23/32`. |
| The public hosts of this platform | `networkPolicy.egress.profiles.platform` | Always with the wallet (on by default for `wallet-service`, `wallet-config`, `wallet-worker`) | `ports`: the container ports of your ingress controller pods, and the ports of the load balancer in `cidrs` (default 80, 443, 10080 and 10443: Envoy Gateway listens on 10080 and 10443; the ingress-nginx profiles set 80 and 443; Traefik 8000 and 8443). `cidrs`: the address of your load balancer, if it is in a private range and pod traffic goes to it (for example a load balancer with `ipMode: Proxy`). See [The public hosts of this platform](#the-public-hosts-of-this-platform). |
| SMTP | `networkPolicy.egress.profiles.smtp` | The api sends e-mail | The CIDR and port of your mail relay (default port 587). |
| An external OpenBao | `networkPolicy.egress.profiles.kms` | `openbao.mode: external` | The CIDR, or the namespace and pod selectors, of OpenBao (default port 8200). |
| A cloud KMS on a private address | `networkPolicy.egress.profiles.cloudKms` | A key store `gcp-kms`, `aws-kms` or `azure-key-vault` through a private endpoint | The CIDR of the private endpoint (port 443). The public endpoints go through the profile `internet`. |
| An external NATS | `networkPolicy.nats` (in the cluster) or `networkPolicy.externalNats` | `nats.enabled: false` | The namespace and pod selectors, or the CIDR and port (default 4222). |
| An external Valkey or Redis | `networkPolicy.externalRedis` | `redis.mode: external`, or `redis.state` or `redis.cache` | Required then. The CIDR and ports (default 6379 and 26379). |
| The Kubernetes API | `networkPolicy.egress.profiles.kubeApi` | `privacyDashboard.enabled` | The addresses and port of the API server endpoints, not the address of the Service `kubernetes` (`kubectl -n default get endpointslices -l kubernetes.io/service-name=kubernetes`; often port 6443). The policy sees the address after the Service translation. |
| Monitoring | `networkPolicy.monitoring` | You scrape the metrics | `enabled: true`, and the namespace and pod selectors of your Prometheus. |

## The public hosts of this platform

A wallet role reads URLs on the public hosts of this platform: the status list of a credential that an organisation of this platform issued, the metadata of an issuer of this platform, or a credential offer or request of another organisation of this platform.

In most clusters, traffic from a pod to the address of a cluster load balancer does not leave the cluster: kube-proxy and Cilium send it directly to the ingress controller pods. The `internet` profiles exclude pod addresses, so the profile `platform` allows these pods (the selectors of `networkPolicy.ingressController`) on its `ports`. If your load balancer has a public address and the traffic goes to it, the `internet` profiles also allow it.

If the public hosts have private addresses (on premise, an internal load balancer), the wallet's SSRF guard refuses them too. List the host names or networks in `organisationWallet.ssrf.allowedPrivate`, and give the address of the load balancer to `networkPolicy.egress.profiles.platform.cidrs`.

### Envoy Gateway

The Envoy pods of the Gateway `platform` (`manifests/envoy-gateway/`, see [Prerequisites](prerequisites.md#envoy-gateway)) listen on the container ports 10080 (listener `http`, port 80) and 10443 (listener `https`, port 443): Envoy Gateway adds 10000 to a listener port below 1024. The defaults select every pod of the namespace `envoy-gateway-system` (the Envoy pods of each Gateway there and the Envoy Gateway controller), in the same way as a selector of the ingress-nginx namespace.

A wallet role reaches the public hosts of this platform in one of two ways, and the defaults allow both:

- With the PROXY protocol, the load balancer must not be short-cut (see [A load balancer with the PROXY protocol](prerequisites.md#a-load-balancer-with-the-proxy-protocol)): the connection goes out to the load balancer and comes back. A public address of the load balancer is in the `internet` profiles; give a private one to `networkPolicy.egress.profiles.platform.cidrs` (ports 80 and 443).
- Without the PROXY protocol, kube-proxy or Cilium sends the connection to the address of the load balancer straight to an Envoy pod, on 10443 or 10080. The profile `platform` allows the pods of `networkPolicy.ingressController` on these ports.

With `useListenerPortAsContainerPort: true` in the EnvoyProxy, Envoy listens on 80 and 443, which are also in the default list. If you give the Gateway another name or namespace, change `networkPolicy.ingressController` too.

## Other vendors and the specifications

The wallet's issuer, verifier and holder call other vendors on the public internet: credential issuers and their metadata, verifiers, trust lists, status lists and JWKS. The specifications allow a URL with any port, and a host given as an IPv4 or IPv6 address. So by default the wallet roles (`wallet-service`, `wallet-config`, `wallet-worker`) have the egress profile `internet-any-port`: any port of every public IPv4 and IPv6 address. That is `0.0.0.0/0` and `::/0` minus the private, link-local, shared and multicast ranges, the NAT64 images of the IPv4 ranges that are never public, and `networkPolicy.clusterCidrs` (see [IPv6 and NAT64](#ipv6-and-nat64)). The wallet's SSRF guard keeps the private addresses closed inside the wallet itself.

Do not remove `internet-any-port` from these roles: a call to a vendor on a port other than 443 or 80 would fail. On a cluster without IPv6, the IPv6 block has no effect (the k3s network policy controller logs that it ignores it).

### The egress of each role

A role that calls URLs that an organisation or another vendor configures has `internet-any-port` (any port of every public IPv4 and IPv6 address). A role that calls only fixed hosts of the installation has `internet` (ports 443 and 80) or no internet profile:

| Role | Profile (default) | The calls and the reason |
| --- | --- | --- |
| `wallet-service`, `wallet-config`, `wallet-worker` | `internet-any-port` | The issuers, verifiers, trust lists, status lists, JWKS and metadata of other vendors (any URL that the specifications allow), the cloud key stores, the audit bucket. |
| `api` | `internet-any-port`, `smtp` | The webhook receivers (`payloadUrl`, often with a port such as 8443), the OIDC providers of the admins and of the organisations (discovery, JWKS, token), the extensions (for example the OpenID conformance suite), the SMS service. |
| `webhook` | `internet-any-port` | The webhook receivers (`payloadUrl`). |
| `consent` | `internet-any-port` | The Data Space of an organisation: the base URL that the organisation configures (discovery, the metadata of its authorisation server, token, `notification_endpoint`). |
| `gateway` | `internet` | Only the upstreams of `gateway.upstreams` (the chart's services in the cluster; an upstream outside the cluster on port 443 or 80). No URL of an organisation. |
| `dashboard`, `wallet-clock`, `db`, `nats`, `redis`, `job` | none | No call outside the cluster. |

The network policy is not the only protection, because a cluster can run without network policies. Each of these callers also has an SSRF guard in its code that refuses private, loopback, link-local and metadata addresses: the wallet (`ssrf_protection`), the api and the webhook handler (`OutboundHttp.ssrfProtectionDisabled: false`, the default) and consent (`OutboundHttp.ssrfProtectionDisabled: false`, the default).

### Receivers behind the ingress controller of this cluster

The api and the webhook handler do not have the profile `platform`. So they cannot call a URL whose host is behind this cluster's ingress controller, for example a webhook receiver (`payloadUrl`) in the same cluster, or an organisation's OIDC provider there. In most clusters, traffic from a pod to the load balancer address goes directly to the ingress controller pods (see [The public hosts of this platform](#the-public-hosts-of-this-platform)), and the `internet` profiles exclude pod addresses: the network policy refuses the connection, and the webhook delivery fails. To allow it, add `platform` to these roles. A list in your values replaces the default list, so keep the default profiles:

```yaml
networkPolicy:
  egress:
    roles:
      api: [internet-any-port, smtp, platform]
      webhook: [internet-any-port, platform]
```

The profile `platform` opens only the pods of `networkPolicy.ingressController` on its `ports` (default 80, 443, 10080 and 10443), not the other pods of the cluster. If the host of the receiver has a private address (on premise, an internal load balancer), also give that address to `networkPolicy.egress.profiles.platform.cidrs`. The SSRF guard of the api and the webhook handler refuses a private address too (see [The SSRF guards](security-context.md#the-ssrf-guards)). Do not turn the guard off (`OutboundHttp.ssrfProtectionDisabled`): that opens all private addresses.

### IPv6 and NAT64

The `::/0` block of the `internet` profiles excludes `fc00::/7` (unique local), `fe80::/10` (link-local), `ff00::/8` (multicast) and the IPv6 ranges of `networkPolicy.clusterCidrs`. In an IPv6-only cluster with DNS64, the DNS server gives a host that has only an IPv4 address an address in the NAT64 prefix `64:ff9b::/96` (RFC 6052), and the NAT64 gateway sends the traffic to the IPv4 address in the last 32 bits. A vendor with only a public IPv4 address is then at such an address, so the profiles cannot exclude the whole prefix. They exclude only the NAT64 images of the IPv4 ranges that are never public:

| IPv4 range | Its NAT64 image in `64:ff9b::/96` |
| --- | --- |
| `10.0.0.0/8` | `64:ff9b::a00:0/104` |
| `172.16.0.0/12` | `64:ff9b::ac10:0/108` |
| `192.168.0.0/16` | `64:ff9b::c0a8:0/112` |
| `100.64.0.0/10` | `64:ff9b::6440:0/106` |
| `169.254.0.0/16` (also the metadata server) | `64:ff9b::a9fe:0/112` |
| `127.0.0.0/8` | `64:ff9b::7f00:0/104` |
| `0.0.0.0/8` | `64:ff9b::/104` |

If your network has its own NAT64 prefix (RFC 6052, section 2.2), the chart's excepts do not cover it. Add the images of the same IPv4 ranges in your prefix to the `except` of both `internet` profiles. A list in your values replaces the default list, so give every entry of the default list (in `values.yaml`), then the new entries. For the prefix `2001:db8:64::/96`, the new entries are `2001:db8:64::a00:0/104`, `2001:db8:64::ac10:0/108`, `2001:db8:64::c0a8:0/112`, `2001:db8:64::6440:0/106`, `2001:db8:64::a9fe:0/112`, `2001:db8:64::7f00:0/104` and `2001:db8:64::/104`. With a prefix shorter than /96, the IPv4 address is not in the last 32 bits (RFC 6052, section 2.2): calculate the images for that format. Also give the prefix to the SSRF guard of the wallet, in `ssrf_protection.nat64_prefixes` (with `organisationWallet.extraConfig`, for example `{ssrf_protection: {nat64_prefixes: ["2001:db8:64::/96"]}}`): without it, the guard takes the NAT64 image of a private IPv4 address as public.

The lists have no `::ffff:0:0/96` (the IPv4-mapped addresses): the API server refuses an IPv4-mapped address in a NetworkPolicy, and a packet never carries one (a dual-stack socket sends IPv4 packets, and the IPv4 block applies to them).

## Jobs and new pods

A network policy controller applies the rules to a new pod after a short delay (a few seconds). In that time, the first connection of a new pod can fail. So the chart's Jobs and hooks use `restartPolicy: OnFailure` and a `backoffLimit` of 3 or more: the container starts again in the same pod, and by then the rules are in place. With `restartPolicy: Never`, each retry is a new pod with the same delay.

## Objects outside the release

The policies select only the pods of this release (the label `app.kubernetes.io/instance` and a network role). The privacy dashboards that the api creates in `privacyDashboard.namespace` are not pods of the release: write their policies yourself. The chart creates no policies for the namespaces of your ingress controller, your DNS or your monitoring.

## Checks

`tests/check_network_matrix.py` proves the policies of a render against `policies/network-matrix.yaml`: each connection in the matrix is allowed, and every other connection between the pods of the release is denied. With a model of the ingress controller pods of the exposure profile (`tests/fixtures/ingress-controller-pods.yaml`), it also proves the connections with these pods: they reach only the gateway, the wallet service and the dashboard, and only the wallet roles reach them, on the ports of their listeners (Envoy Gateway: 10080 and 10443, not the metrics and readiness ports; the defaults select every pod of `envoy-gateway-system`). See [Tests](tests.md).

Check with `helm template` and your values first. To turn the policies off, set `networkPolicy.enabled: false` and run `helm upgrade`.
