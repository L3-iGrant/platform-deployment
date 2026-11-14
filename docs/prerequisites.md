# Prerequisites

What your cluster, your network and your workstation need before you install the platform.

[Back to the contents](../README.md#contents)

| Item | Requirement |
| --- | --- |
| Kubernetes | 1.30 or later. The pods stop with the sleep action of their preStop hooks (on by default from 1.30), because the images have no shell and no sleep program. |
| Helm | Helm 4, or Helm 3.10 or later. The chart tests pass with Helm 3.22.1 and 4.3.2. Helm 3.9 and earlier cannot render the chart. Helm 3 gets security fixes until 10 February 2027. Without a cluster, `helm template` checks the chart against its default Kubernetes version: Helm 3.14 and earlier, and Helm 4.0.0, need `--kube-version 1.30` or later. `helm install` and `helm upgrade` use the version of the cluster. |
| Ingress | A Gateway API implementation or an ingress controller; the chart does not install one. These docs use Envoy Gateway with the files of `manifests/envoy-gateway/` (see [Envoy Gateway](#envoy-gateway)). Other choices are kgateway, Istio or Traefik: your Gateway needs an HTTPS listener and a policy that passes on the client address (see [Exposure](exposure.md)). ingress-nginx was retired on 24 March 2026 and gets no security fixes; its profiles stay for clusters that still run it. |
| DNS | Three host names that point to your ingress controller or Gateway: the API, the organisation wallet and the dashboard (for example `api.example.org`, `wallet.example.org` and `dashboard.example.org`). The API and the dashboard must have the same registrable domain. |
| TLS | Certificates for the three host names. With Envoy Gateway, cert-manager writes the certificate of the Gateway listener (see [Envoy Gateway](#envoy-gateway)). Otherwise: TLS Secrets in the release namespace, or TLS at your load balancer (with ingress-nginx and cert-manager, see `profiles/exposure-ingress-nginx-cert-manager.yaml`). |
| Your own certificates | The wallet (Python 3.13) checks every TLS certificate strictly (RFC 5280). A server certificate needs an authority key identifier. A CA needs a subject key identifier, the key usage `keyCertSign` and critical basic constraints. The certificates that the chart makes have them. Check each certificate or CA that you supply (for an external PostgreSQL, NATS, Valkey or Redis, or OpenBao, and your own NATS or Valkey certificate) with `openssl verify -x509_strict -purpose sslserver -CAfile ca.crt server.crt`. If a certificate fails, make a new one with `subjectKeyIdentifier = hash` and `authorityKeyIdentifier = keyid` (for a CA, also `basicConstraints = critical, CA:true` and `keyUsage = critical, keyCertSign, cRLSign`). |
| Storage | A default StorageClass for ReadWriteOnce volumes, or the value `global.storageClass`. The database server, NATS, OpenBao and Valkey use volumes. The volumes must support `fsGroup` (the processes do not run as root). |
| Pod security | Every pod runs as a non-root user with a read-only root file system and meets the Pod Security Standard `restricted`. The api, the webhook handler, consent and the dashboard use the safe sysctl `net.ipv4.ip_unprivileged_port_start` (port 80). See [Security settings of the containers](security-context.md). |
| Image registry | Read access to the iGrant.io registry `europe-docker.pkg.dev/jenkins-189019/igrant-customers` (a service account key file from iGrant.io) and the release tag of your version, or your own mirror. The Google Cloud CLI (`gcloud`) on your workstation is optional. |
| OpenBao | Operators who unseal the bundled OpenBao after every restart (the Shamir seal), or your own OpenBao. See [OpenBao](openbao.md). |
| Workstation | `kubectl`, `helm`, `bash`, and `docker` to run `scripts/make-keys.sh` (it runs the api image). |

## Envoy Gateway

The default exposure of these docs, `profiles/exposure-envoy-gateway.yaml`, needs Envoy Gateway, the Gateway `platform` and the certificate of its HTTPS listener. `manifests/envoy-gateway/` has the files, ready to apply. Do the steps in order, with cluster admin rights: each step ends with a check.

| Component | Version | Kubernetes | Source |
| --- | --- | --- | --- |
| Envoy Gateway | v1.10.0 | 1.34 to 1.37 | [Release v1.10.0](https://github.com/envoyproxy/gateway/releases/tag/v1.10.0), [compatibility matrix](https://gateway.envoyproxy.io/news/releases/matrix/) |
| Gateway API CRDs | v1.6.1, experimental channel (the Envoy Gateway chart installs them) | | [Compatibility matrix](https://gateway.envoyproxy.io/news/releases/matrix/) |
| cert-manager | v1.21.3 | 1.33 to 1.36 | [Release v1.21.3](https://github.com/cert-manager/cert-manager/releases/tag/v1.21.3), [supported releases](https://cert-manager.io/docs/releases/) |

For an older Kubernetes version, pick the releases from the compatibility matrix of Envoy Gateway and the supported releases of cert-manager. The files below use these fields: `ClientTrafficPolicy` `headers.earlyRequestHeaders` and `proxyProtocol` (Envoy Gateway v1.5 and later), and the cert-manager value `config.gatewayAPI.enabled` (cert-manager v1.21 and later; earlier versions: `config.enableGatewayAPI`).

The files use the placeholders of these docs. Change the lines marked `# change:` before you apply them:

| File | Line to change |
| --- | --- |
| `02-gateway.yaml` | `ows`: the namespace of your release |
| `05-cluster-issuer.yaml` | `admin@example.org`: the e-mail address of your ACME account |
| `06-certificate.yaml` | `api.example.org`, `wallet.example.org`, `dashboard.example.org`: your three host names |

### Step 1: install Envoy Gateway

The Helm chart of Envoy Gateway also installs the Gateway API CRDs and the CRDs of Envoy Gateway:

```bash
helm install eg oci://docker.io/envoyproxy/gateway-helm --version v1.10.0 \
  -n envoy-gateway-system --create-namespace
```

If your cluster provider manages the Gateway API CRDs, follow [Install with Helm](https://gateway.envoyproxy.io/docs/install/install-helm/) of Envoy Gateway instead (`--set crds.enabled=false`).

Check: `kubectl wait --timeout=5m -n envoy-gateway-system deployment/envoy-gateway --for=condition=Available` shows `condition met`.

### Step 2: install cert-manager with Gateway API support

Install cert-manager after step 1: it looks for the Gateway API CRDs only when it starts. `config.gatewayAPI.enabled=true` turns on its Gateway API support (the controller configuration of cert-manager):

```bash
helm install cert-manager oci://quay.io/jetstack/charts/cert-manager --version v1.21.3 \
  -n cert-manager --create-namespace \
  --set crds.enabled=true \
  --set config.gatewayAPI.enabled=true
```

If cert-manager already runs in your cluster, set the value on it and restart it. Keep your own CRD setting: do not add `crds.enabled=true` when you manage the CRDs outside Helm.

```bash
helm upgrade cert-manager oci://quay.io/jetstack/charts/cert-manager --version v1.21.3 \
  -n cert-manager --reuse-values --set config.gatewayAPI.enabled=true
kubectl -n cert-manager rollout restart deployment cert-manager
```

Check: `kubectl wait --timeout=5m -n cert-manager deployment --all --for=condition=Available` shows `condition met` for the 3 Deployments.

### Step 3: the GatewayClass

`01-gatewayclass.yaml` has the GatewayClass `envoy-gateway` and its `EnvoyProxy`: 2 Envoy pods, and a place for the annotations of your cloud's load balancer (for example an internal load balancer or the PROXY protocol).

```bash
kubectl apply -f ./platform-deployment/manifests/envoy-gateway/01-gatewayclass.yaml
```

Check: `kubectl get gatewayclass envoy-gateway` shows `ACCEPTED` `True`.

### Step 4: the Gateway

The Gateway `platform` has the listener `http` (port 80) for the redirect and the certificate challenges, and the listener `https` (port 443) for the routes of the chart. `profiles/exposure-envoy-gateway.yaml` expects exactly these names: the Gateway `platform` in `envoy-gateway-system` with the listener `https`. With other names, change `parentRefs` in your copy of the profile, and `networkPolicy.ingressController`. Envoy listens on the container ports 10080 and 10443: Envoy Gateway adds 10000 to a listener port below 1024.

```bash
kubectl apply -f ./platform-deployment/manifests/envoy-gateway/02-gateway.yaml
```

Check: `kubectl -n envoy-gateway-system get pods -l gateway.envoyproxy.io/owning-gateway-name=platform` shows 2 pods `Running`, and after a minute `kubectl -n envoy-gateway-system get gateway platform` shows the address of the load balancer under `ADDRESS`. Point the three host names to this address in your DNS. If the load balancer has only a host name (see [A load balancer with the PROXY protocol](#a-load-balancer-with-the-proxy-protocol)), `ADDRESS` shows that host name: create its DNS record first (an A record to the load balancer address from your cloud console), then point the three host names to it (CNAME or A). The listener `https` has no certificate until step 8.

### Step 5: the client address

`03-client-traffic-policy.yaml` makes Envoy set `X-Real-IP` to the client address and overwrite any value that the client sends. `profiles/exposure-envoy-gateway.yaml` sets `clientAddress.header: X-Real-IP` and needs this policy (see [Exposure](exposure.md#what-your-proxy-must-do)).

```bash
kubectl apply -f ./platform-deployment/manifests/envoy-gateway/03-client-traffic-policy.yaml
```

Check: `kubectl -n envoy-gateway-system get clienttrafficpolicy platform-client-address -o jsonpath='{.status.ancestors[0].conditions[?(@.type=="Accepted")].status}'` shows `True`.

### Step 6: the redirect to HTTPS

```bash
kubectl apply -f ./platform-deployment/manifests/envoy-gateway/04-http-redirect.yaml
```

The route redirects every HTTP request to HTTPS with 301. The routes of the certificate challenges (step 8) still work: each names its host and an exact path, so it takes precedence.

Check: when the DNS change of step 4 is visible to your resolver, `curl -sI http://api.example.org/` shows `301` and `location: https://api.example.org/`.

### Step 7: the ACME issuer

`05-cluster-issuer.yaml` has the ClusterIssuer `letsencrypt` (Let's Encrypt) with the HTTP-01 challenge on the listener `http` of the Gateway. To test first, use the test server of Let's Encrypt (see the comment in the file).

```bash
kubectl apply -f ./platform-deployment/manifests/envoy-gateway/05-cluster-issuer.yaml
```

Check: `kubectl get clusterissuer letsencrypt` shows `READY` `True`.

### Step 8: the certificate

`06-certificate.yaml` asks for one certificate for the three host names. cert-manager writes it to the Secret `platform-tls` in `envoy-gateway-system`, the certificate of the listener `https`, and renews it.

```bash
kubectl apply -f ./platform-deployment/manifests/envoy-gateway/06-certificate.yaml
```

Check: after a few minutes, `kubectl -n envoy-gateway-system get certificate platform-tls` shows `READY` `True`. If it stays `False`, `kubectl -n envoy-gateway-system describe challenges` shows the reason (for example a host name that does not point to the Gateway yet). The HTTPS check of the hosts is in step 6 of [Install](install.md#step-6-wait-for-the-platform).

### A load balancer with the PROXY protocol

The services need the client address. A load balancer that passes the client address on as the source address (the Envoy Service has `externalTrafficPolicy: Local`, the Envoy Gateway default) needs nothing more. A load balancer that replaces the source address must send the PROXY protocol, and Envoy must read it:

- Turn the PROXY protocol on at the load balancer: an annotation of your cloud in `envoyService.annotations` of `01-gatewayclass.yaml`.
- Turn it on in Envoy: uncomment `proxyProtocol` in `03-client-traffic-policy.yaml`, in the same ClientTrafficPolicy that sets `X-Real-IP` (two ClientTrafficPolicies on one Gateway conflict) (the field `ClientTrafficPolicy.spec.proxyProtocol` of Envoy Gateway v1.5 and later; `enableProxyProtocol: true` before v1.5, deprecated and planned for removal in v1.11).

With the PROXY protocol, Envoy refuses a connection without the PROXY header. In most clusters, kube-proxy sends a connection from a pod to the address of the load balancer straight to the Envoy pods, without the header: the wallet then cannot call its own hosts, and the HTTP-01 self check of cert-manager fails. So, with the PROXY protocol:

1. Avoid this short cut: use a load balancer that has only a host name in the status of the Envoy Service (many clouds have an annotation for it), or `ipMode: Proxy`. The calls from the pods then go out through the load balancer, get the header, and the `internet` egress rules of the network policies allow them.
2. If your cloud has neither, set `proxyProtocol: {optional: true}` (in the file): Envoy also accepts a connection without the header and uses its source address.

Only the load balancer may reach the node ports of the Envoy Service (for example with a firewall rule): a client that reaches Envoy directly can send its own PROXY header.

### Network policies with Envoy Gateway

With `networkPolicy.enabled: true`, the chart defaults fit this Gateway (see [Network policies](network-policies.md#envoy-gateway)):

- `networkPolicy.ingressController` selects the Envoy pods of the Gateway `platform` in the namespace `envoy-gateway-system` (labels `app.kubernetes.io/name: envoy`, `app.kubernetes.io/component: proxy`, `gateway.envoyproxy.io/owning-gateway-name: platform`, `gateway.envoyproxy.io/owning-gateway-namespace: envoy-gateway-system`). Only these pods reach the gateway, the wallet service and the dashboard.
- With the PROXY protocol and no short cut (above), the calls of the wallet roles to their own hosts go out through the load balancer: the `internet` profiles allow a public load balancer address, and `networkPolicy.egress.profiles.platform.cidrs` takes a private one (ports 80 and 443).
- Without the PROXY protocol, kube-proxy sends these calls straight to the Envoy pods: the egress profile `platform` allows the Envoy pods on the container ports 10080 and 10443 (the default).

If you give the Gateway another name or namespace, change these values too.

## Resources

The images are for Linux x86-64. With the default values, the platform requests about 1.6 vCPU and 6.5 GiB of memory in total, and 134 GiB of volumes: the database 50 GiB, NATS 3 × 10 GiB, OpenBao 3 × 10 GiB and Valkey 3 × 8 GiB.

These are the pod requests, not what an installation needs under load. To plan the nodes, use the estimates below.

## Estimated cluster requirements

This chart is the community installation, for development and tests. Production uses the enterprise installation (on request: support@igrant.io). The sizing below applies to both.

> **Estimates.** These figures come from load tests on one computer, before optimisation. They are not a commitment. Your peak load (presentations, issuances and WIA requests), your retention rules and your HSM change them. For a production installation, iGrant.io confirms the sizing with a load test.

| Item | Development and tests | Small production |
| --- | --- | --- |
| Capacity | Up to 10,000 wallet units | Up to 250,000 wallet units |
| Nodes | 1 | 3 |
| CPU | 8 vCPU | 16 vCPU for each node |
| Memory | 32 GB RAM | 64 GB RAM for each node |
| Storage | 250 GB NVMe SSD | 1 TB NVMe SSD for each node, with backups |
| Network | 1 Gbit/s | 10 Gbit/s |
| Key store | OpenBao, with the Shamir seal | OpenBao, unsealed by an HSM (PKCS#11) or Google Cloud KMS (see [Connect your on-premise HSM](on-premise-hsm.md)) |

Run a staging installation with the same topology as production, at a smaller size. One node does not test updates, failover or the HSM path.

### Larger installations

Above 250,000 wallet units, the installation has application nodes and two database servers: a primary and a synchronous standby. For each 1,000,000 active wallet units, add about:

- 35 vCPU and 45 GB RAM on the application nodes.
- 7 vCPU and 32 GB RAM on each database server, with at least 64 GB RAM.
- 300 P-256 signatures per second of HSM capacity at peak, when the signing keys are in the HSM.

OpenBao is the key store, and an HSM (PKCS#11) or Google Cloud KMS must unseal it. The network has 10 Gbit/s over two independent paths, and at most 2 ms round trip between the database servers.

| Active wallet units | Peak presentations and WIA requests each second | Application nodes | Each database server | HSM signatures each second at peak |
| --- | --- | --- | --- | --- |
| 250,000 | 20 and 30 | 3 × 16 vCPU, 64 GB RAM | In the cluster | 75 |
| 1,000,000 | 80 and 120 | 4 × 16 vCPU, 32 GB RAM | 8 vCPU, 64 GB RAM | 300 |
| 4,000,000 | 310 and 460 | 6 × 32 vCPU, 64 GB RAM | 32 vCPU, 256 GB RAM | 1,200 |

In each example, the application nodes use 60 % of their CPU at peak. If one node fails, the other nodes carry the peak load.

### Load model

- Each wallet unit presents a credential 20 times a month. The peak is 10 times the average.
- The PID is issued in 2 formats, each as a batch of 10 copies. A wallet unit asks for a new batch after it uses the last copy.
- Each wallet unit asks for a new wallet instance attestation (WIA) every day. Without the daily WIA, the CPU need is about 30 % lower, and the HSM signs about 40 % less.

### Database growth

The database grows with the records that the installation keeps. We measured these average sizes on our test and hosted installations:

| Record | Average size |
| --- | --- |
| Wallet unit, with its attestations | 26 KB |
| Verification record | 18 to 31 KB |
| WIA | 5 KB |
| Issued credential, each copy | 8 to 17 KB |
| Re-issuance, added to its issuance record | 0.5 MB |
| Audit event, kept 7 years by default (see [Audit log](audit-log.md)) | 1 to 2 KB |

For example, an installation with 1,000,000 active wallet units that keeps all its records adds about 1.8 TB to the database each month. Plan the database storage and the backups for your retention period.

We size installations with high availability, many wallet units, a high transaction rate or HSM signing individually, from their load and availability requirements (see [Scaled deployments](scaled-deployments.md)). Contact support@igrant.io.
