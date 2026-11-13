{{/*
config.yaml of the api (start-api and the operator Jobs) and of the webhook
handler (start-webhook-api). The api reads it with koanf: key names are
exact and an unknown key stops the api. The file holds no secrets: each
<Name>File key names a file in ow.api.secretDir (the projected volume in
deploy.yaml, see ow.api.secretFiles). Both roles get the same file except
for the database pool size and the NATS user (api, api-webhook). The api is
the IAM (Iam.mode "builtin"). The database sections come from ow.db.go (the
database.* engine).
Call with (dict "root" $ "role" "api"|"webhook").
*/}}
{{- define "ow.api.config" -}}
{{- $root := .root -}}
{{- $v := $root.Values -}}
{{- $api := $v.api -}}
{{- $apiUrl := include "ow.publicUrlOf" (list $root "api") -}}
{{- $pools := $v.database.pools -}}
{{- $pool := ternary $pools.webhook $pools.api (eq .role "webhook") -}}
{{- $dir := include "ow.api.secretDir" $root -}}
{{- $client := include "ow.nats.client" (list $root (include "ow.api.natsUser" .role)) | fromJson -}}
{{- $signing := include "ow.serviceKeys.signing" (list $root $api "api" "api-service-key") | fromJson -}}
{{- $config := dict
  "ApiBaseUrl" $apiUrl
  "ServiceName" "igrant-api"
  "ApiSecretKeyFile" (include "ow.api.secretFile" (list $root "api-secret-key"))
  "DataBase" (include "ow.db.goOwner" (dict "root" $root "db" "api" "secretDir" $dir "passwordFile" "db-password" "pool" $pool) | fromJson)
  "Dashboard" (dict "url" ($api.dashboardUrl | default (include "ow.publicUrlOf" (list $root "enterpriseDashboard"))))
  "Iam" (dict
    "IdPAlias" $api.iam.idpAlias
    "APIBaseUrl" $apiUrl
    "mode" "builtin")
  "AdminAuth" (dict
    "walletLogin" (dict "organisationId" $api.adminAuth.walletLogin.organisationId))
  "Webhooks" (dict "DeliveryRetentionDays" ($api.webhooks.deliveryRetentionDays | int))
  "ActionLogs" (dict "RetentionDays" ($api.actionLogRetentionDays | int))
  "Extensions" (dict
    "oidc" (dict
      "issuer" $apiUrl
      "qrPollPrefix" (printf "%s/v4/service/platform/extension/oidc" $apiUrl)
      "apiPathBase" "/v4/service/platform/extension/oidc/{organisationId}/{sandboxOrgId}"
      "database" (include "ow.db.goOwner" (dict "root" $root "db" "oidc" "secretDir" $dir "passwordFile" "oidc-db-password" "pool" $pools.oidc) | fromJson)))
  "Nats" (dict
    "url" (include "ow.nats.url" $root)
    "nkeySeedFile" (printf "%s/nats-seed" (include "ow.api.secretDir" $root))
    "inboxPrefix" $client.inbox
    "streamReplicas" (include "ow.nats.jetstreamReplicas" $root | int)
    "timeout" ($api.nats.timeout | int)
    "maxConcurrentHandlers" ($api.nats.maxConcurrentHandlers | int))
  "KeyStorage" (dict
    "tokenHashSecretFile" (include "ow.api.secretFile" (list $root "token-hash-secret.json"))
    "tokenSigningJwksFile" (include "ow.api.secretFile" (list $root "token-signing-jwks.json"))
    "tokenSigningActiveKid" (required "api.keyStorage.tokenSigning.activeKid is required (the kid of the active key in the token signing JWKS)" $api.keyStorage.tokenSigning.activeKid | toString)
    "dbWrappingKeysFile" (include "ow.api.secretFile" (list $root "db-wrapping-keys.json"))
    "allowPlaintextProviderKeys" false)
  "ClientAddress" (include "ow.clientAddress" $root | fromJson)
  "Log" (dict "level" $api.logLevel)
-}}
{{- /* Services of the installation (ow.installation.config): the section
is only set when a service is not installed. */ -}}
{{- with include "ow.installation.config" $root | fromJson -}}
{{- $_ := set $config "Installation" . -}}
{{- end -}}
{{- /* Public URL of the wallet, only with the wallet (without it the api
has no wallet routes and the chart needs no wallet host). */ -}}
{{- if include "ow.installation.has" (list $root "wallet") -}}
{{- $_ := set $config "OpenIdDeployment" (dict
    "OpenIdServiceEndpoint" (include "ow.publicUrlOf" (list $root "organisationWallet"))) -}}
{{- end -}}
{{- if $api.smtp.host -}}
{{- $smtp := dict
    "host" $api.smtp.host
    "port" ($api.smtp.port | int)
    "username" $api.smtp.username
    "adminEmail" $api.smtp.adminEmail -}}
{{- with $api.smtp.replyTo -}}
{{- $_ := set $smtp "replyTo" . -}}
{{- end -}}
{{- with include "ow.api.secretFile" (list $root "smtp-password") -}}
{{- $_ := set $smtp "passwordFile" . -}}
{{- end -}}
{{- $_ := set $config "Smtp" $smtp -}}
{{- end -}}
{{- with include "ow.api.secretFile" (list $root "twilio-account-sid") -}}
{{- $_ := set $config "Twilio" (dict
    "accountSidFile" .
    "authTokenFile" (include "ow.api.secretFile" (list $root "twilio-auth-token"))) -}}
{{- end -}}
{{- /* The api signs and verifies NATS envelopes (issuer igrant-api). It
trusts its own internal events and the installed services, consent and the
wallet (ow.api.trustedIssuers). Both processes sign with the api key. */ -}}
{{- $_ := set $config "ServiceEnvelope" (dict
    "signingJwksFile" (printf "%s/service-envelope-jwks.json" (include "ow.api.secretDir" $root))
    "activeKid" $signing.activeKid
    "lifetimeSeconds" ($api.serviceEnvelope.lifetimeSeconds | int)
    "clockSkewSeconds" ($api.serviceEnvelope.clockSkewSeconds | int)
    "trustedIssuers" (include "ow.serviceKeys.trusted" (prepend (include "ow.api.trustedIssuers" $root | fromJsonArray) $root) | fromJsonArray)) -}}
{{- if (include "ow.nats.ca" $root | fromJson).secret -}}
{{- $_ := set $config.Nats "tlsCaFile" (printf "%s/nats-ca.crt" (include "ow.api.secretDir" $root)) -}}
{{- end -}}
{{- /* Every api process reads the wallet database views with the api's
read-only user (ReadAccess.wallet, same shape as DataBase). Without the
wallet the file has no ReadAccess. */ -}}
{{- if include "ow.installation.has" (list $root "wallet") -}}
{{- $reader := include "ow.readAccess.reader" (list $root "api" "wallet") | fromJson -}}
{{- $walletRead := include "ow.db.go" (dict
    "root" $root
    "host" $reader.host
    "port" $reader.port
    "name" $reader.name
    "username" $reader.username
    "passwordFile" (include "ow.api.secretFile" (list $root "read-access-wallet-password"))
    "caFile" (printf "%s/%s" $dir (include "ow.db.caFileName" $root))
    "pool" $v.database.pools.apiReadAccess) | fromJson -}}
{{- $_ := set $config "ReadAccess" (dict "wallet" $walletRead) -}}
{{- end -}}
{{- /* The api core verifies the gateway's internal token on every request
(start-api needs GatewayToken.jwksFile; start-webhook-api does not read the
section). */ -}}
{{- $_ := set $config "GatewayToken" (dict
    "issuer" $v.gateway.internalToken.issuer
    "audiences" $v.gateway.internalToken.audiences
    "jwksFile" (printf "%s/gateway-jwks.json" (include "ow.api.configPath" $root | dir))) -}}
{{- /* How the two server processes stop: drain, then wait for the requests
in progress. The operator Jobs do not read this section. */ -}}
{{- $_ := set $config "Server" (dict
    "drainSeconds" ($api.server.drainSeconds | int)
    "gracefulShutdownSeconds" ($api.server.gracefulShutdownSeconds | int)) -}}
{{- /* The installation limits (api.limits): the key is set only when the
installer gives a value; otherwise the api uses its default. The gateway
file never has it, because the gateway refuses the section. */ -}}
{{- with dig "limits" "maxOrganisations" "" $api -}}
{{- $_ := set $config "Limits" (dict "maxOrganisations" (. | int)) -}}
{{- end -}}
{{- if $api.verifierApp.androidPackageName -}}
{{- $_ := set $config "VerifierApp" $api.verifierApp -}}
{{- end -}}
{{- /* api.extraConfig cannot set Installation: ow.installation.config
fails the render when it names other services, and the chart writes its
own section. */ -}}
{{- $extra := deepCopy ($api.extraConfig | default dict) -}}
{{- $_ := unset $extra "Installation" -}}
{{- $config = mustMergeOverwrite $config $extra -}}
{{- /* No log file (ow.noLogFile): the api and the webhook handler log to
stdout. */ -}}
{{- include "ow.noLogFile" (list "api.extraConfig" "Log.file.path" (((get $config "Log") | default dict).file | default dict).path) -}}
{{- $config | toYaml -}}
{{- end }}

{{/*
config.yaml of the api migration hook (migrate-hook.yaml): only the api
database, the OIDC provider database (igrant-api migrate migrates both)
and the log level. config.LoadDatabase requires no other key and reads no
other secret file. The hook runs before the release's resources change, so
it cannot read the release's new ConfigMaps.
*/}}
{{- define "ow.api.migrateConfig" -}}
{{- $dir := include "ow.api.secretDir" . -}}
{{- toYaml (dict
    "DataBase" (include "ow.db.goOwner" (dict "root" . "db" "api" "secretDir" $dir "passwordFile" "db-password") | fromJson)
    "Extensions" (dict "oidc" (dict "database" (include "ow.db.goOwner" (dict "root" . "db" "oidc" "secretDir" $dir "passwordFile" "oidc-db-password") | fromJson)))
    "Log" (dict "level" .Values.api.logLevel)) }}
{{- end }}

{{/*
Limits for the CSV import of individuals that the api reads from
api.extraConfig.Uploads: individualImportMaxFileBytes (65536 to 20971520)
and individualImportMaxRows (1 to 9000); absent or 0 means the api default
(5 MiB, 5000). The dashboard gets the same values in its config.json, so it
refuses exactly the files that the api refuses. The render fails on any
value that the api would refuse at start: a string (even a string of
digits, because the api decodes its file without type conversion), a
non-integer, or a value out of range. Call with the root context. Output:
JSON with the keys that are set (as integers).
*/}}
{{- define "ow.api.importLimits" -}}
{{- $uploads := dig "Uploads" dict (.Values.api.extraConfig | default dict) -}}
{{- $out := dict -}}
{{- range $key, $range := dict "individualImportMaxFileBytes" (list 65536 20971520) "individualImportMaxRows" (list 1 9000) -}}
{{- if hasKey ($uploads | default dict) $key -}}
{{- $value := get $uploads $key -}}
{{- if kindIs "string" $value -}}
{{- fail (printf "api.extraConfig.Uploads.%s (%q) is a text: give a number, not a text (the api reads a whole number and stops at its start with a text)" $key $value) -}}
{{- end -}}
{{- $text := toString $value -}}
{{- if or (kindIs "float64" $value) (kindIs "float32" $value) -}}
{{- if ne (floor $value) ($value | float64) -}}
{{- fail (printf "api.extraConfig.Uploads.%s (%v) must be a whole number: the api and the dashboard read it in whole units" $key $value) -}}
{{- end -}}
{{- $text = printf "%.0f" ($value | float64) -}}
{{- end -}}
{{- if not (regexMatch "^[0-9]+$" $text) -}}
{{- fail (printf "api.extraConfig.Uploads.%s (%v) must be a whole number of 0 or more: the api and the dashboard read it in whole units" $key $value) -}}
{{- end -}}
{{- $number := $text | int64 -}}
{{- if ne $number 0 -}}
{{- if or (lt $number (index $range 0 | int64)) (gt $number (index $range 1 | int64)) -}}
{{- fail (printf "api.extraConfig.Uploads.%s (%s) is not between %v and %v (or 0, the default): the api refuses it at its start, and the dashboard would use its default" $key $text (index $range 0) (index $range 1)) -}}
{{- end -}}
{{- $_ := set $out $key $number -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- toJson $out -}}
{{- end }}

{{/*
Render guard for the upload memory of the api core (api.extraConfig Uploads
and ImageUpload). Each upload in progress (an image or a CSV import of
individuals) holds its file in memory, with at most Uploads.maxInProgress
of them (default 8). The container's memory request (the process memory
without uploads) plus maxInProgress x the largest file must fit below the
memory limit. Call with the root context. Output: nothing.
*/}}
{{- define "ow.api.checkUploads" -}}
{{- $_ := include "ow.api.importLimits" . -}}
{{- $api := .Values.api -}}
{{- $config := $api.extraConfig | default dict -}}
{{- $inProgress := (dig "Uploads" "maxInProgress" 0 $config) | int64 | default 8 -}}
{{- $image := (dig "ImageUpload" "maxBytes" 0 $config) | int64 | default 5242880 -}}
{{- $import := (dig "Uploads" "individualImportMaxFileBytes" 0 $config) | int64 | default 5242880 -}}
{{- $largest := max $image $import -}}
{{- $limit := (($api.resources | default dict).limits | default dict).memory -}}
{{- if $limit -}}
{{- $request := (($api.resources | default dict).requests | default dict).memory | default "0" -}}
{{- $need := add (include "ow.quantityBytes" $request | int64) (mul $inProgress $largest) -}}
{{- if gt $need (include "ow.quantityBytes" $limit | int64) -}}
{{- fail (printf "api.resources: the memory request (%s) + Uploads.maxInProgress (%d) x the largest upload file (%d bytes: the larger of ImageUpload.maxBytes and Uploads.individualImportMaxFileBytes) = %d bytes, above the memory limit (%s): each upload in progress holds its file in memory, so a full set of uploads can make the kernel stop the api. Lower Uploads.maxInProgress or the file limits of api.extraConfig, or raise api.resources.limits.memory" $request $inProgress $largest $need $limit) -}}
{{- end -}}
{{- end -}}
{{- end }}

{{/*
Render guard for /tmp in the api and webhook pods (api.tmp.sizeLimit, an
in-memory emptyDir). Go's multipart parser (r.FormFile, 32 MiB in memory)
writes any file part above 32 MiB to /tmp in full. The largest body that
reaches the api's multipart parser is the larger of the gateway body limits
for the classes default and file (gateway.proxy.maxBodyBytes; the large
class only goes to the wallet). So:
- when that limit is above 32 MiB, /tmp must hold one upload of that size,
  or every such upload fails;
- the memory request plus /tmp must fit below the container's memory limit
  (files in /tmp count against it), or a full /tmp can make the kernel
  stop the process.
Call with the root context. Output: nothing.
*/}}
{{- define "ow.api.checkTmp" -}}
{{- $api := .Values.api -}}
{{- $limits := .Values.gateway.proxy.maxBodyBytes -}}
{{- $default := $limits.default | int64 | default 1048576 -}}
{{- $file := $limits.file | int64 | default (add 5242880 65536) -}}
{{- $body := max $default $file -}}
{{- $inMemory := 33554432 -}}
{{- $tmp := include "ow.quantityBytes" $api.tmp.sizeLimit | int64 -}}
{{- if and (gt $body $inMemory) (gt $body $tmp) -}}
{{- fail (printf "api.tmp.sizeLimit (%s, %d bytes) is below the largest body that the gateway sends to the api (%d bytes, gateway.proxy.maxBodyBytes default and file): the api writes a file part above 32 MiB whole to /tmp, so these uploads fail; give api.tmp.sizeLimit at least that size (and raise the memory limit of the api by the same size)" $api.tmp.sizeLimit $tmp $body) -}}
{{- end -}}
{{- range $role, $resources := dict "api" $api.resources "webhook" $api.webhook.resources -}}
{{- $limit := (($resources | default dict).limits | default dict).memory -}}
{{- if $limit -}}
{{- $request := (($resources | default dict).requests | default dict).memory | default "0" -}}
{{- if gt (add (include "ow.quantityBytes" $request | int64) $tmp) (include "ow.quantityBytes" $limit | int64) -}}
{{- $key := ternary "api.resources" "api.webhook.resources" (eq $role "api") -}}
{{- fail (printf "%s: the memory request (%s) and api.tmp.sizeLimit (%s) together are above the memory limit (%s): /tmp of the %s pods is in memory and counts against the limit; raise %s.limits.memory" $key $request $api.tmp.sizeLimit $limit $role $key) -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end }}
