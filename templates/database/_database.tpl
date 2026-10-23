{{/*
Database helpers. ONE engine for the whole platform (database.engine:
postgresql or mysql) and one server (database.mode: bundled or external).
Each component has its own database and its own owner user: the user name
is the database name. Every component config file, Job and NetworkPolicy
gets the engine, the host, the port and the TLS settings from
these helpers only.
*/}}

{{/* The engine of all components ("postgresql" or "mysql"), validated. */}}
{{- define "ow.db.engine" -}}
{{- $engine := .Values.database.engine | default "postgresql" -}}
{{- if not (has $engine (list "postgresql" "mysql")) -}}
{{- fail (printf "database.engine %q is not supported: use \"postgresql\" or \"mysql\"" $engine) -}}
{{- end -}}
{{ $engine }}
{{- end }}

{{/* "true" when the engine is mysql, else "". */}}
{{- define "ow.db.isMysql" -}}
{{- if eq (include "ow.db.engine" .) "mysql" -}}true{{- end -}}
{{- end }}

{{/* "true" when the chart runs the server (database.mode bundled), else "". */}}
{{- define "ow.db.bundled" -}}
{{- $mode := .Values.database.mode | default "bundled" -}}
{{- if not (has $mode (list "bundled" "external")) -}}
{{- fail (printf "database.mode %q is not supported: use \"bundled\" or \"external\"" $mode) -}}
{{- end -}}
{{- if eq $mode "bundled" -}}true{{- end -}}
{{- end }}

{{/* Name of the bundled server objects (StatefulSet, Service) and of the database Secret: <fullname>-postgres or <fullname>-mysql. */}}
{{- define "ow.db.serverName" -}}
{{ include "ow.name" (list . (ternary "mysql" "postgres" (eq (include "ow.db.isMysql" .) "true"))) }}
{{- end }}

{{/* Default port of the engine. */}}
{{- define "ow.db.defaultPort" -}}
{{ ternary 3306 5432 (eq (include "ow.db.isMysql" .) "true") }}
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

{{/* Key of the admin password of the bundled server in the database Secret (the variable of the server image). */}}
{{- define "ow.db.adminPasswordKey" -}}
{{ ternary "MARIADB_ROOT_PASSWORD" "POSTGRES_PASSWORD" (eq (include "ow.db.isMysql" .) "true") }}
{{- end }}

{{/*
The admin user of the server: it makes the databases and the owner users
(init Job) and the read-only users (read access Jobs).
bundled: "postgres" or "root" and the admin key of the database Secret.
external: database.external.admin (empty user: no admin).
Output: JSON {user, secret, key}, or {} when there is no admin user.
*/}}
{{- define "ow.db.admin" -}}
{{- $db := .Values.database -}}
{{- if include "ow.db.bundled" . -}}
{{- toJson (dict
  "user" (ternary "root" "postgres" (eq (include "ow.db.isMysql" .) "true"))
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

{{/* Name of the TLS Secret (tls.crt, tls.key, ca.crt) of the bundled server. */}}
{{- define "ow.db.tlsSecretName" -}}
{{- .Values.database.tls.existingSecret | default (printf "%s-tls" (include "ow.db.serverName" .)) -}}
{{- end }}

{{/* "true" when the components use TLS to the server, else "". */}}
{{- define "ow.db.tls" -}}
{{- if .Values.database.tls.enabled -}}true{{- end -}}
{{- end }}

{{/*
The CA certificate that the components use to verify the server: bundled
with TLS: ca.crt of the server TLS Secret; external with TLS:
database.tls.caSecret. Output: JSON {secret, key}, or {} without a CA.
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

{{/* File name of the database CA in the secret folder of each component. */}}
{{- define "ow.db.caFileName" -}}
database-ca.crt
{{- end }}

{{/*
sslmode of the PostgreSQL clients (api, gateway, consent, init Job):
database.tls.sslMode, else verify-full with a CA, require with
TLS and no CA, disable without TLS.
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
Render guards of database.*. Output: nothing. Every template that writes a
database connection calls it (through ow.db.go and ow.db.wallet).
*/}}
{{- define "ow.db.check" -}}
{{- $db := .Values.database -}}
{{- $mysql := include "ow.db.isMysql" . -}}
{{- $bundled := include "ow.db.bundled" . -}}
{{- $names := list -}}
{{- range $key := include "ow.db.enabledDatabases" . | splitList "," | compact -}}
{{- $name := (index $db.databases $key).name | default "" -}}
{{- if not (regexMatch "^[a-z][a-z0-9_]{0,62}$" $name) -}}
{{- fail (printf "database.databases.%s.name %q is not a database name: a lower-case letter, then lower-case letters, digits or _" $key $name) -}}
{{- end -}}
{{- if and $mysql (gt (len $name) 32) -}}
{{- fail (printf "database.databases.%s.name %q has more than 32 characters: it is also the MySQL user name" $key $name) -}}
{{- end -}}
{{- if has $name $names -}}
{{- fail (printf "database.databases.%s.name %q is the name of another database: each component needs its own database" $key $name) -}}
{{- end -}}
{{- $names = append $names $name -}}
{{- end -}}
{{- if and (not $bundled) (not $db.external.admin.user) (not $db.auth.existingSecret) -}}
{{- range $key := include "ow.db.enabledDatabases" . | splitList "," | compact -}}
{{- if not (index $db.databases $key).password -}}
{{- fail (printf "database.mode external without database.external.admin.user: the databases and the users exist, so give their passwords in database.auth.existingSecret (or database.databases.%s.password); the chart cannot make them" $key) -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- if and $mysql (include "ow.db.tls" .) (not (include "ow.db.ca" . | fromJson).secret) -}}
{{- fail "database.tls.caSecret is required with database.engine mysql and database.tls.enabled: the MySQL clients of the components verify the server with its CA (or set database.tls.enabled false)" -}}
{{- end -}}
{{- if and $mysql $db.tls.sslMode -}}
{{- fail "database.tls.sslMode is for postgresql only: with mysql the components verify the server with the CA" -}}
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
The DataBase section of the Go components (api DataBase,
Extensions.oidc.database and ReadAccess.*, gateway DataBase, consent
DataBase and ReadAccess.*: one struct, exact keys). postgresql: tls.sslMode
(+ tls.caFile with a CA) and the pool. mysql: tls.caFile (TLS 1.2+, the CA
and hosts[0] are checked; without a tls block the connection is plain text,
and tls.sslMode has no effect) and the session time zone +00:00 (the
components do not set it); the pool keys have no effect on mysql. Call with
(dict "root" $ "host" "<host>" "port" <port> "name" "<database>"
"username" "<user>" "passwordFile" "<path>" "caFile" "<path>" "pool"
<{maxConns, minConns} or nil>). Output: JSON.
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
{{- if include "ow.db.isMysql" $root -}}
{{- if include "ow.db.tls" $root -}}
{{- $_ := set $section "tls" (dict "caFile" .caFile) -}}
{{- end -}}
{{- $_ := set $section "params" (dict "time_zone" "'+00:00'") -}}
{{- else -}}
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
{{- end -}}
{{- toJson $section -}}
{{- end }}

{{/*
The DataBase section of the database of one component in the chart. Call
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
The database section of the wallet (pydantic, exact keys: type, host,
port, name, user, password_file, ssl_ca_file, ssl_mode). postgresql:
ssl_mode (the sslmode of the other components) and, for verify-ca and
verify-full, ssl_ca_file; the wallet never falls back to plain text with
these. mysql: ssl_ca_file (the certificate and the host name are checked;
ssl_mode is for postgresql only). Call with (dict "root" $ "host" "port"
"name" "user" "passwordFile" "caFile"). Output: JSON.
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
{{- if include "ow.db.isMysql" $root -}}
{{- if include "ow.db.tls" $root -}}
{{- $_ := set $section "ssl_ca_file" .caFile -}}
{{- end -}}
{{- else -}}
{{- $sslMode := include "ow.db.sslMode" $root -}}
{{- $_ := set $section "ssl_mode" $sslMode -}}
{{- if has $sslMode (list "verify-ca" "verify-full") -}}
{{- $_ := set $section "ssl_ca_file" .caFile -}}
{{- end -}}
{{- end -}}
{{- toJson $section -}}
{{- end }}

{{/*
The secret files of the database of one component: the password of its
owner user and the CA. Call with (list $ "<key of database.databases>"
"<password file name>"). Output: JSON "<file name>" -> {secret, key}.
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

{{/*
The option file of the bundled MariaDB server ([mariadbd] group): the
options that the components need, database.mysql.parameters, and the TLS
options. Output: text.
*/}}
{{- define "ow.db.mysqlConfig" -}}
{{- $params := .Values.database.mysql.parameters | default dict -}}
[mariadbd]
# The components keep keys and tokens in utf8mb4 with a binary collation.
character-set-server = utf8mb4
collation-server = utf8mb4_bin
# The api and consent do not set the session time zone: the column defaults
# (CURRENT_TIMESTAMP) must be UTC.
default-time-zone = +00:00
skip-name-resolve
{{- range $name := keys $params | sortAlpha }}
{{ $name }} = {{ index $params $name }}
{{- end }}
{{- if include "ow.db.tls" . }}
# TLS with the certificate of the chart (or database.tls.existingSecret).
# A TCP connection without TLS is refused.
ssl_cert = /etc/mysql/tls/tls.crt
ssl_key = /etc/mysql/tls/tls.key
ssl_ca = /etc/mysql/tls/ca.crt
require_secure_transport = ON
{{- end }}
{{- end }}
