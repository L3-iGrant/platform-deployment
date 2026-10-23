# Connect your on-premise HSM

The platform uses the standard PKCS#11 interface for hardware security modules (HSM). It is tested with Thales Luna Network HSM in your data centre and with Thales Luna Cloud HSM (DPoD). Other PKCS#11 HSMs are supported for each customer after a validation with your HSM and its client library.

An HSM protects the keys in two ways. OpenBao can unseal itself through the HSM after each start, so no operator has to enter unseal keys. The local signing keys of the organisations can also be created and kept in the HSM, so that they never leave it. Organisations that want hardware protection for their keys, or that must run without a manual unseal, use this capability.

We set up HSM support with each customer, based on their HSM, network and security requirements. Contact support@igrant.io.

[Back to the contents](../README.md#contents)
