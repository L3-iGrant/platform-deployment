{{/*
Database helpers. The whole platform uses ONE engine (database.engine) and
one server (database.mode: bundled or external). Each component has its own
database and owner user, and the user name is the database name. Every
component config file, Job and NetworkPolicy takes the engine, host, port
and TLS settings from these helpers only.
*/}}

{{/*
Supported engines and their facts: the name suffix of the bundled server
objects, the port, the admin user of the bundled server and the key of its
password in the database Secret. PostgreSQL is the only engine. The other
helpers read the facts from here, so a new engine needs a new entry, a
server template (templates/database/<engine>.yaml, with the values
database.<engine>), an init script (init.yaml) and a section in ow.db.go
and ow.db.wallet. Output: JSON.
*/}}
{{- define "ow.db.engines" -}}
{{- toJson (dict
  "postgresql" (dict "server" "postgres" "port" 5432 "adminUser" "postgres" "adminPasswordKey" "POSTGRES_PASSWORD")) -}}
{{- end }}

{{/*
The engine of all components, validated. The api, consent and the
organisation wallet only accept the engines in ow.db.engines, so any other
value (for example mysql) fails the render with a message that names them.
values.schema.json has no enum for database.engine, because a schema error
cannot name the components.
*/}}
{{- define "ow.db.engine" -}}
{{- $engine := .Values.database.engine | default "postgresql" -}}
{{- $engines := include "ow.db.engines" . | fromJson -}}
{{- if not (hasKey $engines $engine) -}}
{{- fail (printf "database.engine %q is not supported: the api, consent and the organisation wallet accept only %s" $engine (keys $engines | sortAlpha | join " or ")) -}}
{{- end -}}
{{ $engine }}
{{- end }}

{{/* Facts of the engine (its entry in ow.db.engines). Output: JSON. */}}
{{- define "ow.db.engineFacts" -}}
{{- index (include "ow.db.engines" . | fromJson) (include "ow.db.engine" .) | toJson -}}
{{- end }}

{{/* "true" when the chart runs the server (database.mode bundled), else "". */}}
{{- define "ow.db.bundled" -}}
{{- $mode := .Values.database.mode | default "bundled" -}}
{{- if not (has $mode (list "bundled" "external")) -}}
{{- fail (printf "database.mode %q is not supported: use \"bundled\" or \"external\"" $mode) -}}
{{- end -}}
{{- if eq $mode "bundled" -}}true{{- end -}}
{{- end }}

{{/* Name of the bundled server objects (StatefulSet, Service) and of the database Secret: <fullname>-postgres. */}}
{{- define "ow.db.serverName" -}}
{{ include "ow.name" (list . (include "ow.db.engineFacts" . | fromJson).server) }}
{{- end }}

{{/* Default port of the engine. */}}
{{- define "ow.db.defaultPort" -}}
{{ (include "ow.db.engineFacts" . | fromJson).port | int }}
{{- end }}

{{/* Host name that the components use: the bundled Service, else database.external.host. */}}
{{- define "ow.db.host" -}}
{{- if include "ow.db.bundled" . -}}
{{ include "ow.db.serverName" . }}.{{ .Release.Namespace }}.svc
{{- else -}}
{{ required "database.external.host is required with database.mode external" .Values.database.external.host }}
{{- end -}}
{{- end }}

{{/* Port that the components use. */}}
{{- define "ow.db.port" -}}
{{- if include "ow.db.bundled" . -}}
{{ include "ow.db.defaultPort" . }}
{{- else -}}
{{ .Values.database.external.port | default (include "ow.db.defaultPort" .) }}
{{- end -}}
{{- end }}

{{/* Name of the Secret with the database passwords. */}}
{{- define "ow.db.secretName" -}}
{{- .Values.database.auth.existingSecret | default (include "ow.db.serverName" .) -}}
{{- end }}

{{/* Key of the bundled server's admin password in the database Secret (the server image's variable name). */}}
{{- define "ow.db.adminPasswordKey" -}}
{{ (include "ow.db.engineFacts" . | fromJson).adminPasswordKey }}
{{- end }}

{{/*
The server's admin user. It creates the databases and owner users (init
hook), the wallet database roles (roles hook) and the read-only users (read
access Jobs).
bundled: the engine's admin user ("postgres") and the admin key of the
database Secret.
external: database.external.admin (an empty user means no admin, which the
organisation wallet does not allow, see ow.db.check).
Output: JSON {user, secret, key}, or {} when there is no admin user.
*/}}
{{- define "ow.db.admin" -}}
{{- $db := .Values.database -}}
{{- if include "ow.db.bundled" . -}}
{{- toJson (dict
  "user" (include "ow.db.engineFacts" . | fromJson).adminUser
  "secret" (include "ow.db.secretName" .)
  "key" (include "ow.db.adminPasswordKey" .)) -}}
{{- else if $db.external.admin.user -}}
{{- toJson (dict
  "user" $db.external.admin.user
  "secret" (required "database.external.admin.passwordSecret is required with database.external.admin.user" $db.external.admin.passwordSecret)
  "key" ($db.external.admin.passwordKey | default "password")) -}}
{{- else -}}
{{- toJson dict -}}
{{- end -}}
{{- end }}

{{/* TLS Secret of the bundled server (tls.crt, tls.key, ca.crt). */}}
{{- define "ow.db.tlsSecretName" -}}
{{- .Values.database.tls.existingSecret | default (printf "%s-tls" (include "ow.db.serverName" .)) -}}
{{- end }}

{{/* "true" when the components use TLS to the server, else "". */}}
{{- define "ow.db.tls" -}}
{{- if .Values.database.tls.enabled -}}true{{- end -}}
{{- end }}

{{/*
CA certificate that the components use to verify the server. Bundled with
TLS: ca.crt of the server TLS Secret. External with TLS:
database.tls.caSecret. Output: JSON {secret, key}, or {} when there is no CA.
*/}}
{{- define "ow.db.ca" -}}
{{- $tls := .Values.database.tls -}}
{{- if not (include "ow.db.tls" .) -}}
{{- toJson dict -}}
{{- else if include "ow.db.bundled" . -}}
{{- toJson (dict "secret" (include "ow.db.tlsSecretName" .) "key" "ca.crt") -}}
{{- else if $tls.caSecret -}}
{{- toJson (dict "secret" $tls.caSecret "key" ($tls.caKey | default "ca.crt")) -}}
{{- else -}}
{{- toJson dict -}}
{{- end -}}
{{- end }}

{{/* File name of the database CA in each component's secret folder. */}}
{{- define "ow.db.caFileName" -}}
database-ca.crt
{{- end }}

{{/*
Client sslmode (api, gateway, consent, wallet, init hook):
database.tls.sslMode, else verify-full with a CA, require with TLS but no
CA, and disable without TLS.
*/}}
{{- define "ow.db.sslMode" -}}
{{- if not (include "ow.db.tls" .) -}}
disable
{{- else if .Values.database.tls.sslMode -}}
{{ .Values.database.tls.sslMode }}
{{- else if (include "ow.db.ca" . | fromJson).secret -}}
verify-full
{{- else -}}
require
{{- end -}}
{{- end }}

{{/* The keys of database.databases that the enabled components use, comma-separated. */}}
{{- define "ow.db.enabledDatabases" -}}
{{- $keys := list -}}
{{- if .Values.api.enabled -}}{{- $keys = concat $keys (list "api" "oidc") -}}{{- end -}}
{{- if .Values.consent.enabled -}}{{- $keys = append $keys "consent" -}}{{- end -}}
{{- if .Values.organisationWallet.enabled -}}{{- $keys = append $keys "wallet" -}}{{- end -}}
{{ join "," $keys }}
{{- end }}

{{/*
Render guards for database.*. Output: nothing. Every template that writes a
database connection calls this (through ow.db.go and ow.db.wallet).
*/}}
{{- define "ow.db.check" -}}
{{- $db := .Values.database -}}
{{- $bundled := include "ow.db.bundled" . -}}
{{- $names := list -}}
{{- range $key := include "ow.db.enabledDatabases" . | splitList "," | compact -}}
{{- $name := (index $db.databases $key).name | default "" -}}
{{- if not (regexMatch "^[a-z][a-z0-9_]{0,62}$" $name) -}}
{{- fail (printf "database.databases.%s.name %q is not a database name: a lower-case letter, then lower-case letters, digits or _" $key $name) -}}
{{- end -}}
{{- if has $name $names -}}
{{- fail (printf "database.databases.%s.name %q is the name of another database: each component needs its own database" $key $name) -}}
{{- end -}}
{{- $names = append $names $name -}}
{{- end -}}
{{- /* The roles hook creates the wallet database roles as the admin user,
so the chart cannot create them without one. */ -}}
{{- if and .Values.organisationWallet.enabled (not $bundled) (not $db.external.admin.user) -}}
{{- fail "database.external.admin.user is required with database.mode external and the organisation wallet: the hook wallet-database-roles makes the database roles of the wallet with the admin user of the server (see docs/database.md)" -}}
{{- end -}}
{{- if and (not $bundled) (not $db.external.admin.user) (not $db.auth.existingSecret) -}}
{{- range $key := include "ow.db.enabledDatabases" . | splitList "," | compact -}}
{{- if not (index $db.databases $key).password -}}
{{- fail (printf "database.mode external without database.external.admin.user: the databases and the users exist, so give their passwords in database.auth.existingSecret (or database.databases.%s.password); the chart cannot make them" $key) -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- with $db.tls.sslMode -}}
{{- if not (has . (list "disable" "require" "verify-ca" "verify-full")) -}}
{{- fail (printf "database.tls.sslMode %q is not supported: disable, require, verify-ca or verify-full" .) -}}
{{- end -}}
{{- if and (has . (list "verify-ca" "verify-full")) (not (include "ow.db.ca" $ | fromJson).secret) -}}
{{- fail (printf "database.tls.sslMode %s needs the CA of the server: database.tls.caSecret (external) or TLS of the bundled server" .) -}}
{{- end -}}
{{- end -}}
{{- end }}

{{/*
The DataBase section of the Go components (one struct with exact keys, for
api DataBase, Extensions.oidc.database and ReadAccess.*, gateway DataBase,
and consent DataBase and ReadAccess.*): tls.sslMode (plus tls.caFile when
there is a CA) and the pool. Call with (dict "root" $ "host" "<host>"
"port" <port> "name" "<database>" "username" "<user>" "passwordFile"
"<path>" "caFile" "<path>" "pool" <{maxConns, minConns} or nil>).
Output: JSON.
*/}}
{{- define "ow.db.go" -}}
{{- $root := .root -}}
{{- include "ow.db.check" $root -}}
{{- $section := dict
  "type" (include "ow.db.engine" $root)
  "hosts" (list .host)
  "port" (.port | int)
  "name" .name
  "username" .username
  "passwordFile" .passwordFile -}}
{{- $hasCa := (include "ow.db.ca" $root | fromJson).secret -}}
{{- $sslMode := include "ow.db.sslMode" $root -}}
{{- $tls := dict "sslMode" $sslMode -}}
{{- if and $hasCa (ne $sslMode "disable") -}}
{{- $_ := set $tls "caFile" .caFile -}}
{{- end -}}
{{- $_ := set $section "tls" $tls -}}
{{- with .pool -}}
{{- $_ := set $section "maxConns" (.maxConns | int) -}}
{{- $_ := set $section "minConns" (.minConns | int) -}}
{{- end -}}
{{- toJson $section -}}
{{- end }}

{{/*
The DataBase section for one component's own database in the chart. Call
with (dict "root" $ "db" "<key of database.databases>" "secretDir"
"<folder>" "passwordFile" "<file name>" "pool" <pool or nil>). The CA is
the file ow.db.caFileName in the same folder. Output: JSON.
*/}}
{{- define "ow.db.goOwner" -}}
{{- $root := .root -}}
{{- $database := index $root.Values.database.databases .db -}}
{{- include "ow.db.go" (dict
  "root" $root
  "host" (include "ow.db.host" $root)
  "port" (include "ow.db.port" $root)
  "name" $database.name
  "username" $database.name
  "passwordFile" (printf "%s/%s" .secretDir .passwordFile)
  "caFile" (printf "%s/%s" .secretDir (include "ow.db.caFileName" $root))
  "pool" .pool) -}}
{{- end }}

{{/*
The wallet's database section (pydantic, exact keys: type, host, port,
name, user, password_file, ssl_ca_file, ssl_mode): ssl_mode (the same
sslmode as the other components) and, for verify-ca and verify-full,
ssl_ca_file. With these modes the wallet never falls back to plain text.
Call with (dict "root" $ "host" "port" "name" "user" "passwordFile"
"caFile"). Output: JSON.
*/}}
{{- define "ow.db.wallet" -}}
{{- $root := .root -}}
{{- include "ow.db.check" $root -}}
{{- $section := dict
  "type" (include "ow.db.engine" $root)
  "host" .host
  "port" (.port | int)
  "name" .name
  "user" .user
  "password_file" .passwordFile -}}
{{- $sslMode := include "ow.db.sslMode" $root -}}
{{- $_ := set $section "ssl_mode" $sslMode -}}
{{- if has $sslMode (list "verify-ca" "verify-full") -}}
{{- $_ := set $section "ssl_ca_file" .caFile -}}
{{- end -}}
{{- toJson $section -}}
{{- end }}

{{/*
Database secret files of one component: its owner user's password and the
CA. Call with (list $ "<key of database.databases>" "<password file name>").
Output: JSON "<file name>" -> {secret, key}.
*/}}
{{- define "ow.db.secretFiles" -}}
{{- $root := index . 0 -}}
{{- $files := dict (index . 2) (dict "secret" (include "ow.db.secretName" $root) "key" (index $root.Values.database.databases (index . 1)).name) -}}
{{- $ca := include "ow.db.ca" $root | fromJson -}}
{{- if $ca.secret -}}
{{- $_ := set $files (include "ow.db.caFileName" $root) $ca -}}
{{- end -}}
{{- toJson $files -}}
{{- end }}
