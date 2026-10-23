# Exposure

This page explains how the chart exposes the three public hosts of the platform, and what your ingress controller or Gateway must do.

[Back to the contents](../README.md#contents)

The chart exposes three public services. Each has a host name (`api.host`, `organisationWallet.host`, `enterpriseDashboard.host`). `exposure.*` sets the exposure of all three, and `<component>.exposure.*` the exposure of one:

| `exposure.type` | The chart creates | You give |
| --- | --- | --- |
| `ingress` (default) | A `networking.k8s.io/v1` Ingress for each host | `exposure.ingress.className`, the annotations of your controller, and the TLS Secret of each host (`<component>.exposure.tls.secretName`; empty: no TLS block) |
| `gatewayAPI` | A `gateway.networking.k8s.io/v1` HTTPRoute for each host | `exposure.gatewayAPI.parentRefs` (your Gateway: name, namespace, sectionName), and optional `timeouts` |
| `none` | Only the Services | Your own routes to the Services `<release>-gateway` (API host), `<release>-wallet-service` (wallet host) and `<release>-dashboard` (dashboard host), each on port 80 |

## What your proxy must do

Your proxy only routes the traffic: the platform does the CORS checks, the authentication and the rate limits. The chart sets no annotation of a controller. The exposure examples (`examples/exposure-*.yaml`) set what the platform needs:

- request bodies of up to 10 MiB (API and wallet hosts);
- requests of up to 60 seconds (the Envoy default is 15 seconds);
- server-sent event streams of up to 3900 seconds, without buffering (API host);
- the client address, for the rate limits and the IP allow-lists of the API keys.

With the Gateway API, the client address needs a Gateway policy that sets the header `X-Real-IP` (`examples/exposure-envoy-gateway.yaml` has one for Envoy Gateway). Set `clientAddress.header: X-Real-IP` only together with such a policy. Without the policy, leave `clientAddress.header` empty: then every request has the address of a Gateway pod, the rate limits count all clients together, and an API key with `allowedIps` refuses every call.

## The settings for each controller

| Need | ingress-nginx | Envoy Gateway, kgateway |
| --- | --- | --- |
| Request bodies of up to 10 MiB (API and wallet hosts) | `nginx.ingress.kubernetes.io/proxy-body-size: 16m` | No setting (a route has no body limit) |
| Requests of up to 60 s (wallet and dashboard hosts; the gateway of the API also waits 60 s) | No setting (the default `proxy-read-timeout` is 60 s) | `exposure.gatewayAPI.timeouts.request: 60s` (the Envoy default is 15 s: a slower request gets 504 "upstream request timeout") |
| Server-sent event streams of up to 3900 s (API host) | `proxy-read-timeout: "3900"`, `proxy-send-timeout: "3900"` | `api.exposure.timeouts.request: 3900s` |
| No buffering of the event streams (API host) | `proxy-buffering: "off"` | No setting (Envoy streams the response) |
| The client address for the rate limits and the IP allow-list of the API keys (`allowedIps`) | `clientAddress.header: X-Real-IP` | `clientAddress.header: X-Real-IP` and a Gateway policy that sets `X-Real-IP` to the client address and replaces a value that the client sends (Envoy Gateway: the ClientTrafficPolicy in `examples/exposure-envoy-gateway.yaml`; kgateway: a header policy of your Gateway that does the same) |
| The client address at the proxy | A load balancer in front of the controller passes the client address (for example the PROXY protocol: `use-proxy-protocol: "true"` in the controller configuration) | The same (Envoy Gateway: `proxyProtocol: {}` in a ClientTrafficPolicy of the Gateway) |

`exposure-kgateway.yaml` has these settings without the client address header: add the header together with the policy of your Gateway.

## Proxies in front of the cluster

Behind a CDN or another proxy, set `clientAddress.trustedProxies` and `clientAddress.trustedProxyHeader` together.

The wallet must see the `https` scheme of the public request (`X-Forwarded-Proto`): `organisationWallet.forwardedAllowIps` must contain the addresses of your proxy pods (the default is the private address ranges).
