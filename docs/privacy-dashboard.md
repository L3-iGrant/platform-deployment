# Privacy dashboard

This page gives the status of the privacy dashboard feature in this chart.

[Back to the contents](../README.md#contents)

The api of this release cannot deploy the privacy dashboards of the organisations in your cluster: the feature stays off, and the api answers that it is not configured. Keep `privacyDashboard.enabled: false` (the default).

`privacyDashboard.enabled: true` only gives the api pods a ServiceAccount and a Role in `privacyDashboard.namespace` (an existing namespace): `get`, `create`, `update` and `delete` of ConfigMaps, Services, Deployments and Ingresses. With network policies, also set `networkPolicy.egress.profiles.kubeApi` (the address of the Kubernetes API server).
