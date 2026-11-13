# Connect your on-premise HSM

The platform uses the standard PKCS#11 interface for hardware security modules (HSM). It is tested with Thales Luna Network HSM in your data centre and with Thales Luna Cloud HSM (DPoD). Other PKCS#11 HSMs are supported after a validation with your HSM and its client library.

An HSM protects the keys in two ways. OpenBao unseals itself through the HSM after each start, so no operator has to enter unseal keys. And the organisations' local signing keys can be created and kept in the HSM, so they never leave it. Use this capability when you want hardware protection for the keys, or when you must run without a manual unseal.

We set up HSM support with you, based on your HSM, network and security requirements. Contact support@igrant.io.

[Back to the contents](../README.md#contents)
