{{/*
The services of the installation (docs/components.md, "The services of the
installation"). The installation has the organisation wallet: this release
runs it (organisationWallet.enabled), or the gateway routes to the wallet of
another release (gateway.upstreams.walletConfig.url).
*/}}

{{/*
The Installation section of the api and gateway files:
{"optionalFeatures": [...], "services": ["wallet"]}. There is no value for
the list of services. Without the key services, the api and the gateway
turn on all services; without the key optionalFeatures, all optional
features. So the section always has both keys.
The render fails when:
- the wallet is not installed (organisationWallet.enabled is false and
  gateway.upstreams.walletConfig.url is empty);
- api.extraConfig.Installation or gateway.extraConfig.Installation names
  other services than the chart does.
Output: JSON.
*/}}
{{- define "ow.installation.config" -}}
{{- $v := .Values -}}
{{- if not (or $v.organisationWallet.enabled (dig "walletConfig" "url" "" ($v.gateway.upstreams | default dict))) -}}
{{- fail "the installation needs the organisation wallet: set organisationWallet.enabled to true, or set gateway.upstreams.walletConfig.url (the wallet of another release)" -}}
{{- end -}}
{{- $services := list "wallet" -}}
{{- range $key := list "api" "gateway" -}}
{{- $extra := (index $v $key).extraConfig | default dict -}}
{{- if hasKey $extra "Installation" -}}
{{- $named := list -}}
{{- $section := get $extra "Installation" -}}
{{- if and (kindIs "map" $section) (kindIs "slice" (get $section "services")) -}}
{{- $named = get $section "services" | toStrings | uniq | sortAlpha -}}
{{- end -}}
{{- if ne (toJson $named) (toJson $services) -}}
{{- fail (printf "%s.extraConfig.Installation names other services than this release (%s): the chart writes Installation. Remove %s.extraConfig.Installation" $key (join ", " $services) $key) -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- toJson (dict "optionalFeatures" (include "ow.installation.optionalFeatures" . | fromJsonArray) "services" $services) -}}
{{- end }}

{{/*
The optional features of the installation (installation.optionalFeatures),
in the order of the list protocol1. Output: JSON list.
*/}}
{{- define "ow.installation.optionalFeatures" -}}
{{- $named := (.Values.installation | default dict).optionalFeatures | default list -}}
{{- $optional := list -}}
{{- range $feature := list "protocol1" -}}
{{- if has $feature $named -}}
{{- $optional = append $optional $feature -}}
{{- end -}}
{{- end -}}
{{- toJson $optional -}}
{{- end }}
