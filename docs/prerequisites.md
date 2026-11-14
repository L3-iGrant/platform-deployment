# Prerequisites

What your cluster, your network and your workstation need before you install the platform.

[Back to the contents](../README.md#contents)

| Item | Requirement |
| --- | --- |
| Kubernetes | 1.30 or later. The pods stop with the sleep action of their preStop hooks (on by default from 1.30), because the images have no shell and no sleep program. |
| Helm | Helm 4, or Helm 3.10 or later. The chart tests pass with Helm 3.22.1 and 4.3.2. Helm 3.9 and earlier cannot render the chart. Helm 3 gets security fixes until 10 February 2027. Without a cluster, `helm template` checks the chart against its default Kubernetes version: Helm 3.14 and earlier, and Helm 4.0.0, need `--kube-version 1.30` or later. `helm install` and `helm upgrade` use the version of the cluster. |
| Ingress | An ingress controller (for example ingress-nginx or Traefik) or a Gateway API implementation (for example Envoy Gateway, kgateway or Istio). The chart does not install one. With the Gateway API, your Gateway needs an HTTPS listener and a policy that passes on the client address (see [Exposure](exposure.md)). |
| DNS | Three host names that point to your ingress controller or Gateway: the API, the organisation wallet and the dashboard (for example `api.example.org`, `wallet.example.org` and `dashboard.example.org`). The API and the dashboard must have the same registrable domain. |
| TLS | Certificates for the three host names: TLS Secrets in the release namespace, or TLS at your Gateway or load balancer. cert-manager is optional (see `profiles/exposure-ingress-nginx-cert-manager.yaml`). |
| Your own certificates | The wallet (Python 3.13) checks every TLS certificate strictly (RFC 5280). A server certificate needs an authority key identifier. A CA needs a subject key identifier, the key usage `keyCertSign` and critical basic constraints. The certificates that the chart makes have them. Check each certificate or CA that you supply (for an external PostgreSQL, NATS, Valkey or Redis, or OpenBao, and your own NATS or Valkey certificate) with `openssl verify -x509_strict -purpose sslserver -CAfile ca.crt server.crt`. If a certificate fails, make a new one with `subjectKeyIdentifier = hash` and `authorityKeyIdentifier = keyid` (for a CA, also `basicConstraints = critical, CA:true` and `keyUsage = critical, keyCertSign, cRLSign`). |
| Storage | A default StorageClass for ReadWriteOnce volumes, or the value `global.storageClass`. The database server, NATS, OpenBao and Valkey use volumes. The volumes must support `fsGroup` (the processes do not run as root). |
| Pod security | Every pod runs as a non-root user with a read-only root file system and meets the Pod Security Standard `restricted`. The api, the webhook handler, consent and the dashboard use the safe sysctl `net.ipv4.ip_unprivileged_port_start` (port 80). See [Security settings of the containers](security-context.md). |
| Image registry | Read access to the iGrant.io registry `europe-docker.pkg.dev/jenkins-189019/igrant-customers` (a service account key file from iGrant.io) and the release tag of your version, or your own mirror. The Google Cloud CLI (`gcloud`) on your workstation is optional. |
| OpenBao | Operators who unseal the bundled OpenBao after every restart (the Shamir seal), or your own OpenBao. See [OpenBao](openbao.md). |
| Workstation | `kubectl`, `helm`, `bash`, and `docker` to run `scripts/make-keys.sh` (it runs the api image). |

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
