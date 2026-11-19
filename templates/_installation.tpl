{{/*
The Installation section of the api, webhook and gateway files
(docs/components.md, "The services of the installation"):
{"optionalFeatures": [...], "services": ["wallet"]}. The list of services
is a constant of the chart, not a value. Without the key services, the api
and the gateway turn on all services; without the key optionalFeatures,
all optional features. So the section always has both keys. The render
fails when api.extraConfig.Installation or gateway.extraConfig.Installation
names other services than the chart. Output: JSON.
*/}}
{{- define "ow.installation.config" -}}
{{- $v := .Values -}}
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
