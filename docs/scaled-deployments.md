# Scaled deployments

Larger and highly available installations need more than the settings of this chart. The scaled deployment adds disruption budgets for the gateway, consent management, NATS and OpenBao, so that node maintenance does not stop a service, and spreads their pods over the nodes. It also adds automatic unseal of OpenBao through a Google Cloud KMS key, and groups of HSM signers that serve the HSM partitions of many organisations.

We set up this capability with each customer, based on their requirements. Contact support@igrant.io.

[Back to the contents](../README.md#contents)
