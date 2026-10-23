# Key stores

This page explains where the organisation wallet keeps its signing keys, and which key stores the organisation admins can add.

[Back to the contents](../README.md#contents)

The organisation wallet signs with the keys of key stores.

- **The local key store** belongs to the installation, and every organisation can use it. Its keys are in the Transit engine of OpenBao.
- **Organisation key stores:** the organisation admins can add key stores of their own in the dashboard. `organisationWallet.keyStores.types` sets the types that they can add:

| Type | Key store | What the installation needs |
| --- | --- | --- |
| `vault` | An external OpenBao of the organisation (Transit engine) | Access to the address of that OpenBao. A private address needs `organisationWallet.keyStores.allowPrivateAddresses: true`. |
| `csc` | A QTSP (remote signing, CSC API) | Access to the CSC address of the QTSP. |
| `gcp-kms` | Google Cloud KMS | Outbound HTTPS to `cloudkms.googleapis.com` |
| `aws-kms` | AWS KMS | Outbound HTTPS to `kms.<region>.amazonaws.com` |
| `azure-key-vault` | Azure Key Vault or Azure Managed HSM | Outbound HTTPS to `login.microsoftonline.com` and `<vault>.vault.azure.net` or `<hsm>.managedhsm.azure.net` |

The default is `[vault, csc, gcp-kms, aws-kms, azure-key-vault]`. `[]` allows only the local key store.

The local keys of the organisations can also be in an HSM (see [Connect your on-premise HSM](on-premise-hsm.md) and [Thales Luna Cloud HSM (DPoD)](dpod.md)), and organisations can use their own Thales Luna Cloud HSM partitions (see [DPoD key stores](dpod-key-stores.md)).

The cloud key stores call only the official endpoints of their cloud: an organisation cannot set an endpoint. The wallet keeps their credentials encrypted with OpenBao Transit. With network policies, the egress profile `internet` of the wallet allows these endpoints; for a private endpoint in your network, set `networkPolicy.egress.profiles.cloudKms`. An HSM of a cloud KMS is not a certified QSCD.

The built-in test CA issues test certificates for development and testing (up to three test root CAs for each organisation). They are not on any trusted list. The test CA is on by default: turn it off (`organisationWallet.keyStores.testCa.enabled: false`) when the installation must not offer it. Without a validity in the request, a test certificate is valid for `organisationWallet.keyStores.testCa.leafValidityDays` days (default 365).
