# Chart objects

This page lists the objects that the chart creates for OpenBao. For the Secrets of the keys and the passwords, see [Keys](keys.md).

[Back to the contents](../README.md#contents)

## OpenBao

The objects of the bundled OpenBao (`openbao.mode: bundled`):

| Object | Function |
| --- | --- |
| `<release>-openbao` (StatefulSet, Service, ConfigMap) | OpenBao with raft storage, its configuration, the entrypoint and `bootstrap.sh` |
| `<release>-openbao-headless` (Service) | The pod names of the raft nodes |
| `<release>-openbao-tls` (Secret) | The CA and the certificate of the listener (10 years). To use your own certificate, set `openbao.tls.existingSecret`. |
| `<release>-openbao-wallet` (Secret) | The password of the user `wallet` (random); `bootstrap.sh` sets it in OpenBao |

New certificates: delete the Secret `<release>-openbao-tls`, run `helm upgrade`, then restart the OpenBao pods and the wallet pods.
