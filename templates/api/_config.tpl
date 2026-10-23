{{/*
config.yaml of the api (start-api, the operator Jobs) and of the webhook
handler (start-webhook-api). The api reads it with koanf: the key names are
exact and an unknown key stops the api. The file has no secret: each
<Name>File key names a file in ow.api.secretDir (the projected volume of
deploy.yaml, see ow.api.secretFiles). The two roles have the same file,
except the size of the database pool and the NATS user (api, api-webhook).
The api is the IAM (Iam.mode "builtin"). The database sections come from
ow.db.go (the engine of database.*).
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
  "ApplicationMode" "multi-tenant"
  "ApiSecretKeyFile" (include "ow.api.secretFile" (list $root "api-secret-key"))
  "DataBase" (include "ow.db.goOwner" (dict "root" $root "db" "api" "secretDir" $dir "passwordFile" "db-password" "pool" $pool) | fromJson)
  "Dashboard" (dict "url" ($api.dashboardUrl | default (include "ow.publicUrlOf" (list $root "enterpriseDashboard"))))
  "Iam" (dict
    "IdPAlias" $api.iam.idpAlias
    "APIBaseUrl" $apiUrl
    "mode" "builtin")
  "AdminAuth" (dict
    "walletLogin" (dict "organisationId" $api.adminAuth.walletLogin.organisationId))
  "Webhooks" (dict
    "events" $api.webhooks.events
    "DeliveryRetentionDays" ($api.webhooks.deliveryRetentionDays | int))
  "ActionLogs" (dict "RetentionDays" ($api.actionLogRetentionDays | int))
  "OpenIdDeployment" (dict
    "OpenIdServiceEndpoint" (include "ow.publicUrlOf" (list $root "organisationWallet")))
  "Extensions" (dict
    "oidc" (dict
      "issuer" $apiUrl
      "qrPollPrefix" (printf "%s/v3/service/extension/oidc" $apiUrl)
      "apiPathBase" "/v3/service/extension/oidc/{organisationId}/{sandboxOrgId}"
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
    "allowPlainApiKeys" false
    "allowPlaintextProviderKeys" false)
  "ClientAddress" (include "ow.clientAddress" $root | fromJson)
  "Log" (dict "level" $api.logLevel)
-}}
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
{{- /* The api signs and verifies the NATS envelopes (issuer igrant-api;
it trusts consent, the wallet and its own internal events). Both processes
sign with the api key. */ -}}
{{- $_ := set $config "ServiceEnvelope" (dict
    "signingJwksFile" (printf "%s/service-envelope-jwks.json" (include "ow.api.secretDir" $root))
    "activeKid" $signing.activeKid
    "lifetimeSeconds" ($api.serviceEnvelope.lifetimeSeconds | int)
    "clockSkewSeconds" ($api.serviceEnvelope.clockSkewSeconds | int)
    "trustedIssuers" (include "ow.serviceKeys.trusted" (list $root "igrant-api" "igrant-consent-management" "eudi-wallet") | fromJsonArray)) -}}
{{- with $v.nats.tlsCa.existingSecret -}}
{{- $_ := set $config.Nats "tlsCaFile" (printf "%s/nats-ca.crt" (include "ow.api.secretDir" $root)) -}}
{{- end -}}
{{- /* Every api process reads the views of the wallet database with the
read-only user of the api (ReadAccess.wallet, the shape of DataBase). */ -}}
{{- $reader := include "ow.readAccess.reader" (list $root "api" "wallet") | fromJson -}}
{{- $walletRead := include "ow.db.go" (dict
    "root" $root
    "host" $reader.host
    "port" $reader.port
    "name" $reader.name
    "username" $reader.username
    "passwordFile" (include "ow.api.secretFile" (list $root "read-access-wallet-password"))
    "caFile" (printf "%s/%s" $dir (include "ow.db.caFileName" $root))) | fromJson -}}
{{- $_ := set $config "ReadAccess" (dict "wallet" $walletRead) -}}
{{- /* The api core verifies the internal token of the gateway on every
request (start-api needs GatewayToken.jwksFile; start-webhook-api does not
read the section). */ -}}
{{- $_ := set $config "GatewayToken" (dict
    "issuer" $v.gateway.internalToken.issuer
    "audiences" $v.gateway.internalToken.audiences
    "jwksFile" (printf "%s/gateway-jwks.json" (include "ow.api.configPath" $root | dir))) -}}
{{- /* The stop of the two server processes: drain, then the
wait for the requests in progress. The operator Jobs do not read this
section. */ -}}
{{- $_ := set $config "Server" (dict
    "drainSeconds" ($api.server.drainSeconds | int)
    "gracefulShutdownSeconds" ($api.server.gracefulShutdownSeconds | int)) -}}
{{- if $api.verifierApp.androidPackageName -}}
{{- $_ := set $config "VerifierApp" $api.verifierApp -}}
{{- end -}}
{{- $config = mustMergeOverwrite $config (deepCopy ($api.extraConfig | default dict)) -}}
{{- $config | toYaml -}}
{{- end }}

{{/*
config.yaml of the api migration hook (migrate-hook.yaml): only the database
of the api and the database of the OIDC provider (igrant-api migrate
migrates both) and the log level (config.LoadDatabase: no other key is
required, no other secret file is read). The hook runs before the resources
of the release change, so it cannot read the new ConfigMaps of the release.
*/}}
{{- define "ow.api.migrateConfig" -}}
{{- $dir := include "ow.api.secretDir" . -}}
{{- toYaml (dict
    "DataBase" (include "ow.db.goOwner" (dict "root" . "db" "api" "secretDir" $dir "passwordFile" "db-password") | fromJson)
    "Extensions" (dict "oidc" (dict "database" (include "ow.db.goOwner" (dict "root" . "db" "oidc" "secretDir" $dir "passwordFile" "oidc-db-password") | fromJson)))
    "Log" (dict "level" .Values.api.logLevel)) }}
{{- end }}
