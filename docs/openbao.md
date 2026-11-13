# OpenBao

The bundled OpenBao and its Shamir seal, and how to prepare your own OpenBao instead.

[Back to the contents](../README.md#contents)

OpenBao keeps the organisation wallet's signing keys in its Transit engine. You have two options:

| `openbao.mode` | OpenBao | Profile |
| --- | --- | --- |
| `bundled` (default) | The chart runs OpenBao with 3 raft nodes, TLS and the Shamir seal. | none (the default) |
| `external` | The wallet uses your OpenBao (see [External OpenBao](#external-openbao)). | `openbao-external.yaml` |

For automatic unseal through an HSM or a Google Cloud KMS key, see [Connect your on-premise HSM](on-premise-hsm.md), [Thales Luna Cloud HSM (DPoD)](dpod.md) and [Scaled deployments](scaled-deployments.md). A production installation must use automatic unseal through an HSM or Google Cloud KMS. The Shamir seal is for development and tests.

## The Shamir seal

The seal protects the root key of OpenBao. With the Shamir seal, each pod is sealed and not ready after every start, until an operator unseals it with 3 of the 5 unseal keys ([install step 5](install.md#step-5-initialise-openbao-bundled-openbao-only)). Plan for this at every node restart and every upgrade.

Keep the unseal keys and the root token outside the cluster, for example in a password safe, and give the keys to different people. Without the unseal keys, OpenBao stays sealed and its data is lost.

For the objects that the chart creates for OpenBao, and how to renew its TLS certificate, see [Chart objects](chart-objects.md#openbao).

## External OpenBao

With `openbao.mode: external`, the wallet uses your OpenBao: `openbao.external.address`, its CA in `openbao.external.caSecret`, and an optional namespace (see `profiles/openbao-external.yaml`).

In your OpenBao, enable the Transit engine and give the wallet a userpass user with this policy. It is the same policy that the bootstrap of the bundled OpenBao writes:

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

After each platform upgrade, compare your policy with this one: a new version can need new paths.
