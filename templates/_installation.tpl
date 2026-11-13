{{/*
The services of the installation (docs/components.md, "The services of the
installation"). An installation has consent, the organisation wallet, or
both. A service is installed when this release runs it (consent.enabled,
organisationWallet.enabled) or when the gateway routes to it in another
release (gateway.upstreams.consent.url, gateway.upstreams.walletConfig.url).
When both are empty, the service is not installed: the gateway answers 404
on its routes, and no process in the release reads its views or trusts its
keys.

A release without the api (api.enabled false) has no gateway and no
upstream URLs, so it cannot tell which services are installed. It keeps
all services, as earlier releases did.
*/}}

{{/*
"true" when one service is installed, else "". Call with (list $
"consent"|"wallet").
*/}}
{{- define "ow.installation.has" -}}
{{- $root := index . 0 -}}
{{- $service := index . 1 -}}
{{- $v := $root.Values -}}
{{- $upstreams := $v.gateway.upstreams | default dict -}}
{{- if eq $service "consent" -}}
{{- if or (not $v.api.enabled) $v.consent.enabled (dig "consent" "url" "" $upstreams) -}}true{{- end -}}
{{- else if eq $service "wallet" -}}
{{- if or (not $v.api.enabled) $v.organisationWallet.enabled (dig "walletConfig" "url" "" $upstreams) -}}true{{- end -}}
{{- else -}}
{{- fail (printf "ow.installation.has: unknown service %q" $service) -}}
{{- end -}}
{{- end }}

{{/*
The installed services, in the order wallet, consent. Output: JSON list.
*/}}
{{- define "ow.installation.services" -}}
{{- $services := list -}}
{{- range $service := list "wallet" "consent" -}}
{{- if include "ow.installation.has" (list $ $service) -}}
{{- $services = append $services $service -}}
{{- end -}}
{{- end -}}
{{- toJson $services -}}
{{- end }}

{{/*
The Installation section of the api and gateway files: {} when all services
are installed (the files stay the same, so an image from an earlier release
still starts), else {"services": [...]}. There is no value for the list.
The render fails when:
- no service is installed (an installation needs consent or the wallet);
- privacyDashboard.enabled is true and consent is not installed;
- api.extraConfig.Installation or gateway.extraConfig.Installation names
  other services than the chart does.
Output: JSON.
*/}}
{{- define "ow.installation.config" -}}
{{- $v := .Values -}}
{{- $services := include "ow.installation.services" . | fromJsonArray -}}
{{- if not $services -}}
{{- fail "the installation has no service: set consent.enabled or organisationWallet.enabled to true, or set the URL of the service of another release (gateway.upstreams.consent.url, gateway.upstreams.walletConfig.url)" -}}
{{- end -}}
{{- if and $v.privacyDashboard.enabled (not (has "consent" $services)) -}}
{{- fail "privacyDashboard.enabled needs the consent service: each function of the privacy dashboard is a consent route. Set privacyDashboard.enabled to false, or install consent (consent.enabled, or gateway.upstreams.consent.url)" -}}
{{- end -}}
{{- range $key := list "api" "gateway" -}}
{{- $extra := (index $v $key).extraConfig | default dict -}}
{{- if hasKey $extra "Installation" -}}
{{- $named := list -}}
{{- $section := get $extra "Installation" -}}
{{- if and (kindIs "map" $section) (kindIs "slice" (get $section "services")) -}}
{{- $named = get $section "services" | toStrings | uniq | sortAlpha -}}
{{- end -}}
{{- if ne (toJson $named) (toJson ($services | sortAlpha)) -}}
{{- fail (printf "%s.extraConfig.Installation names other services than this release (%s): the chart writes Installation from consent.enabled, organisationWallet.enabled and gateway.upstreams. Remove %s.extraConfig.Installation" $key (join ", " $services) $key) -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- if eq (len $services) 2 -}}
{{- toJson dict -}}
{{- else -}}
{{- toJson (dict "services" $services) -}}
{{- end -}}
{{- end }}

{{/*
Issuers of signed NATS envelopes that the api, consent or the wallet trusts:
the given issuers, limited to the installed services (igrant-api always,
igrant-consent-management with consent, eudi-wallet with the wallet). Call
with (list $ "<issuer>" ...). Output: JSON list.
*/}}
{{- define "ow.installation.issuers" -}}
{{- $root := index . 0 -}}
{{- $services := dict "igrant-api" "" "igrant-consent-management" "consent" "eudi-wallet" "wallet" -}}
{{- $issuers := list -}}
{{- range $issuer := rest . -}}
{{- $service := get $services $issuer -}}
{{- if or (not $service) (include "ow.installation.has" (list $root $service)) -}}
{{- $issuers = append $issuers $issuer -}}
{{- end -}}
{{- end -}}
{{- toJson $issuers -}}
{{- end }}
