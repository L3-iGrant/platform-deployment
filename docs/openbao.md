# OpenBao

The recommended OpenBao seals, your own OpenBao, and the bundled OpenBao with the seal `shamir` for development and tests.

[Back to the contents](../README.md#contents)

OpenBao keeps the organisation wallet's signing keys in its Transit engine. The seal protects the root key of OpenBao. With an HSM seal, OpenBao unseals itself after each start, and no person holds unseal keys. Choose the seal in this order:

| | Seal | When to use it | How |
| --- | --- | --- | --- |
| 1 | Your local HSM on premises: Thales Luna Network HSM | You run the installation in your data centre and have a Luna Network HSM. | The enterprise chart, or your own OpenBao with this seal (`openbao-external.yaml`). See [Connect your on-premise HSM](on-premise-hsm.md). |
| 2 | A cloud HSM: Thales Luna Cloud HSM (DPoD) | You have no HSM of your own and want an HSM partition as a service. | The enterprise chart, or your own OpenBao with this seal (`openbao-external.yaml`). See [Thales Luna Cloud HSM (DPoD)](dpod.md). |
| 3 | A cloud key management service with HSM protection: Google Cloud KMS with protection level HSM | You run the installation on Google Cloud and have no HSM partition. | The enterprise chart, or your own OpenBao with this seal (`openbao-external.yaml`). |
| 4 | Your own OpenBao that already uses one of these seals | You already run OpenBao with an HSM seal. | `openbao-external.yaml` (`openbao.mode: external`, see [External OpenBao](#external-openbao)). |

The bundled OpenBao of this chart has only the seal `shamir` (`openbao-shamir.yaml`): an HSM seal needs the enterprise chart or your own OpenBao with an HSM seal. The seal `shamir` is not for an installation that holds real keys. Use it only for development and tests, because the unseal keys are with people, and after each restart an operator must unseal each pod by hand.

`openbao.seal` has no default: give one of the two profiles, `openbao-external.yaml` or `openbao-shamir.yaml`, or the render stops.

## The Shamir seal

For development and tests only. With the Shamir seal, each pod is sealed and not ready after every start, until an operator unseals it with 3 of the 5 unseal keys ([install step 5](install.md#step-5-initialise-openbao-bundled-openbao-only)). Plan for this at every node restart and every change of the OpenBao pods.

### Restart the pods

The OpenBao pods do not restart on their own (update strategy `OnDelete`), because a restarted pod stays sealed. After a `helm upgrade`, check whether it changed the OpenBao pods (for example a new image tag or a new OpenBao configuration):

```bash
kubectl -n ows get statefulset ows-openbao -o go-template='{{or .status.updatedReplicas 0}}/{{.status.replicas}}{{"\n"}}'
```

`3/3` means no change. Otherwise, restart and unseal the pods one at a time: first the two standby pods, then the active pod (`bao status` shows `HA Mode`: `standby` or `active`). For each pod:

```bash
kubectl -n ows exec ows-openbao-2 -- bao status | grep 'HA Mode'   # standby: restart this pod first
kubectl -n ows delete pod ows-openbao-2
kubectl -n ows wait --for=jsonpath='{.status.phase}'=Running pod/ows-openbao-2 --timeout=5m
kubectl -n ows exec -it ows-openbao-2 -- bao operator unseal   # 3 times, 3 different unseal keys
```

Check: `kubectl -n ows exec ows-openbao-2 -- bao status` shows `Sealed false`. Go to the next pod only when this check passes. After the third pod, the `updatedReplicas` command shows `3/3`.

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
