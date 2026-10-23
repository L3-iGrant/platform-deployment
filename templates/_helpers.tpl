{{/*
Secret, KMS, NATS, key and read access helpers. The database helpers are in
templates/database/_database.tpl.
*/}}

{{/*
ClientAddress of the api and the gateway (the same section in both files):
clientAddress.header, .trustedProxies and .trustedProxyHeader. Empty: the
address of the TCP peer. Output: JSON.
*/}}
{{- define "ow.clientAddress" -}}
{{- $c := .Values.clientAddress | default dict -}}
{{- if and $c.trustedProxies (not $c.trustedProxyHeader) -}}
{{- fail "clientAddress.trustedProxies and clientAddress.trustedProxyHeader go together: set both or none" -}}
{{- end -}}
{{- if and $c.trustedProxyHeader (not $c.trustedProxies) -}}
{{- fail "clientAddress.trustedProxyHeader and clientAddress.trustedProxies go together: set both or none" -}}
{{- end -}}
{{- $out := dict -}}
{{- with $c.header -}}{{- $_ := set $out "header" . -}}{{- end -}}
{{- with $c.trustedProxies -}}{{- $_ := set $out "trustedProxies" . -}}{{- end -}}
{{- with $c.trustedProxyHeader -}}{{- $_ := set $out "trustedProxyHeader" . -}}{{- end -}}
{{- toJson $out -}}
{{- end }}

{{/*
Reads one key of a Secret that already exists in the release namespace
(lookup). It gives "" when the Secret or the key does not exist, and in
"helm template". Call with (list $ "<secret name>" "<key>").
*/}}
{{- define "ow.lookupSecretKey" -}}
{{- $root := index . 0 -}}
{{- $secret := lookup "v1" "Secret" $root.Release.Namespace (index . 1) -}}
{{- if and $secret $secret.data -}}
{{- index $secret.data (index . 2) | default "" | b64dec -}}
{{- end -}}
{{- end }}

{{/*
A secret value: the value from values.yaml, else the value in the Secret of
an earlier release, else a new random value. Call with
(list $ "<value>" "<secret name>" "<key>" <length>).
*/}}
{{- define "ow.secretValue" -}}
{{- $root := index . 0 -}}
{{- $value := index . 1 -}}
{{- if $value -}}
{{ $value }}
{{- else -}}
{{- $earlier := include "ow.lookupSecretKey" (list $root (index . 2) (index . 3)) -}}
{{- $earlier | default (randAlphaNum (index . 4)) -}}
{{- end -}}
{{- end }}

{{/* NATS URL that the services use. */}}
{{- define "ow.nats.url" -}}
{{- if .Values.nats.enabled -}}
nats://{{ include "ow.name" (list . "nats") }}.{{ .Release.Namespace }}.svc:4222
{{- else -}}
{{ required "nats.external.url is required when nats.enabled is false" .Values.nats.external.url }}
{{- end -}}
{{- end }}

{{/*
Name of one key Secret of the api (api.keyStorage.<item>.existingSecret,
else "<fullname>-<default>"). Call with (list $ "<item>" "<default>").
*/}}
{{- define "ow.api.keySecretName" -}}
{{- $root := index . 0 -}}
{{- (index $root.Values.api.keyStorage (index . 1)).existingSecret | default (include "ow.name" (list $root (index . 2))) -}}
{{- end }}

{{/* Folder of the api secret files (one projected volume). */}}
{{- define "ow.api.secretDir" -}}
/run/secrets/igrant-api
{{- end }}

{{/* Path of the api configuration file (ConfigMap key, --config). */}}
{{- define "ow.api.configPath" -}}
/etc/igrant-api/config.yaml
{{- end }}

{{/*
Keys of the Secret "<fullname>-api" that the chart makes: the values that
are in values.yaml or that the chart generates, and that no existing
Secret holds. Output: JSON list.
*/}}
{{- define "ow.api.chartSecretKeys" -}}
{{- $api := .Values.api -}}
{{- $keys := list -}}
{{- if not $api.existingSecret -}}{{- $keys = append $keys "api-secret-key" -}}{{- end -}}
{{- if and $api.smtp.host (not $api.smtp.existingSecret) $api.smtp.password -}}{{- $keys = append $keys "smtp-password" -}}{{- end -}}
{{- if and (not $api.twilio.existingSecret) $api.twilio.accountSid -}}{{- $keys = concat $keys (list "twilio-account-sid" "twilio-auth-token") -}}{{- end -}}
{{- toJson $keys -}}
{{- end }}

{{/*
Secret files of the api, the webhook handler and the operator Jobs. All
are files in one read-only folder (ow.api.secretDir), a projected volume
of these Secret keys. Each item: Secret name, key, file name. The config
file names the files (<Name>File keys).
Output: JSON object "<file name>" -> {secret, key}.
*/}}
{{- define "ow.api.secretFiles" -}}
{{- $root := . -}}
{{- $api := .Values.api -}}
{{- $ks := $api.keyStorage -}}
{{- $chartSecret := include "ow.name" (list $root "api") -}}
{{- $chartKeys := include "ow.api.chartSecretKeys" $root | fromJsonArray -}}
{{- $files := merge
  (include "ow.db.secretFiles" (list $root "api" "db-password") | fromJson)
  (include "ow.db.secretFiles" (list $root "oidc" "oidc-db-password") | fromJson) -}}
{{- $files = merge $files (dict
  "api-secret-key" (dict "secret" ($api.existingSecret | default $chartSecret) "key" "api-secret-key")
  "token-hash-secret.json" (dict "secret" (include "ow.api.keySecretName" (list $root "tokenHash" "api-token-hash")) "key" $ks.tokenHash.key)
  "token-signing-jwks.json" (dict "secret" (include "ow.api.keySecretName" (list $root "tokenSigning" "api-token-signing")) "key" $ks.tokenSigning.key)
  "db-wrapping-keys.json" (dict "secret" (include "ow.api.keySecretName" (list $root "dbWrapping" "api-db-wrapping")) "key" $ks.dbWrapping.key)) -}}
{{- $reader := include "ow.readAccess.reader" (list $root "api" "wallet") | fromJson -}}
{{- $_ := set $files "read-access-wallet-password" (dict "secret" $reader.secret "key" $reader.key) -}}
{{- $signing := include "ow.serviceKeys.signing" (list $root $api "api" "api-service-key") | fromJson -}}
{{- $_ := set $files "service-envelope-jwks.json" (dict "secret" $signing.secret "key" $signing.key) -}}
{{- with $root.Values.nats.tlsCa.existingSecret -}}
{{- $_ := set $files "nats-ca.crt" (dict "secret" . "key" $root.Values.nats.tlsCa.key) -}}
{{- end -}}
{{- if $api.smtp.host -}}
{{- if $api.smtp.existingSecret -}}
{{- $_ := set $files "smtp-password" (dict "secret" $api.smtp.existingSecret "key" $api.smtp.passwordKey) -}}
{{- else if has "smtp-password" $chartKeys -}}
{{- $_ := set $files "smtp-password" (dict "secret" $chartSecret "key" "smtp-password") -}}
{{- end -}}
{{- end -}}
{{- if $api.twilio.existingSecret -}}
{{- $_ := set $files "twilio-account-sid" (dict "secret" $api.twilio.existingSecret "key" $api.twilio.accountSidKey) -}}
{{- $_ := set $files "twilio-auth-token" (dict "secret" $api.twilio.existingSecret "key" $api.twilio.authTokenKey) -}}
{{- else if has "twilio-account-sid" $chartKeys -}}
{{- $_ := set $files "twilio-account-sid" (dict "secret" $chartSecret "key" "twilio-account-sid") -}}
{{- $_ := set $files "twilio-auth-token" (dict "secret" $chartSecret "key" "twilio-auth-token") -}}
{{- end -}}
{{- toJson $files -}}
{{- end }}

{{/*
Path of one api secret file, or "" when the chart has no such file.
Call with (list $ "<file name>").
*/}}
{{- define "ow.api.secretFile" -}}
{{- $files := include "ow.api.secretFiles" (index . 0) | fromJson -}}
{{- if hasKey $files (index . 1) -}}
{{ include "ow.api.secretDir" (index . 0) }}/{{ index . 1 }}
{{- end -}}
{{- end }}

{{/*
Volume mounts of the api configuration (ConfigMap key <role>.yaml) and the
secret files. Output: a list at column 0.
*/}}
{{- define "ow.api.volumeMounts" -}}
- name: config
  mountPath: {{ include "ow.api.configPath" . | dir }}
  readOnly: true
- name: secrets
  mountPath: {{ include "ow.api.secretDir" . }}
  readOnly: true
- name: service-keys
  mountPath: {{ include "ow.serviceKeys.dir" . }}
  readOnly: true
{{- end }}

{{/*
Volumes of the api: the configuration of one role ("api" or "webhook";
the operator Jobs use "api") and the secret files (mode 0440). Call with
(list $ "<role>"). Output: a list at column 0.
*/}}
{{- define "ow.api.volumes" -}}
{{- $root := index . 0 -}}
{{- include "ow.gateway.checkGatewayJwks" $root }}
# The configuration and the public keys of the gateway (GatewayToken).
- name: config
  projected:
    sources:
      - configMap:
          name: {{ include "ow.name" (list $root "api") }}
          items:
            - key: {{ index . 1 }}.yaml
              path: {{ include "ow.api.configPath" $root | base }}
      - configMap:
          name: {{ include "ow.gateway.publicKeysConfigMap" $root }}
          items:
            - key: {{ $root.Values.gateway.publicKeys.gatewayJwksKey }}
              path: gateway-jwks.json
- name: secrets
  projected:
    defaultMode: 0440
    sources:
      {{- range $path, $file := include "ow.api.secretFiles" $root | fromJson }}
      - secret:
          name: {{ $file.secret }}
          items:
            - key: {{ $file.key }}
              path: {{ $path }}
      {{- end }}
      {{- /* The nkey seed of the NATS user of the role (api, api-webhook for
      the webhook handler). */}}
      {{- $client := include "ow.nats.client" (list $root (include "ow.api.natsUser" (index . 1))) | fromJson }}
      {{- with $client.seed }}
      - secret:
          name: {{ .secret }}
          items:
            - key: {{ .key }}
              path: nats-seed
      {{- end }}
{{ include "ow.serviceKeys.volume" (list $root "igrant-api" "igrant-consent-management" "eudi-wallet") }}
{{- end }}

{{/* Folder of the consent secret files (one projected volume). */}}
{{- define "ow.consent.secretDir" -}}
/run/secrets/consent
{{- end }}

{{/*
The owner databases that consent reads with its own read-only users
(ReadAccess).
*/}}
{{- define "ow.consent.readAccessOwners" -}}
api,wallet
{{- end }}

{{/*
Volume mounts of consent (the service and its Jobs): the configuration, the
secret files, the public keys of the gateway and of the trusted services.
Output: a list at column 0.
*/}}
{{- define "ow.consent.volumeMounts" -}}
- name: config
  mountPath: /etc/consent
  readOnly: true
- name: secrets
  mountPath: {{ include "ow.consent.secretDir" . }}
  readOnly: true
- name: gateway-keys
  mountPath: {{ include "ow.gateway.keysDir" . }}
  readOnly: true
- name: service-keys
  mountPath: {{ include "ow.serviceKeys.dir" . }}
  readOnly: true
{{- end }}

{{/*
Volumes of consent (the service and its Jobs). The secret volume holds the
database password and CA, the passwords of the read-only users (ReadAccess), the
nkey seed of the NATS user, the private JWKS of the signed NATS envelopes
and the optional NATS CA (mode 0440). Output: a list at column 0.
*/}}
{{- define "ow.consent.volumes" -}}
{{- $root := . -}}
{{- $client := include "ow.nats.client" (list $root "consent") | fromJson -}}
{{- $signing := include "ow.serviceKeys.signing" (list $root $root.Values.consent "consent" "consent-service-key") | fromJson -}}
- name: config
  configMap:
    name: {{ include "ow.name" (list $root "consent") }}
- name: secrets
  projected:
    defaultMode: 0440
    sources:
      {{- range $path, $file := include "ow.db.secretFiles" (list $root "consent" "database-password") | fromJson }}
      - secret:
          name: {{ $file.secret }}
          items:
            - key: {{ $file.key }}
              path: {{ $path }}
      {{- end }}
      {{- range $owner := include "ow.consent.readAccessOwners" $root | splitList "," }}
      {{- $reader := include "ow.readAccess.reader" (list $root "consent" $owner) | fromJson }}
      - secret:
          name: {{ $reader.secret }}
          items:
            - key: {{ $reader.key }}
              path: read-access-{{ $owner }}-password
      {{- end }}
      - secret:
          name: {{ $client.seed.secret }}
          items:
            - key: {{ $client.seed.key }}
              path: nats-seed
      - secret:
          name: {{ $signing.secret }}
          items:
            - key: {{ $signing.key }}
              path: service-envelope-jwks.json
      {{- with $root.Values.nats.tlsCa.existingSecret }}
      - secret:
          name: {{ . }}
          items:
            - key: {{ $root.Values.nats.tlsCa.key }}
              path: nats-ca.crt
      {{- end }}
{{ include "ow.gateway.keysVolume" $root }}
{{ include "ow.serviceKeys.volume" (list $root "igrant-api" "eudi-wallet") }}
{{- end }}

{{/* The NATS user (values key) of one api role (api, webhook). */}}
{{- define "ow.api.natsUser" -}}
{{- get (dict "api" "api" "webhook" "apiWebhook") . -}}
{{- end }}

{{/*
The owner databases that the wallet config role reads with its own read-only
users (read_access).
*/}}
{{- define "ow.wallet.readAccessOwners" -}}
api,consent
{{- end }}

{{/* The NATS user (values key) of one wallet role. */}}
{{- define "ow.wallet.natsUser" -}}
{{- $users := dict "config" "walletConfig" "service" "walletService" "scheduler" "walletScheduler" -}}
{{- get $users . -}}
{{- end }}

{{/* Folder of the wallet secret files (one projected volume). */}}
{{- define "ow.wallet.secretDir" -}}
/run/secrets/eudi-wallet
{{- end }}

{{/* Path of the wallet configuration file (EUDI_WALLET_CONFIG). */}}
{{- define "ow.wallet.configPath" -}}
/etc/eudi-wallet/config.yaml
{{- end }}

{{/*
Secret files of one wallet role ("service", "config" or "scheduler").
All are files in one read-only folder (ow.wallet.secretDir), a
projected volume of these Secret keys. Call with (list $ "<role>").
Output: JSON object "<file name>" -> {secret, key}.
*/}}
{{- define "ow.wallet.secretFiles" -}}
{{- $root := index . 0 -}}
{{- $role := index . 1 -}}
{{- $w := $root.Values.organisationWallet -}}
{{- $files := include "ow.db.secretFiles" (list $root "wallet" "database-password") | fromJson -}}
{{- /* Every wallet process connects to NATS with the nkey user of its role. */ -}}
{{- $client := include "ow.nats.client" (list $root (include "ow.wallet.natsUser" $role)) | fromJson -}}
{{- if $client.seed -}}
{{- $_ := set $files "nats-seed" $client.seed -}}
{{- end -}}
{{- with $root.Values.nats.tlsCa.existingSecret -}}
{{- $_ := set $files "nats-ca.crt" (dict "secret" . "key" $root.Values.nats.tlsCa.key) -}}
{{- end -}}
{{- /* The OpenBao login of the wallet KMS (password) and the OpenBao CA. */ -}}
{{- $_ := set $files "openbao-password" (include "ow.openbao.walletSecret" $root | fromJson) -}}
{{- with include "ow.openbao.ca" $root | fromJson -}}
{{- if .secret -}}{{- $_ := set $files "openbao-ca.crt" . -}}{{- end -}}
{{- end -}}
{{- with $w.walletUnit.playIntegrity.existingSecret -}}
{{- $_ := set $files "play-integrity-service-account.json" (dict "secret" . "key" $w.walletUnit.playIntegrity.key) -}}
{{- end -}}
{{- with $w.storage.credentials.existingSecret -}}
{{- $_ := set $files "storage-service-account.json" (dict "secret" . "key" $w.storage.credentials.key) -}}
{{- end -}}
{{- with $w.trustList.lookupToken.existingSecret -}}
{{- $_ := set $files "trust-list-lookup-token" (dict "secret" . "key" $w.trustList.lookupToken.key) -}}
{{- end -}}
{{- /* The config role reads the views of the api and consent databases with
the read-only users of the wallet (read_access). */ -}}
{{- if eq $role "config" -}}
{{- range $owner := include "ow.wallet.readAccessOwners" $root | splitList "," -}}
{{- $reader := include "ow.readAccess.reader" (list $root "wallet" $owner) | fromJson -}}
{{- $_ := set $files (printf "read-access-%s-password" $owner) (dict "secret" $reader.secret "key" $reader.key) -}}
{{- end -}}
{{- end -}}
{{- /* Every wallet process signs its NATS events with the private JWKS of
the wallet. */ -}}
{{- $signing := include "ow.serviceKeys.signing" (list $root $w "organisationWallet" "wallet-service-key") | fromJson -}}
{{- $_ := set $files "service-envelope-jwks.json" (dict "secret" $signing.secret "key" $signing.key) -}}
{{- toJson $files -}}
{{- end }}

{{/*
Volumes of one wallet role: the configuration (ConfigMap key <role>.yaml as
config.yaml) and the secret files (mode 0440). Call with (list $ "<role>").
Output: a list at column 0.
*/}}
{{- define "ow.wallet.volumes" -}}
{{- $root := index . 0 -}}
- name: config
  configMap:
    name: {{ include "ow.name" (list $root "wallet") }}
    items:
      - key: {{ index . 1 }}.yaml
        path: {{ include "ow.wallet.configPath" $root | base }}
- name: secrets
  projected:
    defaultMode: 0440
    sources:
      {{- range $path, $file := include "ow.wallet.secretFiles" . | fromJson }}
      - secret:
          name: {{ $file.secret }}
          items:
            - key: {{ $file.key }}
              path: {{ $path }}
      {{- end }}
{{- end }}

{{/* Volume mounts of the wallet configuration and secret files. Output: a list at column 0. */}}
{{- define "ow.wallet.volumeMounts" -}}
- name: config
  mountPath: {{ include "ow.wallet.configPath" . | dir }}
  readOnly: true
- name: secrets
  mountPath: {{ include "ow.wallet.secretDir" . }}
  readOnly: true
{{- end }}

{{/* Folder of the gateway secret files (one projected volume). */}}
{{- define "ow.gateway.secretDir" -}}
/run/secrets/igrant-gateway
{{- end }}

{{/* Path of the gateway configuration file (--config). */}}
{{- define "ow.gateway.configPath" -}}
/etc/igrant-gateway/config.yaml
{{- end }}

{{/*
Name of the shared ConfigMap with the public keys of the gateway
(gateway-jwks.json): the api core, consent and the wallet config role check
the internal token with them. gateway.publicKeys.existingConfigMap, else the
ConfigMap <fullname>-igrant-gateway-jwks of the chart (the same name in all
services).
*/}}
{{- define "ow.gateway.publicKeysConfigMap" -}}
{{- .Values.gateway.publicKeys.existingConfigMap | default (include "ow.name" (list . "igrant-gateway-jwks")) -}}
{{- end }}

{{/*
Name of the ConfigMap with the public keys of the api tokens
(token-verification-jwks.json; only the gateway reads it):
gateway.publicKeys.existingTokenVerificationConfigMap, else the gateway
ConfigMap of the chart (next to config.yaml).
*/}}
{{- define "ow.gateway.tokenVerificationConfigMap" -}}
{{- .Values.gateway.publicKeys.existingTokenVerificationConfigMap | default (include "ow.name" (list . "gateway")) -}}
{{- end }}

{{/*
Secret files of the gateway. All are files in one read-only folder
(ow.gateway.secretDir), a projected volume of these Secret keys: the API
secret key, the api database password and CA, the token hash secret (the same
Secrets as the api), and the private JWKS of the internal token (its own
Secret). The gateway gets no token signing key of the api.
Output: JSON object "<file name>" -> {secret, key}.
*/}}
{{- define "ow.gateway.secretFiles" -}}
{{- $api := include "ow.api.secretFiles" . | fromJson -}}
{{- $signing := .Values.gateway.internalToken.signingKey -}}
{{- $files := include "ow.db.secretFiles" (list . "api" "db-password") | fromJson -}}
{{- $files = merge $files (dict
  "api-secret-key" (get $api "api-secret-key")
  "token-hash-secret.json" (get $api "token-hash-secret.json")
  "internal-token-jwks.json" (dict "secret" ($signing.existingSecret | default (include "ow.name" (list . "gateway-internal-token"))) "key" $signing.key)) -}}
{{- toJson $files -}}
{{- end }}

{{/* Folder of the public keys of the gateway in the consent and wallet config pods. */}}
{{- define "ow.gateway.keysDir" -}}
/etc/igrant-gateway-keys
{{- end }}

{{/*
The gateway public keys volume of a service pod (gateway-jwks.json in
ow.gateway.keysDir). Output: a list at column 0.
*/}}
{{- define "ow.gateway.keysVolume" -}}
- name: gateway-keys
  configMap:
    name: {{ include "ow.gateway.publicKeysConfigMap" . }}
    items:
      - key: {{ .Values.gateway.publicKeys.gatewayJwksKey }}
        path: gateway-jwks.json
{{- end }}

{{/*
Checks the public keys of the gateway (gateway-jwks.json): the api core,
consent and the wallet config role verify the internal token of every
request with them. Output: nothing.
*/}}
{{- define "ow.gateway.checkGatewayJwks" -}}
{{- $keys := .Values.gateway.publicKeys -}}
{{- if and (not $keys.existingConfigMap) (not $keys.gatewayJwks) -}}
{{- fail "gateway.publicKeys.gatewayJwks (or gateway.publicKeys.existingConfigMap) is required: the public keys of the gateway, which the api core, consent and the wallet use to verify the internal token (igrant-api keys export-token-jwks; see docs/keys.md)" -}}
{{- end -}}
{{- end }}

{{/*
The api requests that consent sends (the subject contract of
the services),
each subject by name: a new consent request needs a change of the chart.
Consent publishes its events by name too (the stream CONSENT_EVENTS). Output: JSON list.
*/}}
{{- define "ow.nats.consentApiRequests" -}}
{{- toJson (list
  "api.v1.rpc.organisation.get"
  "api.v1.rpc.individual.get"
  "api.v1.rpc.wallet.definition.check"
  "api.v1.rpc.wallet.jwt.create"
  "api.v1.rpc.wallet.jwt.verify"
  "api.v1.rpc.wallet.software_statement.present"
  "api.v1.rpc.wallet.software_statement.validate"
  "api.v1.rpc.wallet.dda_signature.create"
  "api.v1.rpc.wallet.verification_request.send"
  "api.v1.rpc.wallet.verification_request.receive") -}}
{{- end }}

{{/*
The JetStream rights of one NATS user: only the JetStream API subjects that
its process uses: the streams that it
ensures (STREAM.INFO/CREATE/UPDATE), its own durables (CONSUMER.INFO, CREATE
in its three forms, DELETE; MSG.NEXT for a pull consumer; the acks
$JS.ACK.<stream>.<durable>.>), the retired durables that it deletes (INFO,
DELETE) and its KV buckets (the KV stream, the direct get, the puts). No
STREAM.DELETE, STREAM.PURGE or other API subject: a service cannot delete or
purge the stream or the consumers of another service. Call with the values
key of the user. Output: JSON list.
*/}}
{{- define "ow.nats.jetStreamRights" -}}
{{- $spec := dig . dict (dict
  "api" (dict
    "streams" (list "OWS_MICROSERVICE" "API_EVENTS")
    "durables" (list "OWS_MICROSERVICE/openidprovider-client-created" "OWS_MICROSERVICE/openidprovider-client-deleted" "OWS_MICROSERVICE/openidprovider-clients-deleted")
    "retired" (list "OWS_MICROSERVICE/api-wua-revocation")
    "kv" (list "OWS_ENVELOPE_JTI")
    "extra" (list "$JS.API.INFO"))
  "apiWebhook" (dict
    "streams" (list "OWS_MICROSERVICE" "API_EVENTS")
    "durables" (list "OWS_MICROSERVICE/api-webhook-issue-credential" "OWS_MICROSERVICE/api-webhook-credential" "OWS_MICROSERVICE/api-webhook-present-proof" "OWS_MICROSERVICE/api-webhook-presentation" "OWS_MICROSERVICE/api-push-requested" "CONSENT_EVENTS/api-consent-webhooks" "CONSENT_EVENTS/api-consent-policy")
    "retired" (list "OWS_MICROSERVICE/api-wua-revocation"))
  "consent" (dict
    "streams" (list "CONSENT_EVENTS")
    "pull" (list "API_EVENTS/consent-api-organisation" "OWS_MICROSERVICE/consent-dda-present-proof" "OWS_MICROSERVICE/consent-dda-presentation"))
  "walletConfig" (dict
    "streams" (list "OWS_MICROSERVICE")
    "pull" (list "API_EVENTS/eudi-wallet-api-triggers")
    "retired" (list "OWS_MICROSERVICE/credential-definition-worker" "OWS_MICROSERVICE/presentation-definition-worker")
    "kv" (list "wallet-command-replay" "wallet-command-replies"))
  "walletService" (dict
    "streams" (list "OWS_MICROSERVICE")
    "retired" (list "OWS_MICROSERVICE/credential-definition-worker" "OWS_MICROSERVICE/presentation-definition-worker"))
  "walletScheduler" (dict
    "streams" (list "OWS_MICROSERVICE"))) -}}
{{- $out := list -}}
{{- range $stream := concat ($spec.streams | default list) (list) -}}
{{- $out = concat $out (list (printf "$JS.API.STREAM.INFO.%s" $stream) (printf "$JS.API.STREAM.CREATE.%s" $stream) (printf "$JS.API.STREAM.UPDATE.%s" $stream)) -}}
{{- end -}}
{{- range $kind := list "durables" "pull" -}}
{{- range $item := (get $spec $kind | default list) -}}
{{- $stream := index (splitList "/" $item) 0 -}}{{- $name := index (splitList "/" $item) 1 -}}
{{- $out = concat $out (list
    (printf "$JS.API.CONSUMER.INFO.%s.%s" $stream $name)
    (printf "$JS.API.CONSUMER.CREATE.%s.%s" $stream $name)
    (printf "$JS.API.CONSUMER.CREATE.%s.%s.>" $stream $name)
    (printf "$JS.API.CONSUMER.DURABLE.CREATE.%s.%s" $stream $name)
    (printf "$JS.API.CONSUMER.DELETE.%s.%s" $stream $name)
    (printf "$JS.ACK.%s.%s.>" $stream $name)) -}}
{{- if eq $kind "pull" -}}{{- $out = append $out (printf "$JS.API.CONSUMER.MSG.NEXT.%s.%s" $stream $name) -}}{{- end -}}
{{- end -}}
{{- end -}}
{{- range $item := ($spec.retired | default list) -}}
{{- $stream := index (splitList "/" $item) 0 -}}{{- $name := index (splitList "/" $item) 1 -}}
{{- $out = concat $out (list (printf "$JS.API.CONSUMER.INFO.%s.%s" $stream $name) (printf "$JS.API.CONSUMER.DELETE.%s.%s" $stream $name)) -}}
{{- end -}}
{{- range $bucket := ($spec.kv | default list) -}}
{{- $out = concat $out (list
    (printf "$JS.API.STREAM.INFO.KV_%s" $bucket) (printf "$JS.API.STREAM.CREATE.KV_%s" $bucket) (printf "$JS.API.STREAM.UPDATE.KV_%s" $bucket)
    (printf "$JS.API.DIRECT.GET.KV_%s" $bucket) (printf "$JS.API.DIRECT.GET.KV_%s.>" $bucket) (printf "$JS.API.STREAM.MSG.GET.KV_%s" $bucket)
    (printf "$KV.%s.>" $bucket)) -}}
{{- end -}}
{{- toJson (concat $out ($spec.extra | default list) | uniq) -}}
{{- end }}

{{/*
NATS users of the services: one nkey user per service process in the global
account, with the subjects of the process. Each item: name, values key,
nkey, seed {secret, key}, inbox prefix, publish, subscribe, allowResponses,
enabled (the process is in the chart). The services publish their events
and requests by name (the stream and subject contract of the services); the
wallet commands stay ows.cmd.>.
The JetStream consumers of a process (pull, and push with a deliver subject
from its inbox prefix) get their messages on its inbox, so a process
subscribes only to its inbox, to the requests that it serves (api.v1.rpc.>,
ows.cmd.*.>) and to the events of its core subscriptions (start-api: the
passwordless status waits; start-scheduler: ows.wia_pool.refill_requested,
the WIA pool refill event of the config and service roles). The JetStream
API rights are the exact subjects
of each process (ow.nats.jetStreamRights): the services ensure their
streams, durables and KV buckets at start, and nobody can delete or purge
the stream or the consumers of another service. Output: JSON list.
*/}}
{{- define "ow.nats.users" -}}
{{- $v := .Values -}}
{{- $users := $v.nats.auth.users -}}
{{- $table := list
  (dict "name" "api" "key" "api" "inbox" "_INBOX_api" "enabled" $v.api.enabled "allowResponses" true
    "publish" (concat (list "ows.cmd.>")
      (list "api.v1.evt.organisation.created" "api.v1.evt.organisation.updated" "api.v1.evt.sandbox.updated" "api.v1.evt.sandbox.deleted" "api.v1.evt.extension.updated")
      (list "ows.openidprovider.client.created" "ows.openidprovider.client.deleted" "ows.openidprovider.clients.deleted")
      (include "ow.nats.jetStreamRights" "api" | fromJsonArray))
    "subscribe" (list "api.v1.rpc.>" "ows.users.*.authentication.oidcpasswordless.verified" "ows.users.*.authentication.oidcpasswordless.accepted"))
  (dict "name" "api-webhook" "key" "apiWebhook" "inbox" "_INBOX_apiwh" "enabled" $v.api.enabled "allowResponses" false
    "publish" (concat (list "ows.users.*.authentication.oidcpasswordless.verified" "ows.users.*.authentication.oidcpasswordless.accepted" "ows.cmd.*.credential_history.set_revocation_status") (include "ow.nats.jetStreamRights" "apiWebhook" | fromJsonArray))
    "subscribe" (list))
  (dict "name" "consent" "key" "consent" "inbox" "_INBOX_consent" "enabled" $v.consent.enabled "allowResponses" false
    "publish" (concat (include "ow.nats.consentApiRequests" . | fromJsonArray) (list "consent.v1.evt.webhook.requested" "consent.v1.evt.policy.updated") (include "ow.nats.jetStreamRights" "consent" | fromJsonArray))
    "subscribe" (list))
  (dict "name" "wallet-config" "key" "walletConfig" "inbox" "_INBOX_wallet" "enabled" $v.organisationWallet.enabled "allowResponses" true
    "publish" (concat (list "ows.*.webhook.*" "ows.*.notification" "ows.*.evt.push_requested" "ows.wia_pool.refill_requested") (include "ow.nats.jetStreamRights" "walletConfig" | fromJsonArray))
    "subscribe" (list "ows.cmd.*.>" "ows.*.notification" "ows.*.webhook.present_proof"))
  (dict "name" "wallet-service" "key" "walletService" "inbox" "_INBOX_wallet" "enabled" $v.organisationWallet.enabled "allowResponses" false
    "publish" (concat (list "ows.*.webhook.*" "ows.*.notification" "ows.*.evt.push_requested" "ows.wia_pool.refill_requested") (include "ow.nats.jetStreamRights" "walletService" | fromJsonArray))
    "subscribe" (list))
  (dict "name" "wallet-scheduler" "key" "walletScheduler" "inbox" "_INBOX_wallet" "enabled" $v.organisationWallet.enabled "allowResponses" false
    "publish" (concat (list "ows.*.webhook.*" "ows.*.notification" "ows.*.evt.push_requested") (include "ow.nats.jetStreamRights" "walletScheduler" | fromJsonArray))
    "subscribe" (list "ows.wia_pool.refill_requested")) -}}
{{- $out := list -}}
{{- range $user := $table -}}
{{- $values := index $users $user.key | default dict -}}
{{- $seed := dict -}}
{{- with $values.seedSecret -}}{{- $seed = dict "secret" . "key" ($values.seedKey | default "seed") -}}{{- end -}}
{{- $out = append $out (dict
    "name" $user.name "key" $user.key "nkey" ($values.nkey | default "") "seed" $seed "inbox" $user.inbox
    "enabled" $user.enabled "allowResponses" $user.allowResponses
    "publish" $user.publish
    "subscribe" (concat $user.subscribe (list (printf "%s.>" $user.inbox)))) -}}
{{- end -}}
{{- toJson $out -}}
{{- end }}

{{/*
Checks the NATS users: every process of the chart connects with its own
nkey user, so each needs the public nkey and the seed Secret. The server has
no user without credentials. Output: nothing.
*/}}
{{- define "ow.nats.checkUsers" -}}
{{- $missing := list -}}
{{- range $user := include "ow.nats.users" . | fromJsonArray -}}
{{- if and $user.nkey (not (hasPrefix "U" $user.nkey)) -}}
{{- fail (printf "nats.auth.users.%s.nkey must be a public user nkey (it starts with U), never the seed" $user.key) -}}
{{- end -}}
{{- if and $user.enabled (or (not $user.nkey) (not $user.seed)) -}}
{{- $missing = append $missing (printf "nats.auth.users.%s (%s)" $user.key $user.name) -}}
{{- end -}}
{{- end -}}
{{- if $missing -}}
{{- fail (printf "every process connects to NATS with its own nkey user: set nkey and seedSecret for %s (make a pair with \"nsc generate nkey --user\"; see docs/nats-users.md)" (join ", " $missing)) -}}
{{- end -}}
{{- end }}

{{/*
The authorization block of nats.conf: the users of the processes of the
chart, no user without credentials. Output: text at column 0.
*/}}
{{- define "ow.nats.authorization" -}}
{{- include "ow.nats.checkUsers" . -}}
authorization {
  users = [
    {{- range $user := include "ow.nats.users" . | fromJsonArray }}
    {{- if $user.nkey }}
    # {{ $user.name }}
    {{- /* An empty allow list is no restriction in nats.conf: a process
    without publish subjects gets a deny of all subjects. */}}
    { nkey: {{ $user.nkey | quote }}, permissions: { publish: { {{ if $user.publish }}allow: {{ include "ow.nats.list" $user.publish }}{{ else }}deny: [">"]{{ end }} }, subscribe: { allow: {{ include "ow.nats.list" $user.subscribe }} }{{ if $user.allowResponses }}, allow_responses: true{{ end }} } }
    {{- end }}
    {{- end }}
  ]
}
{{- end }}

{{/* A list of subjects in nats.conf syntax (quoted, no JSON escapes). */}}
{{- define "ow.nats.list" -}}
[{{ range $i, $subject := . }}{{ if $i }}, {{ end }}{{ $subject | quote }}{{ end }}]
{{- end }}

{{/*
Replicas of the JetStream streams and KV buckets (replay store) that the
services create (file storage). nats.jetstreamReplicas,
else nats.replicas when the chart runs NATS, else 1 (an external NATS: set
the value to its cluster size). A production cluster uses 3.
*/}}
{{- define "ow.nats.jetstreamReplicas" -}}
{{- .Values.nats.jetstreamReplicas | default (ternary .Values.nats.replicas 1 .Values.nats.enabled) | int -}}
{{- end }}

{{/* Folder of the public service keys (ConfigMap igrant-service-jwks) in the service pods. */}}
{{- define "ow.serviceKeys.dir" -}}
/etc/igrant-service-keys
{{- end }}

{{/*
Name of the shared ConfigMap with the public JWKS of the services
(<issuer>.json): serviceKeys.existingConfigMap, else the ConfigMap
<fullname>-igrant-service-jwks of the chart (the same name in all
services).
*/}}
{{- define "ow.serviceKeys.configMap" -}}
{{- .Values.serviceKeys.existingConfigMap | default (include "ow.name" (list . "igrant-service-jwks")) -}}
{{- end }}

{{/*
The trusted services of the signed NATS envelopes of one service, and the
check that their public JWKS are in the chart (serviceKeys.publicJwks, or an
existing ConfigMap). Call with (list $ "<issuer>" ...). Output: JSON list
of {issuer, jwksFile}.
*/}}
{{- define "ow.serviceKeys.trusted" -}}
{{- $root := index . 0 -}}
{{- $out := list -}}
{{- range $issuer := rest . -}}
{{- if and (not $root.Values.serviceKeys.existingConfigMap) (not (index $root.Values.serviceKeys.publicJwks $issuer)) -}}
{{- fail (printf "serviceKeys.publicJwks.%s (or serviceKeys.existingConfigMap) is required: the public keys of the signed NATS envelopes of %s (igrant-api keys export-token-jwks; see docs/keys.md)" $issuer $issuer) -}}
{{- end -}}
{{- $out = append $out (dict "issuer" $issuer "jwksFile" (printf "%s/%s.json" (include "ow.serviceKeys.dir" $root) $issuer)) -}}
{{- end -}}
{{- toJson $out -}}
{{- end }}

{{/*
The volume of the public service keys for the trusted issuers of one
service. Call with (list $ "<issuer>" ...). Output: a list at column 0.
*/}}
{{- define "ow.serviceKeys.volume" -}}
{{- $root := index . 0 -}}
- name: service-keys
  configMap:
    name: {{ include "ow.serviceKeys.configMap" $root }}
    items:
      {{- range $issuer := rest . }}
      - key: {{ $issuer }}.json
        path: {{ $issuer }}.json
      {{- end }}
{{- end }}

{{/*
The private JWKS Secret of the signed NATS envelopes of one service, and the
check of its active kid. Call with (list $ <service values> "<values key>"
"<default secret suffix>"). Output: JSON {secret, key, activeKid}.
*/}}
{{- define "ow.serviceKeys.signing" -}}
{{- $root := index . 0 -}}
{{- $envelope := (index . 1).serviceEnvelope -}}
{{- $key := index . 2 -}}
{{- $kid := required (printf "%s.serviceEnvelope.activeKid is required: the kid of the active key in the private JWKS of the signed NATS envelopes (igrant-api keys generate-token-key; see docs/keys.md)" $key) $envelope.activeKid -}}
{{- toJson (dict
  "secret" ($envelope.signingKey.existingSecret | default (include "ow.name" (list $root (index . 3))))
  "key" $envelope.signingKey.key
  "activeKid" ($kid | toString)) -}}
{{- end }}

{{/*
NATS client values of one process: the seed Secret of its user, the inbox
prefix and the optional CA. Call with (list $ "<user values key>"). Output:
JSON {seed: {secret, key}, inbox}.
*/}}
{{- define "ow.nats.client" -}}
{{- $root := index . 0 -}}
{{- $key := index . 1 -}}
{{- $found := dict -}}
{{- range $user := include "ow.nats.users" $root | fromJsonArray -}}
{{- if eq $user.key $key -}}{{- $found = $user -}}{{- end -}}
{{- end -}}
{{- toJson (dict "seed" $found.seed "inbox" $found.inbox) -}}
{{- end }}

{{/*
The read-only database user of one reader for one owner database, and the
check that it is set. Call with (list $ "<reader>"
"<owner>"); reader and owner are keys of database.databases. Output: JSON
{host, port, name, username, secret, key}. Empty host, port and name: the
database of the owner in this chart. The engine and the TLS settings are
always the ones of database.* (ow.db.go, ow.db.wallet).
*/}}
{{- define "ow.readAccess.reader" -}}
{{- $root := index . 0 -}}
{{- $reader := index . 1 -}}
{{- $owner := index . 2 -}}
{{- include "ow.readAccess.checkNames" $root -}}
{{- $entry := index (index $root.Values.readAccess $reader | default dict) $owner | default dict -}}
{{- $key := printf "readAccess.%s.%s" $reader $owner -}}
{{- if not $entry.username -}}
{{- fail (printf "%s.username is required: %s reads the views of the %s database with its own read-only user (see docs/read-access.md)" $key $reader $owner) -}}
{{- end -}}
{{- /* A name that the read-access commands of all owners accept (wallet:
^[a-z][a-z0-9_]{0,62}$; api and consent accept more); MySQL user names
have at most 32 characters. */ -}}
{{- if not (regexMatch "^[a-z][a-z0-9_]{0,62}$" $entry.username) -}}
{{- fail (printf "%s.username %q is not a database user name: a lower-case letter, then lower-case letters, digits or _ (at most 63)" $key $entry.username) -}}
{{- end -}}
{{- if and (include "ow.db.isMysql" $root) (gt (len $entry.username) 32) -}}
{{- fail (printf "%s.username %q has more than 32 characters: the limit of a MySQL user name" $key $entry.username) -}}
{{- end -}}
{{- toJson (dict
  "host" ($entry.host | default (include "ow.db.host" $root))
  "port" ($entry.port | default (include "ow.db.port" $root) | int)
  "name" ($entry.name | default (index $root.Values.database.databases $owner).name)
  "username" $entry.username
  "secret" ($entry.passwordSecret | default (include "ow.readAccess.secretName" $root))
  "key" (ternary ($entry.passwordKey | default "password") (printf "%s-%s" $reader $owner) (not (empty $entry.passwordSecret)))) -}}
{{- end }}

{{/* Name of the Secret of the chart with the passwords of the read-only users (key <reader>-<owner>). */}}
{{- define "ow.readAccess.secretName" -}}
{{ include "ow.name" (list . "read-access") }}
{{- end }}

{{/*
The admin user of the read access Job of one owner database
(readAccess.jobs.<owner>; "read-access apply --admin-user
--admin-password-file"): it makes the read-only users and grants SELECT on
the views. Empty values: the admin user of database.* (ow.db.admin: the
"postgres" or "root" user of the bundled server, or
database.external.admin). Call with (list $ "<owner>"). Output: JSON
{user, secret, key}.
*/}}
{{- define "ow.readAccess.admin" -}}
{{- $root := index . 0 -}}
{{- $owner := index . 1 -}}
{{- $access := index $root.Values.readAccess.jobs $owner -}}
{{- $admin := include "ow.db.admin" $root | fromJson -}}
{{- $user := $access.adminUser | default $admin.user -}}
{{- $secret := $access.adminPasswordSecret -}}
{{- $key := $access.adminPasswordKey -}}
{{- if not $secret -}}
{{- $secret = $admin.secret -}}
{{- $key = $key | default $admin.key -}}
{{- end -}}
{{- $prefix := printf "readAccess.jobs.%s" $owner -}}
{{- toJson (dict
  "user" (required (printf "%s.adminUser (or database.external.admin.user) is required: the admin user that makes the read-only users" $prefix) $user)
  "secret" (required (printf "%s.adminPasswordSecret (or database.external.admin.passwordSecret) is required: the Secret with the password of the admin user" $prefix) $secret)
  "key" (required (printf "%s.adminPasswordKey is required with adminPasswordSecret" $prefix) $key)) -}}
{{- end }}

{{/*
Checks that no two read-only users of the chart have the same name on one
database server: a PostgreSQL role (MySQL account) belongs to the whole
server, so the second "read-access apply" would change the password of the
first user, and one read connection would fail. The pairs of the enabled
services: api -> wallet; consent -> api, wallet; wallet -> api, consent.
Output: nothing.
*/}}
{{- define "ow.readAccess.checkNames" -}}
{{- $root := . -}}
{{- $v := $root.Values -}}
{{- $pairs := list -}}
{{- if $v.api.enabled -}}{{- $pairs = append $pairs (list "api" "wallet") -}}{{- end -}}
{{- if $v.consent.enabled -}}{{- $pairs = concat $pairs (list (list "consent" "api") (list "consent" "wallet")) -}}{{- end -}}
{{- if $v.organisationWallet.enabled -}}{{- $pairs = concat $pairs (list (list "wallet" "api") (list "wallet" "consent")) -}}{{- end -}}
{{- $seen := dict -}}
{{- range $pair := $pairs -}}
{{- $reader := index $pair 0 -}}
{{- $owner := index $pair 1 -}}
{{- $entry := index (index $v.readAccess $reader | default dict) $owner | default dict -}}
{{- if $entry.username -}}
{{- $host := $entry.host | default (include "ow.db.host" $root) -}}
{{- $port := $entry.port | default (include "ow.db.port" $root) | toString -}}
{{- $key := printf "%s|%s|%s" $host $port $entry.username -}}
{{- with get $seen $key -}}
{{- fail (printf "readAccess.%s.username and readAccess.%s.%s.username are both %q on the database server %s:%s: a PostgreSQL role (MySQL account) belongs to the whole server, so the second read-access apply changes the password of the first. Use one name per reader and owner, for example the default <reader>_<owner>_reader" . $reader $owner $entry.username $host $port) -}}
{{- end -}}
{{- $_ := set $seen $key (printf "%s.%s" $reader $owner) -}}
{{- end -}}
{{- end -}}
{{- end }}

{{/*
Stop budget of a Go server (api, webhook handler, gateway, consent): at
SIGTERM the server drains for drainSeconds, then waits at most
gracefulShutdownSeconds; Kubernetes must not kill it first, so
terminationGracePeriodSeconds must be at least drain + graceful + 5 s
margin (no preStop: the process drains itself). 0 = the default of the code
of the service. Call with (list "<values path>" <values with drainSeconds,
gracefulShutdownSeconds, terminationGracePeriodSeconds> <default drain>
<default graceful>).
*/}}
{{- define "ow.checkStopBudget" -}}
{{- $path := index . 0 -}}
{{- $v := index . 1 -}}
{{- $drain := $v.drainSeconds | int | default (index . 2) -}}
{{- $graceful := $v.gracefulShutdownSeconds | int | default (index . 3) -}}
{{- $need := add $drain $graceful 5 -}}
{{- if lt ($v.terminationGracePeriodSeconds | int) $need -}}
{{- fail (printf "%s.terminationGracePeriodSeconds (%v) must be at least drainSeconds (%v) + gracefulShutdownSeconds (%v) + 5 = %v: Kubernetes would kill the process before it stops" $path $v.terminationGracePeriodSeconds $drain $graceful $need) -}}
{{- end -}}
{{- end }}
