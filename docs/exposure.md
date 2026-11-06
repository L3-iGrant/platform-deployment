# Exposure

This page explains how the chart exposes the three hosts of the platform, which hosts are public in an on-premise installation, and what your ingress controller or Gateway must do.

[Back to the contents](../README.md#contents)

The chart exposes three services. Each has a host name (`api.host`, `organisationWallet.host`, `enterpriseDashboard.host`). `exposure.*` sets the exposure of all three, and `<component>.exposure.*` the exposure of one:

| `exposure.type` | The chart creates | You give |
| --- | --- | --- |
| `ingress` (default) | A `networking.k8s.io/v1` Ingress for each host | `exposure.ingress.className`, the annotations of your controller, and the TLS Secret of each host (`<component>.exposure.tls.secretName`; empty: no TLS block) |
| `gatewayAPI` | A `gateway.networking.k8s.io/v1` HTTPRoute for each host | `exposure.gatewayAPI.parentRefs` (your Gateway: name, namespace, sectionName), and optional `timeouts` |
| `none` | Only the Services | Your own routes to the Services `<release>-gateway` (API host), `<release>-wallet-service` (wallet host) and `<release>-dashboard` (dashboard host), each on port 80 |

The chart does not decide which host is public: the IngressClass, the Gateway or your own routes of each host decide. The Service of the config role of the wallet (`<release>-wallet-config`) never has a route: only the gateway calls it, inside the cluster. Do not make a route to it.

## On-premise installation

An on-premise installation exposes only the service routes. Only the wallet host is public; the API host and the dashboard host stay on your internal network:

| Host or Service | Network | Values |
| --- | --- | --- |
| Wallet host (`<release>-wallet-service`) | Public | `organisationWallet.exposure`: your public IngressClass (`className`) or your public Gateway (`parentRefs`) |
| API host (`<release>-gateway`) | Internal | `api.exposure`: an internal IngressClass (`className`) or an internal Gateway (`parentRefs`); or `type: none` and your own internal route |
| Dashboard host (`<release>-dashboard`) | Internal | `enterpriseDashboard.exposure`: the same as the API host |
| `<release>-wallet-config` | In the cluster only | No route |

`examples/exposure-on-premise.yaml` does this with two ingress-nginx controllers: the public IngressClass `nginx` for the wallet host, and the internal IngressClass `nginx-internal` for the other hosts (the default `exposure.ingress.className`, so that a host is internal unless you name the public class). The admins open the dashboard from the internal network, and their browser calls the API host there.

The wallet host serves only the public routes of the wallet: the service role of the wallet has only the route group `service`. The configuration routes are in the config role, which has no route.

With network policies, `networkPolicy.ingressController` is the one source of the gateway, wallet service and dashboard pods: give a selector that selects the pods of both controllers (the example selects the namespaces `ingress-nginx` and `ingress-nginx-internal`).

### The routes of the phone app

For the wallet unit flow, the wallet app of a phone calls only the wallet host (`<wallet id>`: the wallet id of the wallet provider organisation):

| Route on the wallet host | Use |
| --- | --- |
| `GET` or `POST /organisation/<wallet id>/service/wallet-provider/nonce` | The nonce of the wallet provider |
| `POST /organisation/<wallet id>/service/wallet-provider/wallet-unit/request`, `.../wallet-unit/request/batch` | The registration of a wallet unit and its WIA requests |
| `POST /organisation/<wallet id>/service/wallet-provider/key-attestation` | The key attestations |
| `GET /organisation/<wallet id>/service/revocation-statuslists/<status list id>` | The status lists of the WIAs and of the key attestations |
| `GET /.well-known/openid-credential-issuer/organisation/<wallet id>/service/version-01`, `GET /.well-known/oauth-authorization-server/organisation/<wallet id>/service/wallet-provider` | The metadata of the wallet provider |

The issuers and verifiers that the app uses after that are at their own hosts.

### The limit of the API host

The chart exposes the API host as one path (`api.exposure.path`, default `/`) to the gateway: the API host is public with all the routes of the gateway, or internal with all of them. Some apps need a public route of the gateway, for example the login of an individual, the `/service` routes of consent, or the app link files `/.well-known/apple-app-site-association` and `/.well-known/assetlinks.json`. The chart cannot expose only these routes of the API host today. With `api.exposure.type: none` you make the routes of the API host yourself, and the chart does not know which paths they make public.

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

The metadata routes of the issuers on the wallet host (`/.well-known/openid-credential-issuer/...`, `/.well-known/oauth-authorization-server/...`, `/.well-known/jwt-vc-issuer/...`) and the JWKS of an issuer (`/organisation/<wallet id>/service/<version>/jwks` and `/organisation/<wallet id>/service/jwks`) answer with `Cache-Control: max-age=60` and a strong `ETag`; a request with a matching `If-None-Match` gets 304 without a body. The chart and the exposure examples set no cache rule. A CDN or a proxy that keeps these answers must keep the header `Vary: Accept` of the credential issuer metadata (`Accept: application/jwt` gives the signed metadata, with its own `ETag`). A change of the metadata then shows after at most 60 seconds in the wallet pods, plus the time that your cache keeps the answer.

Behind a CDN or another proxy, set `clientAddress.trustedProxies` and `clientAddress.trustedProxyHeader` together.

The wallet must see the `https` scheme of the public request (`X-Forwarded-Proto`): `organisationWallet.forwardedAllowIps` must contain the addresses of your proxy pods (the default is the private address ranges).

The wallet limits the anonymous nonce routes (the nonce of the wallet provider and the `c_nonce` of the credential issuer) for each client address: at most `organisationWallet.server.nonceRequestsPerMinute` requests (default 300) of one address, or of one IPv6 /64 network, in 60 seconds; more get 429 with `Retry-After`. The wallet takes the client address from `X-Forwarded-For` of a proxy of `forwardedAllowIps`, so the proxy must see the client address (the row "The client address at the proxy" above). Without it, all clients have the address of the load balancer and share one limit. Behind a carrier NAT many phones share one IPv4 address: keep the limit above their requests at peak. You can also limit the rate at the ingress, with the same client address.
