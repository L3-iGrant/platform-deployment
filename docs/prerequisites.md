# Prerequisites

This page lists what your cluster, your network and your workstation need before you install the platform.

[Back to the contents](../README.md#contents)

| Item | Requirement |
| --- | --- |
| Kubernetes | 1.25 or later. |
| Helm | 3.8 or later. |
| Ingress | An ingress controller (for example ingress-nginx or Traefik) or a Gateway API implementation (for example Envoy Gateway, kgateway or Istio). The chart does not install one. With the Gateway API, your Gateway has an HTTPS listener and a policy that passes the client address (see [Exposure](exposure.md)). |
| DNS | Three host names that point to your ingress controller or Gateway: the API, the organisation wallet and the dashboard (for example `api.example.org`, `wallet.example.org` and `dashboard.example.org`). The API and the dashboard must have the same registrable domain. |
| TLS | Certificates for the three host names: TLS Secrets in the release namespace, or TLS at your Gateway or load balancer. cert-manager is optional (see `examples/exposure-ingress-nginx-cert-manager.yaml`). |
| Storage | A default StorageClass for ReadWriteOnce volumes, or the value `global.storageClass`. The database server, NATS and OpenBao use volumes. |
| Image registry | Access to the iGrant.io registry for customers (`europe-docker.pkg.dev/jenkins-189019/igrantio`, with a service account key from iGrant.io) and the release tag of your version, or your own mirror. |
| File store | A Google Cloud Storage bucket for the files of the organisation wallet (not public), or a server with the Google Cloud Storage API (`organisationWallet.storage.emulatorHost`). Create the bucket before the install. The service account of the wallet needs the roles `roles/storage.objectAdmin` and `roles/storage.legacyBucketReader` on this bucket only: the wallet reads the bucket before each upload. |
| OpenBao | Operators who unseal the bundled OpenBao after each restart (the Shamir seal), or your own OpenBao. See [OpenBao](openbao.md). |
| Workstation | `kubectl`, `helm`, `bash`, and `docker` to run `scripts/make-keys.sh` (it runs the api image). |

## Resources

The images are for Linux x86-64. With the default values, the platform requests about 1 vCPU and 4 GiB of memory in total, and 110 GiB of volumes: the database 50 GiB, NATS 3 × 10 GiB and OpenBao 3 × 10 GiB.

The minimum for tests, pilots and small installations:

| Item | Tests and pilots | Small production installation |
| --- | --- | --- |
| Nodes | 1 | 3 |
| CPU | 4 vCPU | 4 vCPU for each node |
| Memory | 8 GB | 8 GB for each node |
| Storage | 128 GB SSD | 128 GB SSD for the volumes, with backups |
| Network | 1 Gbit/s | 1 Gbit/s |

The resources grow with the number of organisations, the issuance and verification rate, the number of concurrent API calls and the size of the database. Installations with high availability, many organisations, a high transaction rate or HSM signing are sized with each customer, based on their load and availability requirements (see [Scaled deployments](scaled-deployments.md)). If you are an iGrant.io customer, contact support@igrant.io.
