{{/*
config.json of the dashboard (ConfigMap <release>-dashboard). The pod
checksum is taken from this text, so a change restarts the pods: the
image's start scripts read the file at start, for example for the
Content-Security-Policy.
baseUrl: the public URL of api.host (the dashboard's CSP connect-src also
comes from it). The chart writes no apiIssuer, so the dashboard checks the
issuer of the api's login answers against baseUrl.
walletUrl: the public URL of organisationWallet.host. Only the CSP reads it
(the vct metadata of the credential types); the app does not.
appVersion: the image tag of the dashboard.
Call with the root context. Output: the JSON text.
*/}}
{{- define "ow.dashboard.config" -}}
{{- $d := .Values.enterpriseDashboard -}}
{{- $config := dict
  "baseUrl" (include "ow.publicUrlOf" (list . "api"))
  "walletUrl" (include "ow.publicUrlOf" (list . "organisationWallet"))
  "appVersion" ($d.image.tag | toString | default (.Values.global.imageTag | toString)) -}}
{{- $config | toPrettyJson -}}
{{- end }}
