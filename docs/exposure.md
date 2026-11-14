# Exposure

How the chart exposes the three hosts of the platform, which hosts are public in an on-premise installation, and what your ingress controller or Gateway must do.

[Back to the contents](../README.md#contents)

The chart exposes three services, each on its own host name (`api.host`, `organisationWallet.host`, `enterpriseDashboard.host`). `exposure.*` sets the exposure of all three; `<component>.exposure.*` overrides it for one:

| `exposure.type` | The chart creates | You give |
| --- | --- | --- |
| `ingress` (default) | A `networking.k8s.io/v1` Ingress for each host | `exposure.ingress.className`, the annotations of your controller, and the TLS Secret of each host (`<component>.exposure.tls.secretName`; empty: no TLS block) |
| `gatewayAPI` | A `gateway.networking.k8s.io/v1` HTTPRoute for each host | `exposure.gatewayAPI.parentRefs` (your Gateway: name, namespace, sectionName), and optional `timeouts` |
| `none` | Only the Services | Your own routes to the Services `<release>-gateway` (API host), `<release>-wallet-service` (wallet host) and `<release>-dashboard` (dashboard host), each on port 80 |

The chart does not decide which host is public: the IngressClass, the Gateway or your own route of each host does. The Service of the wallet's config role (`<release>-wallet-config`) never gets a route: only the gateway calls it, inside the cluster. Do not create a route to it.

The install docs use `profiles/exposure-envoy-gateway.yaml` with Envoy Gateway and the Gateway `platform` of `manifests/envoy-gateway/` (see [Prerequisites](prerequisites.md#envoy-gateway)).

## On-premise installation

An on-premise installation exposes only the service routes. Only the wallet host is public; the API host and the dashboard host stay on your internal network:

| Host or Service | Network | Values |
| --- | --- | --- |
| Wallet host (`<release>-wallet-service`) | Public | `organisationWallet.exposure`: your public IngressClass (`className`) or your public Gateway (`parentRefs`) |
| API host (`<release>-gateway`) | Internal | `api.exposure`: an internal IngressClass (`className`) or an internal Gateway (`parentRefs`); or `type: none` and your own internal route |
| Dashboard host (`<release>-dashboard`) | Internal | `enterpriseDashboard.exposure`: the same as the API host |
| `<release>-wallet-config` | In the cluster only | No route |

`profiles/exposure-on-premise.yaml` does this with two ingress-nginx controllers: the public IngressClass `nginx` for the wallet host, and the internal IngressClass `nginx-internal` for the other hosts. `nginx-internal` is the default `exposure.ingress.className`, so a host stays internal unless you name the public class. The admins open the dashboard from the internal network, and their browser calls the API host there. ingress-nginx was retired on 24 March 2026 and gets no security fixes; the profile stays for clusters that still run it. With the Gateway API, attach the wallet host to a public Gateway and the other hosts to an internal Gateway (`parentRefs`, see the table above).

The wallet host serves only the wallet's public routes: the wallet's service role has only the route group `service`. The configuration routes are in the config role, which has no route.

Some parts of the dashboard need internet access from the admins' browser: the docs links and guides, and the list of supported IAMs, come from `https://docs.igrant.io`, and the docs search uses `https://typesense.igrant.io`. Without internet access, only these parts do not work.

With network policies, `networkPolicy.ingressController` is the only source of traffic to the gateway, wallet service and dashboard pods. Give a selector that matches the pods of both controllers (the example selects the namespaces `ingress-nginx` and `ingress-nginx-internal`, and sets `matchLabels: null` to remove the default labels of the Envoy pods, see [Network policies](network-policies.md#the-values-that-you-must-set)).

### The routes of the phone app

In the wallet unit flow, the wallet app on a phone calls only the wallet host (`<wallet id>` is the wallet id of the wallet provider organisation):

| Route on the wallet host | Use |
| --- | --- |
| `GET` or `POST /organisation/<wallet id>/service/wallet-provider/nonce` | The wallet provider's nonce |
| `POST /organisation/<wallet id>/service/wallet-provider/wallet-unit/request`, `.../wallet-unit/request/batch` | Wallet unit registration and WIA requests |
| `POST /organisation/<wallet id>/service/wallet-provider/key-attestation` | Key attestations |
| `GET /organisation/<wallet id>/service/revocation-statuslists/<status list id>` | The status lists of the WIAs and the key attestations |
| `GET /.well-known/openid-credential-issuer/organisation/<wallet id>/service/version-01`, `GET /.well-known/oauth-authorization-server/organisation/<wallet id>/service/wallet-provider` | The wallet provider's metadata |

After that, the app uses issuers and verifiers on their own hosts.

### The limit of the API host

The chart exposes the API host as one path (`api.exposure.path`, default `/`) to the gateway. So the API host is either public with all gateway routes, or internal with all of them. Some apps need a public gateway route, for example an individual's login, the consent `/service` routes, or the app link files `/.well-known/apple-app-site-association` and `/.well-known/assetlinks.json`. Today the chart cannot expose only these routes of the API host. With `api.exposure.type: none` you create the API host routes yourself, and the chart does not know which paths they make public.

## What your proxy must do

Your proxy only routes the traffic: the platform does the CORS checks, the authentication and the rate limits. The chart sets no controller annotations. The exposure profiles (`profiles/exposure-*.yaml`) set what the platform needs:

- request bodies of up to 10 MiB (API and wallet hosts);
- requests of up to 60 seconds (the Envoy default is 15 seconds);
- server-sent event streams of up to 3900 seconds, without buffering (API host);
- the client address, for the rate limits and the IP allow-lists of the API keys;
- request headers of up to 16 KiB each (wallet host): other vendors' wallets and verifiers send JWTs with certificate chains in headers (`OAuth-Client-Attestation`, `OAuth-Client-Attestation-PoP`, `DPoP`);
- other vendors' requests unchanged: the headers, the bodies (`application/x-www-form-urlencoded`, `application/json`, `application/jwt`) and the paths below `/.well-known/`. A web application firewall or CDN rule that changes or refuses them breaks conformance with the specifications.

With the Gateway API, the client address needs a Gateway policy that sets the header `X-Real-IP` (for Envoy Gateway: `manifests/envoy-gateway/03-client-traffic-policy.yaml`, see [Prerequisites](prerequisites.md#step-5-the-client-address)). Set `clientAddress.header: X-Real-IP` only together with such a policy. Without the policy, leave `clientAddress.header` empty. Then every request has the address of a Gateway pod: the rate limits count all clients together, and an API key with `allowedIps` refuses every call.

## The settings for each controller

ingress-nginx was retired on 24 March 2026 and gets no security fixes; its column is for clusters that still run it.

| Need | ingress-nginx | Envoy Gateway, kgateway |
| --- | --- | --- |
| Request bodies of up to 10 MiB (API and wallet hosts) | `nginx.ingress.kubernetes.io/proxy-body-size: 16m` | No setting (a route has no body limit) |
| Requests of up to 60 s (wallet and dashboard hosts; the gateway of the API also waits 60 s) | No setting (the default `proxy-read-timeout` is 60 s) | `exposure.gatewayAPI.timeouts.request: 60s` (the Envoy default is 15 s: a slower request gets 504 "upstream request timeout") |
| Request headers of up to 16 KiB each (wallet host) | `large-client-header-buffers: "4 16k"` in the controller ConfigMap (the default `4 8k` refuses a longer header line with 400) | No setting (the Envoy default is 60 KiB for all headers) |
| Server-sent event streams of up to 3900 s (API host) | `proxy-read-timeout: "3900"`, `proxy-send-timeout: "3900"` | `api.exposure.timeouts.request: 3900s` |
| No buffering of the event streams (API host) | `proxy-buffering: "off"` | No setting (Envoy streams the response) |
| The client address for the rate limits and the IP allow-list of the API keys (`allowedIps`) | `clientAddress.header: X-Real-IP` | `clientAddress.header: X-Real-IP`, and a Gateway policy that sets `X-Real-IP` to the client address and replaces any value that the client sends (Envoy Gateway: `manifests/envoy-gateway/03-client-traffic-policy.yaml`; kgateway: a header policy of your Gateway that does the same) |
| The client address at the proxy | A load balancer in front of the controller passes on the client address (for example with the PROXY protocol: `use-proxy-protocol: "true"` in the controller configuration) | The same (Envoy Gateway: `proxyProtocol` in `manifests/envoy-gateway/03-client-traffic-policy.yaml`, see [A load balancer with the PROXY protocol](prerequisites.md#a-load-balancer-with-the-proxy-protocol)) |

`exposure-kgateway.yaml` has these settings except the client address header: add the header together with the policy of your Gateway.

## Switch from ingress-nginx to Envoy Gateway

1. Install Envoy Gateway, the Gateway `platform` and its certificate (see [Envoy Gateway](prerequisites.md#envoy-gateway)). The new load balancer has a new address, and both load balancers run for a while (check the quota of your cloud).
2. Run `helm upgrade` with `profiles/exposure-envoy-gateway.yaml` in place of the ingress-nginx profile. The chart replaces the Ingresses with HTTPRoutes. With network policies, the upgrade also moves `networkPolicy.ingressController` to the Envoy pods, so ingress-nginx stops reaching the platform at that moment: do steps 2 and 3 together.
3. Point the three host names to the address of the Gateway, and wait until the DNS change is visible.
4. Remove ingress-nginx.

## Proxies in front of the cluster

These routes on the wallet host answer with `Cache-Control: max-age=60` and a strong `ETag`:

- the issuer metadata routes (`/.well-known/openid-credential-issuer/...`, `/.well-known/oauth-authorization-server/...`, `/.well-known/jwt-vc-issuer/...`);
- the JWKS of an issuer (`/organisation/<wallet id>/service/<version>/jwks` and `/organisation/<wallet id>/service/jwks`).

A request with a matching `If-None-Match` gets 304 without a body. The chart and the exposure profiles set no cache rule. A CDN or proxy that caches these answers must keep the header `Vary: Accept` of the credential issuer metadata (`Accept: application/jwt` gives the signed metadata, with its own `ETag`). A metadata change then shows within 60 seconds in the wallet pods, plus the time that your cache keeps the answer.

Behind a CDN or another proxy, set `clientAddress.trustedProxies` and `clientAddress.trustedProxyHeader` together.

The wallet must see the client address of the public request (`X-Forwarded-For`), for the rate limit of the nonce routes and for its logs: `organisationWallet.forwardedAllowIps` must contain the addresses of your proxy pods (the default is the private address ranges).

The wallet rate-limits the anonymous nonce routes (the wallet provider's nonce and the credential issuer's `c_nonce`) per client address. One address, or one IPv6 /64 network, gets at most `organisationWallet.server.nonceRequestsPerMinute` requests (default 300) in 60 seconds; more get 429 with `Retry-After`. The wallet takes the client address from `X-Forwarded-For` of a proxy in `forwardedAllowIps`, so the proxy must see the client address (row "The client address at the proxy" above). Otherwise all clients have the address of the load balancer and share one limit. Behind a carrier NAT, many phones share one IPv4 address: keep the limit above their peak requests. You can also rate-limit at the ingress, with the same client address.
