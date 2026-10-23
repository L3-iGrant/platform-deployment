{{/*
Common helpers: names, labels, images, scheduling and the exposure of the
public services.

Each object name is "<fullname>-<component>". The fullname is
fullnameOverride, else the release name.
*/}}

{{- define "ow.fullname" -}}
{{- .Values.fullnameOverride | default .Release.Name | trunc 40 | trimSuffix "-" -}}
{{- end }}

{{/* Name of a component object. Call with (list $ "component"). */}}
{{- define "ow.name" -}}
{{- $root := index . 0 -}}
{{- printf "%s-%s" (include "ow.fullname" $root) (index . 1) | trunc 63 | trimSuffix "-" -}}
{{- end }}

{{/* Selector labels. Call with (list $ "component"). */}}
{{- define "ow.selectorLabels" -}}
{{- $root := index . 0 -}}
app.kubernetes.io/name: {{ $root.Chart.Name }}
app.kubernetes.io/instance: {{ $root.Release.Name }}
app.kubernetes.io/component: {{ index . 1 }}
{{- end }}

{{/* All labels. Call with (list $ "component"). */}}
{{- define "ow.labels" -}}
{{- $root := index . 0 -}}
{{ include "ow.selectorLabels" . }}
app.kubernetes.io/part-of: organisation-wallet-suite
app.kubernetes.io/managed-by: {{ $root.Release.Service }}
helm.sh/chart: {{ printf "%s-%s" $root.Chart.Name $root.Chart.Version | replace "+" "_" }}
{{- with $root.Values.global.labels }}
{{ toYaml . }}
{{- end }}
{{- end }}

{{/*
Container image. Call with (list $ .Values.<component>.image).
The registry is image.registry, else global.imageRegistry; the tag is
image.tag, else global.imageTag (the release tag of the iGrant.io images). An
empty registry gives "repository:tag".
*/}}
{{- define "ow.image" -}}
{{- $root := index . 0 -}}
{{- $image := index . 1 -}}
{{- $registry := $image.registry | default $root.Values.global.imageRegistry -}}
{{- $tag := $image.tag | toString | default ($root.Values.global.imageTag | toString) -}}
{{- $reference := printf "%s:%s" $image.repository $tag -}}
{{- if $image.digest }}{{- $reference = printf "%s@%s" $image.repository $image.digest -}}{{- end -}}
{{- if $registry -}}
{{ printf "%s/%s" (trimSuffix "/" $registry) $reference }}
{{- else -}}
{{ $reference }}
{{- end -}}
{{- end }}

{{/* imagePullPolicy. Call with (list $ .Values.<component>.image). */}}
{{- define "ow.imagePullPolicy" -}}
{{- $root := index . 0 -}}
{{- (index . 1).pullPolicy | default $root.Values.global.imagePullPolicy | default "IfNotPresent" -}}
{{- end }}

{{/*
Pod-level fields that every workload shares: image pull secrets, priority
class, scheduling and pod security context. Call with
(list $ .Values.<component>). Output starts at the pod spec indentation.
*/}}
{{- define "ow.podSpecCommon" -}}
{{- $root := index . 0 -}}
{{- $component := index . 1 -}}
{{- $pullSecrets := concat ($root.Values.global.imagePullSecrets | default list) ($component.imagePullSecrets | default list) | uniq -}}
{{- with $pullSecrets }}
imagePullSecrets:
{{- range . }}
  - name: {{ . }}
{{- end }}
{{- end }}
{{- with ($component.priorityClassName | default $root.Values.global.priorityClassName) }}
priorityClassName: {{ . }}
{{- end }}
{{- with ($component.podSecurityContext | default $root.Values.global.podSecurityContext) }}
securityContext:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- with ($component.nodeSelector | default $root.Values.global.nodeSelector) }}
nodeSelector:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- with ($component.tolerations | default $root.Values.global.tolerations) }}
tolerations:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- with ($component.affinity | default $root.Values.global.affinity) }}
affinity:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- end }}

{{/* Container security context. Call with (list $ .Values.<component>). */}}
{{- define "ow.containerSecurityContext" -}}
{{- $root := index . 0 -}}
{{- $component := index . 1 -}}
{{- with ($component.containerSecurityContext | default $root.Values.global.containerSecurityContext) }}
securityContext:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- end }}

{{/* Storage class line of a volume claim. Call with (list $ "<component storageClass>"). */}}
{{- define "ow.storageClass" -}}
{{- $root := index . 0 -}}
{{- $storageClass := (index . 1) | default $root.Values.global.storageClass -}}
{{- if $storageClass }}
{{- if eq $storageClass "-" }}
storageClassName: ""
{{- else }}
storageClassName: {{ $storageClass }}
{{- end }}
{{- end }}
{{- end }}

{{/* Public base URL of a public component: "https://<host>". Call with (list $ "api"|"organisationWallet"|"enterpriseDashboard"). */}}
{{- define "ow.publicUrlOf" -}}
{{- include "ow.publicUrl" (list (index . 0) (include "ow.host" .)) -}}
{{- end }}

{{/* Public base URL of a host: "https://<host>". Call with (list $ "<host>"). */}}
{{- define "ow.publicUrl" -}}
{{- $root := index . 0 -}}
{{- printf "%s://%s" ($root.Values.global.publicScheme | default "https") (index . 1) -}}
{{- end }}

{{/*
Public host name of one public component (required). Call with (list $
"api"|"organisationWallet"|"enterpriseDashboard").
*/}}
{{- define "ow.host" -}}
{{- $root := index . 0 -}}
{{- $key := index . 1 -}}
{{- $host := (index $root.Values $key).host | default "" -}}
{{- if not $host -}}
{{- fail (printf "%s.host is required: the public host name of the %s (for example %s.example.org)" $key $key (get (dict "api" "api" "organisationWallet" "wallet" "enterpriseDashboard" "dashboard") $key)) -}}
{{- end -}}
{{- if not (regexMatch "^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$" $host) -}}
{{- fail (printf "%s.host %q is not a host name (lower-case DNS name, no scheme, no port, no path)" $key $host) -}}
{{- end -}}
{{ $host }}
{{- end }}

{{/*
The exposure of one public component (exposure.type, or
<component>.exposure.type): "ingress" renders a networking.k8s.io/v1
Ingress, "gatewayAPI" a gateway.networking.k8s.io/v1 HTTPRoute to the
Gateway of the admin, "none" nothing (only the Service). The chart never
renders a controller-specific setting: the annotations are free form. Call
with (dict "root" $ "key" "<values key>" "component" "<name suffix>"
"service" "<Service name>" "port" <Service port>).
*/}}
{{- define "ow.exposure" -}}
{{- $root := .root -}}
{{- $global := $root.Values.exposure -}}
{{- $values := index $root.Values .key -}}
{{- $exposure := $values.exposure | default dict -}}
{{- $type := $exposure.type | default $global.type -}}
{{- if not (has $type (list "ingress" "gatewayAPI" "none")) -}}
{{- fail (printf "%s.exposure.type (or exposure.type) %q is not supported: use ingress, gatewayAPI or none" .key $type) -}}
{{- end -}}
{{- $host := include "ow.host" (list $root .key) -}}
{{- $path := $exposure.path | default "/" -}}
{{- $pathType := $exposure.pathType | default "Prefix" -}}
{{- if not (has $pathType (list "Prefix" "Exact")) -}}
{{- fail (printf "%s.exposure.pathType %q is not supported: use Prefix or Exact" .key $pathType) -}}
{{- end -}}
{{- if eq $type "ingress" }}
{{- $annotations := merge (dict) ($exposure.annotations | default dict) ($global.ingress.annotations | default dict) }}
{{- $className := $exposure.className | default $global.ingress.className }}
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: {{ include "ow.name" (list $root .component) }}
  namespace: {{ $root.Release.Namespace }}
  labels:
    {{- include "ow.labels" (list $root .component) | nindent 4 }}
  {{- with $annotations }}
  annotations:
    {{- toYaml . | nindent 4 }}
  {{- end }}
spec:
  {{- with $className }}
  ingressClassName: {{ . }}
  {{- end }}
  {{- with ($exposure.tls | default dict).secretName }}
  tls:
    - hosts:
        - {{ $host | quote }}
      secretName: {{ . }}
  {{- end }}
  rules:
    - host: {{ $host | quote }}
      http:
        paths:
          - path: {{ $path }}
            pathType: {{ $pathType }}
            backend:
              service:
                name: {{ .service }}
                port:
                  number: {{ .port }}
{{- else if eq $type "gatewayAPI" }}
{{- $annotations := merge (dict) ($exposure.annotations | default dict) ($global.gatewayAPI.annotations | default dict) }}
{{- $parentRefs := $exposure.parentRefs | default $global.gatewayAPI.parentRefs }}
{{- if not $parentRefs }}
{{- fail (printf "%s.exposure.parentRefs (or exposure.gatewayAPI.parentRefs) is required for gatewayAPI: the Gateway of the route, for example [{name: platform, namespace: gateway-system, sectionName: https}]" .key) }}
{{- end }}
{{- $timeouts := $exposure.timeouts | default $global.gatewayAPI.timeouts }}
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: {{ include "ow.name" (list $root .component) }}
  namespace: {{ $root.Release.Namespace }}
  labels:
    {{- include "ow.labels" (list $root .component) | nindent 4 }}
  {{- with $annotations }}
  annotations:
    {{- toYaml . | nindent 4 }}
  {{- end }}
spec:
  parentRefs:
    {{- toYaml $parentRefs | nindent 4 }}
  hostnames:
    - {{ $host | quote }}
  rules:
    - matches:
        - path:
            type: {{ ternary "PathPrefix" "Exact" (eq $pathType "Prefix") }}
            value: {{ $path }}
      backendRefs:
        - name: {{ .service }}
          port: {{ .port }}
      {{- with $timeouts }}
      timeouts:
        {{- toYaml . | nindent 8 }}
      {{- end }}
{{- end }}
{{- end }}

{{/* checksum annotation of a values block. Call with (list "<name>" <value>). */}}
{{- define "ow.checksum" -}}
checksum/{{ index . 0 }}: {{ index . 1 | toYaml | sha256sum }}
{{- end }}
