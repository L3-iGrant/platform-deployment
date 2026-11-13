{{/*
config.yaml of the consent service (koanf, exact key names; an unknown key
stops the service). It holds no secrets: each *File key names a file in the
projected secret volume /run/secrets/consent (see deploy.yaml). Consent:
- always verifies the gateway's internal token (GatewayToken; the chart's
  gateway is the trusted issuer);
- connects to NATS with its nkey user;
- signs and verifies NATS envelopes (ServiceEnvelope; it trusts igrant-api
  and, when the wallet is installed, eudi-wallet);
- reads the api database views, and the wallet database views when the
  wallet is installed, with its own read-only users (ReadAccess;
  readAccess.consent.*).
*/}}
{{- define "ow.consent.config" -}}
{{- $c := .Values.consent -}}
{{- $client := include "ow.nats.client" (list . "consent") | fromJson -}}
{{- $signing := include "ow.serviceKeys.signing" (list . $c "consent" "consent-service-key") | fromJson -}}
{{- include "ow.gateway.checkGatewayJwks" . -}}
{{- $config := dict
  "Server" (dict
    "port" 80
    "adminPort" 8081
    "drainSeconds" ($c.server.drainSeconds | int)
    "gracefulShutdownSeconds" ($c.server.gracefulShutdownSeconds | int))
  "DataBase" (include "ow.consent.database" . | fromJson)
  "Nats" (dict
    "url" (include "ow.nats.url" .)
    "rpcTimeoutSeconds" ($c.nats.rpcTimeoutSeconds | int)
    "readRpcTimeoutSeconds" ($c.nats.readRpcTimeoutSeconds | int)
    "streamReplicas" (include "ow.nats.jetstreamReplicas" . | int)
    "nkeySeedFile" "/run/secrets/consent/nats-seed"
    "inboxPrefix" $client.inbox)
  "ServiceName" "igrant-consent-management"
  "Http" (dict "maxRequestBodyBytes" ($c.maxRequestBodyBytes | int64))
  "PublicBaseUrl" (include "ow.publicUrlOf" (list . "api"))
  "Log" (dict "level" $c.logLevel)
-}}
{{- $_ := set $config "GatewayToken" (dict
    "audience" .Values.gateway.internalToken.audiences.consent
    "clockSkewSeconds" ($c.gatewayToken.clockSkewSeconds | int)
    "trustedIssuers" (list (dict
      "issuer" .Values.gateway.internalToken.issuer
      "jwksFile" (printf "%s/gateway-jwks.json" (include "ow.gateway.keysDir" .))))) -}}
{{- $_ := set $config "ServiceEnvelope" (dict
    "signingJwksFile" "/run/secrets/consent/service-envelope-jwks.json"
    "activeKid" $signing.activeKid
    "lifetimeSeconds" ($c.serviceEnvelope.lifetimeSeconds | int)
    "clockSkewSeconds" ($c.serviceEnvelope.clockSkewSeconds | int)
    "trustedIssuers" (include "ow.serviceKeys.trusted" (prepend (include "ow.consent.trustedIssuers" . | fromJsonArray) .) | fromJsonArray)) -}}
{{- $readAccess := dict -}}
{{- range $owner := include "ow.consent.readAccessOwners" . | splitList "," -}}
{{- $reader := include "ow.readAccess.reader" (list $ "consent" $owner) | fromJson -}}
{{- $_ := set $readAccess $owner (include "ow.db.go" (dict
    "root" $
    "host" $reader.host
    "port" $reader.port
    "name" $reader.name
    "username" $reader.username
    "passwordFile" (printf "%s/read-access-%s-password" (include "ow.consent.secretDir" $) $owner)
    "caFile" (printf "%s/%s" (include "ow.consent.secretDir" $) (include "ow.db.caFileName" $))) | fromJson) -}}
{{- end -}}
{{- $_ := set $config "ReadAccess" $readAccess -}}
{{- if (include "ow.nats.ca" . | fromJson).secret -}}
{{- $_ := set $config.Nats "tlsCaFile" "/run/secrets/consent/nats-ca.crt" -}}
{{- end -}}
{{- $config = mustMergeOverwrite $config (deepCopy ($c.extraConfig | default dict)) -}}
{{- /* No log file (ow.noLogFile): consent logs to stdout. */ -}}
{{- include "ow.noLogFile" (list "consent.extraConfig" "Log.file.path" (((get $config "Log") | default dict).file | default dict).path) -}}
{{- $config | toYaml }}
{{- end }}

{{/* DataBase section of consent (the service, its Jobs and the migration hook). */}}
{{- define "ow.consent.database" -}}
{{- include "ow.db.goOwner" (dict "root" . "db" "consent" "secretDir" (include "ow.consent.secretDir" .) "passwordFile" "database-password" "pool" .Values.database.pools.consent) -}}
{{- end }}

{{/*
config.yaml of the consent migration hook (migrate-hook.yaml): only the
database and the log level. The hook runs before the release's resources
change, so it cannot read the new ConfigMaps of the gateway and service
keys; the migrate commands only need the database.
*/}}
{{- define "ow.consent.migrateConfig" -}}
{{- toYaml (dict
    "DataBase" (include "ow.consent.database" . | fromJson)
    "Log" (dict "level" .Values.consent.logLevel)) }}
{{- end }}
