# OpenBao

This page explains the bundled OpenBao and its Shamir seal, and how to prepare your own OpenBao instead.

[Back to the contents](../README.md#contents)

OpenBao keeps the signing keys of the organisation wallet in its Transit engine. You have two options:

| `openbao.mode` | OpenBao | Example |
| --- | --- | --- |
| `bundled` (default) | The chart runs OpenBao with 3 raft nodes, TLS and the Shamir seal. | `openbao-shamir.yaml` |
| `external` | The wallet uses your OpenBao (see [External OpenBao](#external-openbao)). | `openbao-external.yaml` |

For an automatic unseal through an HSM or a Google Cloud KMS key, see [Connect your on-premise HSM](on-premise-hsm.md), [Thales Luna Cloud HSM (DPoD)](dpod.md) and [Scaled deployments](scaled-deployments.md).

## The Shamir seal

The seal protects the root key of OpenBao. With the Shamir seal, each pod is sealed and not ready after each start, until an operator unseals it with 3 of the 5 unseal keys ([install step 5](install.md#step-5-initialise-openbao-bundled-openbao-only)). Plan this for each restart of a node and for each upgrade.

Keep the unseal keys and the root token outside the cluster, for example in a password safe, with the keys held by different persons. Without the unseal keys, OpenBao stays sealed and its data is lost.

The objects that the chart creates for OpenBao, and how to renew its TLS certificate: [Chart objects](chart-objects.md#openbao).

## External OpenBao

With `openbao.mode: external`, the wallet uses your OpenBao: `openbao.external.address`, its CA in `openbao.external.caSecret`, and an optional namespace (see `examples/openbao-external.yaml`).

In your OpenBao, enable the Transit engine and give the wallet a userpass user with this policy. It is the same policy as the bootstrap of the bundled OpenBao:

```bash
bao secrets enable transit
bao policy write wallet-kms - <<'POLICY'
path "transit/keys"           { capabilities = ["list"] }
path "transit/keys/*"         { capabilities = ["create", "read", "update", "delete"] }
path "transit/sign/*"         { capabilities = ["update"] }
path "transit/wrapping_key"   { capabilities = ["read"] }
path "transit/datakey/plaintext/wallet-key-store-credentials" { capabilities = ["update"] }
path "transit/decrypt/wallet-key-store-credentials"           { capabilities = ["update"] }
POLICY
bao auth enable userpass
bao write auth/userpass/users/wallet password=- token_policies=wallet-kms   # the password on stdin
```

Then create the Secret with the same password (`openbao.wallet.existingSecret`, key `password`).

After an upgrade of the platform, compare your policy with this one: a new version can need new paths.
