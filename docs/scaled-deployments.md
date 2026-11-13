# Scaled deployments

Larger and highly available installations need more than the settings of this chart. The scaled deployment runs 2 or more replicas of the API core, the webhook handler and the wallet's service and config roles. It adds disruption budgets for the gateway, the API core, the webhook handler, consent management, the wallet roles, the clock, NATS, OpenBao and Valkey, so that node maintenance does not stop a service, and it spreads their pods over nodes and zones. It scales the wallet's service role on CPU, and the wallet's worker groups on the length of their queues (KEDA). It also adds automatic unseal of OpenBao through a Google Cloud KMS key, and groups of HSM signers that serve the HSM partitions of many organisations.

We set up this capability with you, based on your requirements. Contact support@igrant.io.

[Back to the contents](../README.md#contents)
