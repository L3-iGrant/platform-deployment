{{/*
OpenBao helpers. The key management service of the wallet is always the
Transit engine of OpenBao: the bundled OpenBao of the chart
(openbao.mode bundled; raft storage and the Shamir seal) or an external
OpenBao (openbao.mode external). See docs/openbao.md.
*/}}

{{/* "true" when the chart runs OpenBao (openbao.mode bundled and the wallet is enabled), else "". */}}
{{- define "ow.openbao.bundled" -}}
{{- $mode := .Values.openbao.mode | default "bundled" -}}
{{- if not (has $mode (list "bundled" "external")) -}}
{{- fail (printf "openbao.mode %q is not supported: use \"bundled\" or \"external\"" $mode) -}}
{{- end -}}
{{- if and (eq $mode "bundled") .Values.organisationWallet.enabled -}}true{{- end -}}
{{- end }}

{{/* The seal of the bundled OpenBao, validated. */}}
{{- define "ow.openbao.seal" -}}
{{- $seal := .Values.openbao.seal | default "shamir" -}}
{{- if ne $seal "shamir" -}}
{{- fail (printf "openbao.seal %q is not supported: use \"shamir\" (an operator unseals each pod after each start), or set openbao.mode external" $seal) -}}
{{- end -}}
{{ $seal }}
{{- end }}

{{/* The updateStrategy type of the StatefulSet: openbao.updateStrategy, else OnDelete (a restarted pod waits sealed for an operator). */}}
{{- define "ow.openbao.updateStrategy" -}}
{{ .Values.openbao.updateStrategy | default "OnDelete" }}
{{- end }}

{{/* The address of OpenBao that the wallet uses. */}}
{{- define "ow.openbao.address" -}}
{{- if eq (.Values.openbao.mode | default "bundled") "external" -}}
{{- $address := .Values.openbao.external.address | default "" -}}
{{- if not (regexMatch "^https?://[^/\\s]+$" $address) -}}
{{- fail (printf "openbao.external.address %q is required with openbao.mode external: the address of your OpenBao, for example https://openbao.example.org:8200 (no path)" $address) -}}
{{- end -}}
{{ $address }}
{{- else -}}
{{ include "ow.openbao.addr" . }}
{{- end -}}
{{- end }}

{{/* The userpass user of the wallet. */}}
{{- define "ow.openbao.walletUser" -}}
{{- $user := .Values.openbao.wallet.user | default "wallet" -}}
{{- if not (regexMatch "^[A-Za-z0-9][A-Za-z0-9._@-]*$" $user) -}}
{{- fail (printf "openbao.wallet.user %q is not a user name (letters, digits, . _ @ -)" $user) -}}
{{- end -}}
{{ $user }}
{{- end }}

{{/*
The Secret with the password of the wallet user: openbao.wallet.existingSecret
(required with an external OpenBao), else <fullname>-openbao-wallet of the
chart. Output: JSON {secret, key}.
*/}}
{{- define "ow.openbao.walletSecret" -}}
{{- $w := .Values.openbao.wallet -}}
{{- if $w.existingSecret -}}
{{- toJson (dict "secret" $w.existingSecret "key" ($w.passwordKey | default "password")) -}}
{{- else if include "ow.openbao.bundled" . -}}
{{- toJson (dict "secret" (include "ow.name" (list . "openbao-wallet")) "key" "password") -}}
{{- else -}}
{{- fail "openbao.wallet.existingSecret is required with openbao.mode external: the Secret with the password of the OpenBao user of the wallet" -}}
{{- end -}}
{{- end }}

{{/* The CA of the OpenBao address: the TLS Secret of the bundled OpenBao, or openbao.external.caSecret. Output: JSON {secret, key} or {}. */}}
{{- define "ow.openbao.ca" -}}
{{- $external := .Values.openbao.external -}}
{{- if include "ow.openbao.bundled" . -}}
{{- toJson (dict "secret" (include "ow.openbao.tlsSecretName" .) "key" "ca.crt") -}}
{{- else if and (eq (.Values.openbao.mode | default "bundled") "external") $external.caSecret -}}
{{- toJson (dict "secret" $external.caSecret "key" ($external.caKey | default "ca.crt")) -}}
{{- else -}}
{{- toJson dict -}}
{{- end -}}
{{- end }}

{{/* The mount path of the Transit engine, validated. */}}
{{- define "ow.openbao.transitMount" -}}
{{- $mount := .Values.openbao.transitMount | default "transit" -}}
{{- if or (not (regexMatch "^[A-Za-z0-9][A-Za-z0-9._/-]*$" $mount)) (hasSuffix "/" $mount) -}}
{{- fail (printf "openbao.transitMount %q is not a mount path: letters, digits, . _ / - (no / at the end)" $mount) -}}
{{- end -}}
{{ $mount }}
{{- end }}

{{/* The OpenBao namespace of the wallet ("" with the bundled OpenBao: the root namespace). */}}
{{- define "ow.openbao.namespace" -}}
{{- if eq (.Values.openbao.mode | default "bundled") "external" -}}
{{ .Values.openbao.external.namespace | default "" }}
{{- end -}}
{{- end }}

{{/* Name of the StatefulSet and of the client Service. */}}
{{- define "ow.openbao.name" -}}
{{ include "ow.name" (list . "openbao") }}
{{- end }}

{{/* Name of the headless Service (raft peers, pod DNS names). */}}
{{- define "ow.openbao.headlessName" -}}
{{ include "ow.name" (list . "openbao-headless") }}
{{- end }}

{{/* Name of the TLS Secret (tls.crt, tls.key, ca.crt) of the listener. */}}
{{- define "ow.openbao.tlsSecretName" -}}
{{- .Values.openbao.tls.existingSecret | default (include "ow.name" (list . "openbao-tls")) -}}
{{- end }}

{{/* Address of the client Service that the wallet uses. */}}
{{- define "ow.openbao.addr" -}}
https://{{ include "ow.openbao.name" . }}.{{ .Release.Namespace }}.svc:8200
{{- end }}

{{/* DNS name of one pod. Call with (list $ <ordinal>). */}}
{{- define "ow.openbao.podHost" -}}
{{- $root := index . 0 -}}
{{ include "ow.openbao.name" $root }}-{{ index . 1 }}.{{ include "ow.openbao.headlessName" $root }}.{{ $root.Release.Namespace }}.svc
{{- end }}

{{/* Fixed paths in the OpenBao container. */}}
{{- define "ow.openbao.paths" -}}
{{- toJson (dict
  "config" "/openbao/config/openbao.hcl"
  "scripts" "/openbao/scripts"
  "tls" "/openbao/tls"
  "bootstrap" "/openbao/bootstrap"
  "data" "/openbao/data") -}}
{{- end }}

{{/*
Render guards of the chart OpenBao. The values go into the HCL
configuration, so the guards also allow only safe characters. Output:
nothing.
*/}}
{{- define "ow.openbao.check" -}}
{{- $v := .Values -}}
{{- $ob := $v.openbao -}}
{{- $_ := include "ow.openbao.transitMount" . -}}
{{- $_ := include "ow.openbao.seal" . -}}
{{- $replicas := $ob.replicas | int -}}
{{- if or (lt $replicas 1) (eq (mod $replicas 2) 0) -}}
{{- fail (printf "openbao.replicas (%v) must be an odd number (1, 3 or 5): a raft cluster needs a majority of its nodes" $ob.replicas) -}}
{{- end -}}
{{- if not (has $ob.logLevel (list "trace" "debug" "info" "warn" "error")) -}}
{{- fail (printf "openbao.logLevel %q is not supported: trace, debug, info, warn or error" $ob.logLevel) -}}
{{- end -}}
{{- end }}

{{/*
The server configuration of OpenBao (HCL, ConfigMap key openbao.hcl). No
secret is in it. The values of each pod come from the environment
(BAO_RAFT_NODE_ID, BAO_API_ADDR, BAO_CLUSTER_ADDR). OpenBao 2.7 has no
mlock: no disable_mlock.
*/}}
{{- define "ow.openbao.config" -}}
{{- $ob := .Values.openbao -}}
{{- $seal := include "ow.openbao.seal" . -}}
{{- $paths := include "ow.openbao.paths" . | fromJson -}}
# OpenBao server configuration of the chart (seal {{ $seal }}). No secret is
# in this file. Per pod: BAO_RAFT_NODE_ID, BAO_API_ADDR, BAO_CLUSTER_ADDR.
ui        = false
log_level = {{ $ob.logLevel | quote }}

# Standby nodes send every request to the active node. The wallet reads a
# key just after it makes it; a standby that answers reads itself can be
# behind the active node and answers "not found".
disable_standby_reads = true

listener "tcp" {
  address         = "0.0.0.0:8200"
  cluster_address = "0.0.0.0:8201"
  tls_cert_file   = "{{ $paths.tls }}/tls.crt"
  tls_key_file    = "{{ $paths.tls }}/tls.key"
  tls_min_version = "tls12"
}

storage "raft" {
  path = "{{ $paths.data }}/raft"
  {{- range $i := until ($ob.replicas | int) }}

  retry_join {
    leader_api_addr     = "https://{{ include "ow.openbao.podHost" (list $ $i) }}:8200"
    leader_ca_cert_file = "{{ $paths.tls }}/ca.crt"
  }
  {{- end }}
}

# No seal stanza: the Shamir seal. An operator unseals each pod after each
# start (bao operator unseal).
{{- if $ob.audit.stdout }}

# Audit device: one JSON line per request and response on stdout (the
# values are HMAC-SHA256 hashes). OpenBao 2.7 enables audit devices only
# from the configuration file.
audit "file" "stdout" {
  description = "Audit log on stdout"
  options {
    file_path = "stdout"
  }
}
{{- end }}
{{- with $ob.extraConfig }}

# openbao.extraConfig
{{ . }}
{{- end }}
{{- end }}
