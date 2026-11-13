{{/*
config.json of the dashboard (the ConfigMap <release>-dashboard; the
checksum of the pods is of this text, so a change restarts them: the start
scripts of the image read the file at the start, for example for the
Content-Security-Policy).
baseUrl: the api (the CSP connect-src of the dashboard also comes from it).
walletUrl: the organisation wallet (vct metadata of the credential types).
Empty: the public URLs of api.host and organisationWallet.host. Without the
wallet (ow.installation.has), no walletUrl: the dashboard shows no wallet
area, and the chart needs no organisationWallet.host.
individualImportMaxFileBytes, individualImportMaxRows: the limits of the CSV
import of individuals of the api (api.extraConfig.Uploads, one source),
only when they are set: without them the dashboard
uses the defaults of the api.
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
