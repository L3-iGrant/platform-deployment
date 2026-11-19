{{/*
config.json of the dashboard (ConfigMap <release>-dashboard). The pod
checksum is taken from this text, so a change restarts the pods: the
image's start scripts read the file at start, for example for the
Content-Security-Policy.
baseUrl: the api (the dashboard's CSP connect-src also comes from it). The
chart writes no apiIssuer, so the dashboard checks the issuer of the api's
login answers against baseUrl: it must be the api's public URL.
walletUrl: the organisation wallet. Only the CSP reads it (the vct metadata
of the credential types); the app does not.
Empty means the public URLs of api.host and organisationWallet.host.
Call with the root context. Output: the JSON text.
*/}}
{{- define "ow.dashboard.config" -}}
{{- $d := .Values.enterpriseDashboard -}}
{{- $baseUrl := $d.configuration.baseUrl -}}
{{- if not $baseUrl }}{{- $baseUrl = include "ow.publicUrlOf" (list . "api") }}{{- end -}}
{{- $walletUrl := $d.configuration.walletUrl -}}
{{- if not $walletUrl }}{{- $walletUrl = include "ow.publicUrlOf" (list . "organisationWallet") }}{{- end -}}
{{- $config := dict
  "baseUrl" $baseUrl
  "walletUrl" $walletUrl
  "appVersion" ($d.configuration.appVersion | default ($d.image.tag | toString | default (.Values.global.imageTag | toString))) -}}
{{- $config | toPrettyJson -}}
{{- end }}
