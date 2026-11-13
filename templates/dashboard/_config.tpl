{{/*
config.json of the dashboard (ConfigMap <release>-dashboard). The pod
checksum is taken from this text, so a change restarts the pods: the
image's start scripts read the file at start, for example for the
Content-Security-Policy.
baseUrl: the api (the dashboard's CSP connect-src also comes from it).
walletUrl: the organisation wallet (vct metadata of the credential types).
Empty means the public URLs of api.host and organisationWallet.host.
Without the wallet (ow.installation.has) there is no walletUrl: the
dashboard shows no wallet area and the chart needs no
organisationWallet.host.
individualImportMaxFileBytes, individualImportMaxRows: the api's limits for
the CSV import of individuals (api.extraConfig.Uploads, the single source),
set only when configured; otherwise the dashboard uses the api defaults.
Call with the root context. Output: the JSON text.
*/}}
{{- define "ow.dashboard.config" -}}
{{- $d := .Values.enterpriseDashboard -}}
{{- $baseUrl := $d.configuration.baseUrl -}}
{{- if not $baseUrl }}{{- $baseUrl = include "ow.publicUrlOf" (list . "api") }}{{- end -}}
{{- $walletUrl := $d.configuration.walletUrl -}}
{{- if and (not $walletUrl) (include "ow.installation.has" (list . "wallet")) }}{{- $walletUrl = include "ow.publicUrlOf" (list . "organisationWallet") }}{{- end -}}
{{- $config := dict
  "baseUrl" $baseUrl
  "appVersion" ($d.configuration.appVersion | default ($d.image.tag | toString | default (.Values.global.imageTag | toString))) -}}
{{- with $walletUrl }}{{- $_ := set $config "walletUrl" . }}{{- end -}}
{{- range $key, $value := include "ow.api.importLimits" . | fromJson -}}
{{- $_ := set $config $key ($value | int64) -}}
{{- end -}}
{{- $config | toPrettyJson -}}
{{- end }}
