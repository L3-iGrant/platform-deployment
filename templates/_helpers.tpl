{{/*
Helpers for Secrets, the KMS, NATS, keys and read access. The database
helpers are in templates/database/_database.tpl.
*/}}

{{/*
The ClientAddress section of the api and gateway configs (the same in both):
clientAddress.header, .trustedProxies and .trustedProxyHeader. When empty,
the services use the TCP peer address. Output: JSON.
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
The SSRF guards of the api core, the webhook handler, the gateway and the
wallet (outboundHttp, docs/security-context.md, "The SSRF guards"). Each
service has a guard on by default; outboundHttp.ssrfProtection.enabled
false turns all of them off. The extra configuration keys of the services
cannot turn a guard off or allow a private host: two sources for one
setting. Call with the root context. Output: JSON {off: bool,
allowedPrivate: [...]}.
*/}}
{{- define "ow.outboundHttp" -}}
{{- $o := .Values.outboundHttp | default dict -}}
{{- if hasKey ((.Values.api.advanced.extraConfig | default dict).OutboundHttp | default dict) "ssrfProtectionDisabled" -}}
{{- fail "api.advanced.extraConfig.OutboundHttp.ssrfProtectionDisabled: set outboundHttp.ssrfProtection.enabled instead (the same setting for the api and the wallet)" -}}
{{- end -}}
{{- $walletSsrf := (.Values.organisationWallet.advanced.extraConfig | default dict).ssrf_protection | default dict -}}
{{- if or (hasKey $walletSsrf "enabled") (hasKey $walletSsrf "allowed_private") -}}
{{- fail "organisationWallet.advanced.extraConfig.ssrf_protection: set outboundHttp.ssrfProtection.enabled and outboundHttp.allowedPrivate instead" -}}
{{- end -}}
{{- $allowed := $o.allowedPrivate | default list -}}
{{- range $entry := $allowed -}}
{{- $text := lower (toString $entry) -}}
{{- if or (hasPrefix "127." $text) (hasPrefix "169.254." $text) (hasPrefix "0." $text) (eq $text "localhost") (hasPrefix "::1" $text) (hasPrefix "fe80:" $text) (eq $text "::") -}}
{{- fail (printf "outboundHttp.allowedPrivate: %q covers a loopback, link-local, metadata or unspecified address, which the wallet never allows; give the private host names or the networks of your public hosts" $entry) -}}
{{- end -}}
{{- end -}}
{{- toJson (dict "off" (eq (toString (dig "ssrfProtection" "enabled" true $o)) "false") "allowedPrivate" $allowed) -}}
{{- end }}

{{/*
Reads one key of an existing Secret in the release namespace (lookup).
Returns "" when the Secret or the key is missing, and always under
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
A secret value: the value from values.yaml if set, else the value already in
the Secret from an earlier release, else a new random value. Call with
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

{{/* "true" when the chart runs NATS (nats.mode bundled), else "". */}}
{{- define "ow.nats.bundled" -}}
{{- $mode := .Values.nats.mode | default "bundled" -}}
{{- if not (has $mode (list "bundled" "external")) -}}
{{- fail (printf "nats.mode %q is not supported: use \"bundled\" or \"external\"" $mode) -}}
{{- end -}}
{{- if eq $mode "bundled" -}}true{{- end -}}
{{- end }}

{{/* TLS Secret of the bundled NATS (tls.crt, tls.key, ca.crt). */}}
{{- define "ow.nats.tlsSecretName" -}}
{{- .Values.nats.tls.existingSecret | default (include "ow.name" (list . "nats-tls")) -}}
{{- end }}

{{/*
The NATS CA that the services trust: ca.crt from the TLS Secret of the
bundled NATS (which always runs TLS), or nats.external.ca for an external
NATS with TLS. Output: JSON {secret, key}, or {} when there is no CA.
*/}}
{{- define "ow.nats.ca" -}}
{{- $ca := .Values.nats.external.ca -}}
{{- if include "ow.nats.bundled" . -}}
{{- if $ca.existingSecret -}}
{{- fail "nats.external.ca is the CA of an external NATS (nats.mode external): the bundled NATS has its own TLS (nats.tls)" -}}
{{- end -}}
{{- toJson (dict "secret" (include "ow.nats.tlsSecretName" .) "key" "ca.crt") -}}
{{- else if $ca.existingSecret -}}
{{- toJson (dict "secret" $ca.existingSecret "key" ($ca.key | default "ca.crt")) -}}
{{- else -}}
{{- toJson dict -}}
{{- end -}}
{{- end }}

{{/* The NATS URL that the services connect to. */}}
{{- define "ow.nats.url" -}}
{{- if include "ow.nats.bundled" . -}}
nats://{{ include "ow.name" (list . "nats") }}.{{ .Release.Namespace }}.svc:4222
{{- else -}}
{{ required "nats.external.url is required with nats.mode external" .Values.nats.external.url }}
{{- end -}}
{{- end }}

{{/*
Name of one key Secret: keys.<item>.existingSecret, else
"<fullname>-<default>" (the Secret of scripts/make-keys.sh). Call with
(list $ "<item>" "<default>").
*/}}
{{- define "ow.keys.secretName" -}}
{{- $root := index . 0 -}}
{{- (index $root.Values.keys (index . 1)).existingSecret | default (include "ow.name" (list $root (index . 2))) -}}
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
Keys that the chart writes to the Secret "<fullname>-api": the HMAC key of
the api (keys.apiHmacKey), random and kept, when no existing Secret holds
it. The values file has no secret. Output: JSON list.
*/}}
{{- define "ow.api.chartSecretKeys" -}}
{{- $keys := list -}}
{{- if not .Values.keys.apiHmacKey.existingSecret -}}{{- $keys = append $keys .Values.keys.apiHmacKey.key -}}{{- end -}}
{{- toJson $keys -}}
{{- end }}

{{/*
Secret files of the api, the webhook handler and the operator Jobs, mounted
as one projected volume in a read-only folder (ow.api.secretDir). The config
file points to them with its <Name>File keys.
Output: JSON object "<file name>" -> {secret, key}.
*/}}
{{- define "ow.api.secretFiles" -}}
{{- $root := . -}}
{{- $api := .Values.api -}}
{{- $k := .Values.keys -}}
{{- $chartSecret := include "ow.name" (list $root "api") -}}
{{- $files := merge
  (include "ow.db.secretFiles" (list $root "api" "db-password") | fromJson)
  (include "ow.db.secretFiles" (list $root "oidc" "oidc-db-password") | fromJson) -}}
{{- $files = merge $files (dict
  "api-secret-key" (dict "secret" ($k.apiHmacKey.existingSecret | default $chartSecret) "key" $k.apiHmacKey.key)
  "token-hash-secret.json" (dict "secret" (include "ow.keys.secretName" (list $root "apiTokenHash" "api-token-hash")) "key" $k.apiTokenHash.key)
  "token-signing-jwks.json" (dict "secret" (include "ow.keys.secretName" (list $root "apiTokenSigning" "api-token-signing")) "key" $k.apiTokenSigning.key)
  "db-wrapping-keys.json" (dict "secret" (include "ow.keys.secretName" (list $root "apiDatabaseWrapping" "api-db-wrapping")) "key" $k.apiDatabaseWrapping.key)) -}}
{{- $reader := include "ow.readAccess.reader" (list $root "api" "wallet") | fromJson -}}
{{- $_ := set $files "read-access-wallet-password" (dict "secret" $reader.secret "key" $reader.key) -}}
{{- $signing := include "ow.serviceKeys.signing" (list $root "api") | fromJson -}}
{{- $_ := set $files "service-envelope-jwks.json" (dict "secret" $signing.secret "key" $signing.key) -}}
{{- with include "ow.nats.ca" $root | fromJson -}}
{{- $_ := set $files "nats-ca.crt" . -}}
{{- end -}}
{{- with $api.smtp.password.existingSecret -}}
{{- if $api.smtp.host -}}
{{- $_ := set $files "smtp-password" (dict "secret" . "key" $api.smtp.password.key) -}}
{{- end -}}
{{- end -}}
{{- $twilio := $api.twilio -}}
{{- if ne (empty $twilio.accountSid.existingSecret) (empty $twilio.authToken.existingSecret) -}}
{{- fail "api.twilio.accountSid.existingSecret and api.twilio.authToken.existingSecret go together: set both (SMS with Twilio) or none" -}}
{{- end -}}
{{- if $twilio.accountSid.existingSecret -}}
{{- $_ := set $files "twilio-account-sid" (dict "secret" $twilio.accountSid.existingSecret "key" $twilio.accountSid.key) -}}
{{- $_ := set $files "twilio-auth-token" (dict "secret" $twilio.authToken.existingSecret "key" $twilio.authToken.key) -}}
{{- end -}}
{{- toJson $files -}}
{{- end }}

{{/*
Path of one api secret file, or "" when the chart does not mount it.
Call with (list $ "<file name>").
*/}}
{{- define "ow.api.secretFile" -}}
{{- $files := include "ow.api.secretFiles" (index . 0) | fromJson -}}
{{- if hasKey $files (index . 1) -}}
{{ include "ow.api.secretDir" (index . 0) }}/{{ index . 1 }}
{{- end -}}
{{- end }}

{{/*
Volume mounts of the api pods: the config, the secret files and the public
service keys. Output: a list at column 0.
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
Volumes of the api pods: the config of one role ("api" or "webhook"; the
operator Jobs use "api") and the secret files (mode 0440). Call with
(list $ "<role>"). Output: a list at column 0.
*/}}
{{- define "ow.api.volumes" -}}
{{- $root := index . 0 -}}
{{- include "ow.gateway.checkGatewayJwks" $root }}
# The config file and the gateway public keys (GatewayToken).
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
            - key: gateway-jwks.json
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
      {{- /* The nkey seed of the role's NATS user (api, or api-webhook for
      the webhook handler). */}}
      {{- $client := include "ow.nats.client" (list $root (include "ow.api.natsUser" (index . 1))) | fromJson }}
      {{- with $client.seed }}
      - secret:
          name: {{ .secret }}
          items:
            - key: {{ .key }}
              path: nats-seed
      {{- end }}
{{ include "ow.serviceKeys.volume" (prepend (include "ow.api.trustedIssuers" $root | fromJsonArray) $root) }}
{{- end }}

{{/*
Issuers of signed NATS envelopes that the api trusts: itself (internal
events) and the wallet. Output: JSON list.
*/}}
{{- define "ow.api.trustedIssuers" -}}
{{- toJson (list "igrant-api" "eudi-wallet") -}}
{{- end }}

{{/* NATS user (values key) of an api role: api or webhook. */}}
{{- define "ow.api.natsUser" -}}
{{- get (dict "api" "api" "webhook" "webhook") . -}}
{{- end }}

{{/* NATS user (values key) of a wallet role; "" for the clock, which does not use NATS. */}}
{{- define "ow.wallet.natsUser" -}}
{{- $users := dict "config" "walletConfig" "service" "walletService" "worker" "walletWorker" -}}
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
The wallet's database login roles, comma-separated, without the prefix (see
ow.wallet.databaseUser). The roles hook ("database-roles apply") creates
them with the passwords from the role Secret
(ow.wallet.databaseRolesSecretName), one key per name: the migrator, the
launcher, the jobs role, the clock, the audit reader and one role per role
application. "database-roles apply" stops when a login role has no
password file.
*/}}
{{- define "ow.wallet.databaseLogins" -}}
migrator,launcher_app,jobs,clock,audit_reader,issuer_app,relying_party_app,business_wallet_app,individual_wp_app,business_wp_app,admin_app
{{- end }}

{{/* Name of the Secret with the passwords of the wallet database roles (ow.wallet.databaseLogins). */}}
{{- define "ow.wallet.databaseRolesSecretName" -}}
{{ include "ow.name" (list . "wallet-database-roles") }}
{{- end }}

{{/*
The database role that a wallet role connects as (docs/database.md): the
service and config roles use the launcher role, the workers the jobs role,
and the clock the clock role (CONNECT only, for its leader lock and
pg_is_in_recovery()). Output: the name without the prefix, which is also
the key of its password in the role Secret.
*/}}
{{- define "ow.wallet.databaseRole" -}}
{{- $roles := dict "service" "launcher_app" "config" "launcher_app" "worker" "jobs" "clock" "clock" -}}
{{- get $roles . -}}
{{- end }}

{{/*
User name of a wallet database role: <prefix>_<role>. The prefix is the
wallet database name (the default prefix of "database-roles" and of the
wallet setting database.role_prefix). A role name has at most 63 characters
and the longest is <prefix>_business_wallet_app, so the database name can
have at most 43. Call with (list $ "<role without the prefix>").
*/}}
{{- define "ow.wallet.databaseUser" -}}
{{- $root := index . 0 -}}
{{- $prefix := $root.Values.database.databases.wallet.name -}}
{{- if gt (len $prefix) 43 -}}
{{- fail (printf "database.databases.wallet.name %q has %d characters: it is the prefix of the database roles of the wallet (for example %s_business_wallet_app), and a role name has at most 63, so the name can have at most 43" $prefix (len $prefix) $prefix) -}}
{{- end -}}
{{- printf "%s_%s" $prefix (index . 1) -}}
{{- end }}

{{/*
Database files of one wallet login in ow.wallet.secretDir: its password and
the server CA. Call with (list $ "<password file name>" {secret, key}).
Output: JSON "<file name>" -> {secret, key}.
*/}}
{{- define "ow.wallet.databaseFiles" -}}
{{- $root := index . 0 -}}
{{- $files := dict (index . 1) (index . 2) -}}
{{- $ca := include "ow.db.ca" $root | fromJson -}}
{{- if $ca.secret -}}
{{- $_ := set $files (include "ow.db.caFileName" $root) $ca -}}
{{- end -}}
{{- toJson $files -}}
{{- end }}

{{/*
Secret files of one wallet role ("service", "config", "worker" or "clock"),
mounted as one projected volume in a read-only folder (ow.wallet.secretDir).
Call with (list $ "<role>"). Output: JSON object "<file name>" -> {secret, key}.
*/}}
{{- define "ow.wallet.secretFiles" -}}
{{- $root := index . 0 -}}
{{- $role := index . 1 -}}
{{- $w := $root.Values.organisationWallet -}}
{{- /* The password of the role's own database role, never the one of the
database owner. */ -}}
{{- $password := dict "secret" (include "ow.wallet.databaseRolesSecretName" $root) "key" (include "ow.wallet.databaseRole" $role) -}}
{{- $files := include "ow.wallet.databaseFiles" (list $root "database-password" $password) | fromJson -}}
{{- /* All wallet processes except the clock connect to NATS with the nkey
user of their role. */ -}}
{{- if ne $role "clock" -}}
{{- $client := include "ow.nats.client" (list $root (include "ow.wallet.natsUser" $role)) | fromJson -}}
{{- if $client.seed -}}
{{- $_ := set $files "nats-seed" $client.seed -}}
{{- end -}}
{{- with include "ow.nats.ca" $root | fromJson -}}
{{- $_ := set $files "nats-ca.crt" . -}}
{{- end -}}
{{- end -}}
{{- /* The role's Valkey user (redis): its password and the server CA (also
for the separate groups). */ -}}
{{- $files = merge $files (include "ow.redis.secretFiles" (list $root (include "ow.wallet.redisUser" $role)) | fromJson) -}}
{{- /* The CA of each separate group (redis.state, redis.cache). */ -}}
{{- range $name, $group := include "ow.redis.groups" $root | fromJson -}}
{{- if and (ne $name "queue") $group.caFile -}}
{{- $_ := set $files $group.caFile $group.ca -}}
{{- end -}}
{{- end -}}
{{- /* The clock needs nothing more: it makes no OpenBao calls and signs no
NATS events (it only sends the cron actor messages). */ -}}
{{- if ne $role "clock" -}}
{{- /* The wallet KMS login to OpenBao (password) and the OpenBao CA. */ -}}
{{- $_ := set $files "openbao-password" (include "ow.openbao.walletSecret" $root | fromJson) -}}
{{- with include "ow.openbao.ca" $root | fromJson -}}
{{- if .secret -}}{{- $_ := set $files "openbao-ca.crt" . -}}{{- end -}}
{{- end -}}
{{- /* Play Integrity keys: the service pods check the WIA requests of
wallet units with them, and the service and config pods make the first
Android wallet app record from them (ow.wallet.config). */ -}}
{{- $p := $w.walletUnit.playIntegrity -}}
{{- if and $p.existingSecret (has $role (list "service" "config")) -}}
{{- $_ := set $files "play-integrity-decryption-key" (dict "secret" $p.existingSecret "key" $p.decryptionKeyKey) -}}
{{- $_ := set $files "play-integrity-verification-key" (dict "secret" $p.existingSecret "key" $p.verificationKeyKey) -}}
{{- end -}}
{{- /* The workers write audit anchor copies and monthly exports to the audit
bucket (actors audit.anchor and audit.export), with the wallet's access key
(type s3) or its service account (type gcs). */ -}}
{{- $b := $w.audit.bucket -}}
{{- if and (eq $role "worker") $b.name -}}
{{- include "ow.wallet.checkAudit" $root -}}
{{- if eq $b.type "s3" -}}
{{- $_ := set $files "audit-bucket-access-key-id" (dict "secret" $b.accessKeyId.existingSecret "key" $b.accessKeyId.key) -}}
{{- $_ := set $files "audit-bucket-secret-access-key" (dict "secret" $b.secretAccessKey.existingSecret "key" $b.secretAccessKey.key) -}}
{{- with $b.ca.existingSecret -}}
{{- $_ := set $files "audit-bucket-ca.crt" (dict "secret" . "key" $b.ca.key) -}}
{{- end -}}
{{- else if $b.credentials.existingSecret -}}
{{- $_ := set $files "audit-bucket-service-account.json" (dict "secret" $b.credentials.existingSecret "key" $b.credentials.key) -}}
{{- end -}}
{{- end -}}
{{- /* The config role reads the api database views with the wallet's
read-only user (read_access). */ -}}
{{- if eq $role "config" -}}
{{- $reader := include "ow.readAccess.reader" (list $root "wallet" "api") | fromJson -}}
{{- $_ := set $files "read-access-api-password" (dict "secret" $reader.secret "key" $reader.key) -}}
{{- end -}}
{{- /* Every wallet process signs its NATS events with the wallet's private
JWKS. */ -}}
{{- $signing := include "ow.serviceKeys.signing" (list $root "organisationWallet") | fromJson -}}
{{- $_ := set $files "service-envelope-jwks.json" (dict "secret" $signing.secret "key" $signing.key) -}}
{{- end -}}
{{- toJson $files -}}
{{- end }}

{{/*
Volumes of one wallet role: the config (ConfigMap key <role>.yaml, or the
given key, mounted as config.yaml) and the secret files (mode 0440).
Call with (list $ "<role>") or (list $ "<role>" "<ConfigMap key>").
Output: a list at column 0.
*/}}
{{- define "ow.wallet.volumes" -}}
{{- $root := index . 0 -}}
{{- $role := index . 1 -}}
{{- $key := printf "%s.yaml" $role -}}
{{- if gt (len .) 2 -}}{{- $key = index . 2 -}}{{- end -}}
- name: config
  configMap:
    name: {{ include "ow.name" (list $root "wallet") }}
    items:
      - key: {{ $key }}
        path: {{ include "ow.wallet.configPath" $root | base }}
- name: secrets
  projected:
    defaultMode: 0440
    sources:
      {{- range $path, $file := include "ow.wallet.secretFiles" (list $root $role) | fromJson }}
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

{{/* Folder with the device roots for wallet units (wallet_unit.trust_anchors_dir). */}}
{{- define "ow.wallet.trustAnchorsDir" -}}
/etc/eudi-wallet-trust-anchors
{{- end }}

{{/*
"true" when the pods of a wallet role mount the device roots from
organisationWallet.walletUnit.trustAnchors.existingConfigMap. Only the
service, config and worker roles check device evidence; the clock has no
wallet_unit settings. Call with (list $ "<role>").
*/}}
{{- define "ow.wallet.trustAnchors" -}}
{{- $root := index . 0 -}}
{{- if and $root.Values.organisationWallet.walletUnit.trustAnchors.existingConfigMap (has (index . 1) (list "service" "config" "worker")) -}}
true
{{- end -}}
{{- end }}

{{/*
Device roots volume of a wallet role: the two root files from the ConfigMap
(the pod does not start when a key is missing). Call with (list $ "<role>").
Output: a list at column 0, or nothing.
*/}}
{{- define "ow.wallet.trustAnchorsVolume" -}}
{{- $root := index . 0 -}}
{{- if include "ow.wallet.trustAnchors" . -}}
- name: trust-anchors
  configMap:
    name: {{ $root.Values.organisationWallet.walletUnit.trustAnchors.existingConfigMap }}
    items:
      - key: google_hardware_attestation_root.pem
        path: google_hardware_attestation_root.pem
      - key: apple_app_attestation_root_ca.pem
        path: apple_app_attestation_root_ca.pem
{{- end -}}
{{- end }}

{{/* Device roots mount of a wallet role. Call with (list $ "<role>"). Output: a list at column 0, or nothing. */}}
{{- define "ow.wallet.trustAnchorsMount" -}}
{{- if include "ow.wallet.trustAnchors" . -}}
- name: trust-anchors
  mountPath: {{ include "ow.wallet.trustAnchorsDir" (index . 0) }}
  readOnly: true
{{- end -}}
{{- end }}

{{/* Folder of the gateway secret files (one projected volume). */}}
{{- define "ow.gateway.secretDir" -}}
/run/secrets/igrant-gateway
{{- end }}

{{/* The port of the gateway process: a constant of the chart (1024 or more, the gateway runs as non-root). */}}
{{- define "ow.gateway.listenPort" -}}
8070
{{- end }}

{{/* Path of the gateway configuration file (--config). */}}
{{- define "ow.gateway.configPath" -}}
/etc/igrant-gateway/config.yaml
{{- end }}

{{/*
Name of the shared ConfigMap with the gateway public keys
(gateway-jwks.json). The api core and the wallet config role check the
internal token with them. keys.publicJwks.existingConfigMap, else the
chart's ConfigMap <fullname>-igrant-gateway-jwks (same name for all
services).
*/}}
{{- define "ow.gateway.publicKeysConfigMap" -}}
{{- .Values.keys.publicJwks.existingConfigMap | default (include "ow.name" (list . "igrant-gateway-jwks")) -}}
{{- end }}

{{/*
Name of the ConfigMap with the public keys for api tokens
(token-verification-jwks.json; only the gateway reads it):
keys.publicJwks.existingConfigMap, else the chart's gateway ConfigMap (next
to config.yaml).
*/}}
{{- define "ow.gateway.tokenVerificationConfigMap" -}}
{{- .Values.keys.publicJwks.existingConfigMap | default (include "ow.name" (list . "gateway")) -}}
{{- end }}

{{/*
The internal token of the gateway: constants of the protocol, the same in
the gateway, the api core and the wallet config role. issuer: its iss.
audiences: its aud for each upstream. Output: JSON.
*/}}
{{- define "ow.gateway.internalToken" -}}
{{- toJson (dict "issuer" "igrant-gateway" "audiences" (dict "core" "igrant-api-core" "walletConfig" "wallet-config")) -}}
{{- end }}

{{/*
Secret files of the gateway, mounted as one projected volume in a read-only
folder (ow.gateway.secretDir): the API secret key, the api database password
and CA, and the token hash secret (the same Secrets as the api); the private
JWKS of the internal token (its own Secret); and the password of its Valkey
user with the server CA (redis-password, redis-ca.crt). The gateway never
gets the api token signing key.
Output: JSON object "<file name>" -> {secret, key}.
*/}}
{{- define "ow.gateway.secretFiles" -}}
{{- $api := include "ow.api.secretFiles" . | fromJson -}}
{{- $signing := .Values.keys.gatewayInternalToken -}}
{{- $files := include "ow.db.secretFiles" (list . "api" "db-password") | fromJson -}}
{{- $files = merge $files (dict
  "api-secret-key" (get $api "api-secret-key")
  "token-hash-secret.json" (get $api "token-hash-secret.json")
  "internal-token-jwks.json" (dict "secret" ($signing.existingSecret | default (include "ow.name" (list . "gateway-internal-token"))) "key" $signing.key)) -}}
{{- $files = merge $files (include "ow.redis.secretFiles" (list . "gateway") | fromJson) -}}
{{- toJson $files -}}
{{- end }}

{{/* Folder of the public keys of the gateway in the wallet config pods. */}}
{{- define "ow.gateway.keysDir" -}}
/etc/igrant-gateway-keys
{{- end }}

{{/*
Volume with the gateway public keys for a service pod (gateway-jwks.json in
ow.gateway.keysDir). Output: a list at column 0.
*/}}
{{- define "ow.gateway.keysVolume" -}}
- name: gateway-keys
  configMap:
    name: {{ include "ow.gateway.publicKeysConfigMap" . }}
    items:
      - key: gateway-jwks.json
        path: gateway-jwks.json
{{- end }}

{{/*
Fails when the gateway public keys (gateway-jwks.json) are missing: the api
core and the wallet config role verify the internal token of every request
with them. Output: nothing.
*/}}
{{- define "ow.gateway.checkGatewayJwks" -}}
{{- $keys := .Values.keys.publicJwks -}}
{{- if and (not $keys.existingConfigMap) (not $keys.gatewayInternalToken) -}}
{{- fail "keys.publicJwks.gatewayInternalToken (or keys.publicJwks.existingConfigMap) is required: the public keys of the gateway, which the api core and the wallet use to verify the internal token (scripts/make-keys.sh; see docs/keys.md)" -}}
{{- end -}}
{{- end }}

{{/*
JetStream rights of one NATS user, limited to the JetStream API subjects
that its process uses:
- the streams it ensures: STREAM.INFO, CREATE and UPDATE;
- its own durables: CONSUMER.INFO, CREATE (all three forms) and DELETE,
  MSG.NEXT for a pull consumer, and the acks $JS.ACK.<stream>.<durable>.>;
- its KV buckets: the KV stream, direct get and puts.
No STREAM.DELETE, STREAM.PURGE or other API subject, so a service cannot
delete or purge the stream or the consumers of another service. Call with
the user's values key. Output: JSON list.
*/}}
{{- define "ow.nats.jetStreamRights" -}}
{{- $spec := dig . dict (dict
  "api" (dict
    "streams" (list "OWS_MICROSERVICE" "API_EVENTS")
    "durables" (list "OWS_MICROSERVICE/openidprovider-client-created" "OWS_MICROSERVICE/openidprovider-client-deleted" "OWS_MICROSERVICE/openidprovider-clients-deleted")
    "kv" (list "OWS_ENVELOPE_JTI")
    "extra" (list "$JS.API.INFO"))
  "webhook" (dict
    "streams" (list "OWS_MICROSERVICE" "API_EVENTS")
    "durables" (list "OWS_MICROSERVICE/api-webhook-event" "OWS_MICROSERVICE/api-push-requested"))
  "walletConfig" (dict
    "streams" (list "OWS_MICROSERVICE")
    "pull" (list "API_EVENTS/eudi-wallet-api-triggers")
    "kv" (list "wallet-command-replay" "wallet-command-replies"))
  "walletService" (dict
    "streams" (list "OWS_MICROSERVICE"))
  "walletWorker" (dict
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
account, limited to the subjects of that process. Each item has: name,
values key, nkey, seed {secret, key}, inbox prefix, publish, subscribe and
allowResponses.

Publish:
- The services publish events and requests by name (the stream and subject
  contract of the services). The api events are the subjects of the stream
  API_EVENTS, including api.v1.evt.organisation.deleted.
- The api core sends wallet commands on ows.cmd.> (this includes
  ows.cmd.*.organisation.set_suspended).
- The webhook handler sends one wallet command, ows.cmd.*.issuance.revoke,
  to revoke an admin's Authenticator credential when the admin gets a new
  one.
- The wallet roles publish their outbox events (from the outbox edge of the
  servers, the outbox relay and the worker actors): record events,
  notifications, the push trigger, and the webhook events of the issuer,
  the verifier and the holder.

Subscribe: the JetStream consumers of a process (pull, or push with a
deliver subject under its inbox prefix) deliver to its inbox. So a process
subscribes only to its inbox, to the requests it serves (api.v1.rpc.>,
ows.cmd.*.>) and to the events of its core subscriptions (start-api: the
passwordless status waits).

Cache clears: the wallet service and config pods send and receive the
clears of their process caches on ows.cache.cleared (core NATS, so every pod
gets every clear). A pod that cannot subscribe to it is not ready. The
workers send no clears.

The WIA pool refill is a worker actor, not a NATS event. The clock does not
use NATS. The JetStream API rights are the exact subjects of each process
(ow.nats.jetStreamRights): the services ensure their streams, durables and
KV buckets at start, and no service can delete or purge the stream or the
consumers of another. Output: JSON list.
*/}}
{{- define "ow.nats.users" -}}
{{- $v := .Values -}}
{{- $users := $v.nats.users -}}
{{- $walletEvents := list "ows.*.webhook.*" "ows.*.notification" "ows.*.evt.push_requested" "ows.*.evt.webhook_event" -}}
{{- $cacheClears := list "ows.cache.cleared" -}}
{{- $table := list
  (dict "name" "api" "key" "api" "inbox" "_INBOX_api" "allowResponses" true
    "publish" (concat (list "ows.cmd.>")
      (list "api.v1.evt.organisation.created" "api.v1.evt.organisation.updated" "api.v1.evt.organisation.deleted" "api.v1.evt.sandbox.updated" "api.v1.evt.sandbox.deleted" "api.v1.evt.extension.updated")
      (list "ows.openidprovider.client.created" "ows.openidprovider.client.deleted" "ows.openidprovider.clients.deleted")
      (include "ow.nats.jetStreamRights" "api" | fromJsonArray))
    "subscribe" (list "api.v1.rpc.>" "ows.users.*.authentication.oidcpasswordless.verified" "ows.users.*.authentication.oidcpasswordless.accepted"))
  (dict "name" "api-webhook" "key" "webhook" "inbox" "_INBOX_apiwh" "allowResponses" false
    "publish" (concat (list "ows.users.*.authentication.oidcpasswordless.verified" "ows.users.*.authentication.oidcpasswordless.accepted" "ows.cmd.*.issuance.revoke") (include "ow.nats.jetStreamRights" "webhook" | fromJsonArray))
    "subscribe" (list))
  (dict "name" "wallet-config" "key" "walletConfig" "inbox" "_INBOX_wallet" "allowResponses" true
    "publish" (concat $walletEvents $cacheClears (include "ow.nats.jetStreamRights" "walletConfig" | fromJsonArray))
    "subscribe" (concat (list "ows.cmd.*.>" "ows.*.notification" "ows.*.webhook.present_proof") $cacheClears))
  (dict "name" "wallet-service" "key" "walletService" "inbox" "_INBOX_wallet" "allowResponses" false
    "publish" (concat $walletEvents $cacheClears (include "ow.nats.jetStreamRights" "walletService" | fromJsonArray))
    "subscribe" $cacheClears)
  (dict "name" "wallet-worker" "key" "walletWorker" "inbox" "_INBOX_wallet" "allowResponses" false
    "publish" (concat $walletEvents (include "ow.nats.jetStreamRights" "walletWorker" | fromJsonArray))
    "subscribe" (list)) -}}
{{- $out := list -}}
{{- range $user := $table -}}
{{- $values := index $users $user.key | default dict -}}
{{- $seed := dict -}}
{{- with ($values.seed | default dict).existingSecret -}}{{- $seed = dict "secret" . "key" ($values.seed.key | default "seed") -}}{{- end -}}
{{- $out = append $out (dict
    "name" $user.name "key" $user.key "nkey" ($values.nkey | default "") "seed" $seed "inbox" $user.inbox
    "allowResponses" $user.allowResponses
    "publish" $user.publish
    "subscribe" (concat $user.subscribe (list (printf "%s.>" $user.inbox)))) -}}
{{- end -}}
{{- toJson $out -}}
{{- end }}

{{/*
Checks the NATS users. Every process in the chart connects with its own nkey
user, so each needs a public nkey and a seed Secret; the server has no user
without credentials. Output: nothing.
*/}}
{{- define "ow.nats.checkUsers" -}}
{{- $missing := list -}}
{{- range $user := include "ow.nats.users" . | fromJsonArray -}}
{{- if and $user.nkey (not (hasPrefix "U" $user.nkey)) -}}
{{- fail (printf "nats.users.%s.nkey must be a public user nkey (it starts with U), never the seed" $user.key) -}}
{{- end -}}
{{- if or (not $user.nkey) (not $user.seed) -}}
{{- $missing = append $missing (printf "nats.users.%s (%s)" $user.key $user.name) -}}
{{- end -}}
{{- end -}}
{{- if $missing -}}
{{- fail (printf "every process connects to NATS with its own nkey user: set nkey and seed.existingSecret for %s (make a pair with \"nsc generate nkey --user\"; see docs/nats-users.md)" (join ", " $missing)) -}}
{{- end -}}
{{- end }}

{{/*
The authorization block of nats.conf: the users of the chart's processes,
each with its credentials. Output: text at column 0.
*/}}
{{- define "ow.nats.authorization" -}}
{{- include "ow.nats.checkUsers" . -}}
authorization {
  users = [
    {{- range $user := include "ow.nats.users" . | fromJsonArray }}
    # {{ $user.name }}
    {{- /* In nats.conf an empty allow list means no restriction, so a process
    with no publish subjects gets deny [">"]. */}}
    { nkey: {{ $user.nkey | quote }}, permissions: { publish: { {{ if $user.publish }}allow: {{ include "ow.nats.list" $user.publish }}{{ else }}deny: [">"]{{ end }} }, subscribe: { allow: {{ include "ow.nats.list" $user.subscribe }} }{{ if $user.allowResponses }}, allow_responses: true{{ end }} } }
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
services create (file storage): nats.jetstreamReplicas, else nats.replicas
when the chart runs NATS, else 1. For an external NATS, set it to the
cluster size. A production cluster uses 3.
*/}}
{{- define "ow.nats.jetstreamReplicas" -}}
{{- .Values.nats.jetstreamReplicas | default (ternary .Values.nats.replicas 1 (eq (include "ow.nats.bundled" .) "true")) | int -}}
{{- end }}

{{/* Folder of the public service keys (ConfigMap igrant-service-jwks) in the service pods. */}}
{{- define "ow.serviceKeys.dir" -}}
/etc/igrant-service-keys
{{- end }}

{{/*
Name of the shared ConfigMap with the public JWKS of the services
(<issuer>.json): keys.publicJwks.existingConfigMap, else the chart's
ConfigMap <fullname>-igrant-service-jwks (same name for all services).
*/}}
{{- define "ow.serviceKeys.configMap" -}}
{{- .Values.keys.publicJwks.existingConfigMap | default (include "ow.name" (list . "igrant-service-jwks")) -}}
{{- end }}

{{/*
The issuer name of the signed NATS envelopes of each component
(keys.serviceEnvelope.<component>): a constant of the services. Output:
JSON component -> issuer.
*/}}
{{- define "ow.serviceKeys.issuers" -}}
{{- toJson (dict "api" "igrant-api" "organisationWallet" "eudi-wallet") -}}
{{- end }}

{{/*
The issuers of signed NATS envelopes that one service trusts. Fails when the
public JWKS of an issuer is missing (keys.serviceEnvelope.<component>.publicJwks,
or keys.publicJwks.existingConfigMap). Call with (list $ "<issuer>" ...).
Output: JSON list of {issuer, jwksFile}.
*/}}
{{- define "ow.serviceKeys.trusted" -}}
{{- $root := index . 0 -}}
{{- $out := list -}}
{{- $components := dict -}}
{{- range $component, $issuer := include "ow.serviceKeys.issuers" $root | fromJson -}}
{{- $_ := set $components $issuer $component -}}
{{- end -}}
{{- range $issuer := rest . -}}
{{- $component := get $components $issuer -}}
{{- if and (not $root.Values.keys.publicJwks.existingConfigMap) (not (index $root.Values.keys.serviceEnvelope $component).publicJwks) -}}
{{- fail (printf "keys.serviceEnvelope.%s.publicJwks (or keys.publicJwks.existingConfigMap) is required: the public keys of the signed NATS messages of %s (scripts/make-keys.sh; see docs/keys.md)" $component $issuer) -}}
{{- end -}}
{{- $out = append $out (dict "issuer" $issuer "jwksFile" (printf "%s/%s.json" (include "ow.serviceKeys.dir" $root) $issuer)) -}}
{{- end -}}
{{- toJson $out -}}
{{- end }}

{{/*
Volume with the public keys of the issuers that one service trusts.
Call with (list $ "<issuer>" ...). Output: a list at column 0.
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
The private JWKS Secret that one service signs its NATS envelopes with
(keys.serviceEnvelope.<component>). Fails when the active kid is not set.
Call with (list $ "api"|"organisationWallet"). Output: JSON {secret, key,
activeKid}.
*/}}
{{- define "ow.serviceKeys.signing" -}}
{{- $root := index . 0 -}}
{{- $component := index . 1 -}}
{{- $envelope := index $root.Values.keys.serviceEnvelope $component -}}
{{- $kid := required (printf "keys.serviceEnvelope.%s.activeKid is required: the kid of the active key in the private JWKS of the signed NATS messages (scripts/make-keys.sh; see docs/keys.md)" $component) $envelope.activeKid -}}
{{- toJson (dict
  "secret" ($envelope.existingSecret | default (include "ow.name" (list $root (get (dict "api" "api-service-key" "organisationWallet" "wallet-service-key") $component))))
  "key" $envelope.key
  "activeKid" ($kid | toString)) -}}
{{- end }}

{{/*
Lifetime and clock skew of the signed NATS envelopes, in seconds: constants
of the protocol, the same in every service. Output: JSON.
*/}}
{{- define "ow.serviceKeys.timing" -}}
{{- toJson (dict "lifetimeSeconds" 60 "clockSkewSeconds" 60) -}}
{{- end }}

{{/*
NATS client settings of one process: the seed Secret of its user and its
inbox prefix. Call with (list $ "<user values key>"). Output: JSON
{seed: {secret, key}, inbox}.
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
The read-only database user of one reader on one owner database. Fails when
it is not set. Call with (list $ "<reader>" "<owner>"); reader and owner are
keys of database.databases. Output: JSON {host, port, name, username,
secret, key}. An empty host, port or name defaults to the owner database in
this chart. The engine and TLS settings always come from database.*
(ow.db.go, ow.db.wallet).
*/}}
{{- define "ow.readAccess.reader" -}}
{{- $root := index . 0 -}}
{{- $reader := index . 1 -}}
{{- $owner := index . 2 -}}
{{- include "ow.readAccess.checkNames" $root -}}
{{- $entry := index (index $root.Values.database.readAccess $reader | default dict) $owner | default dict -}}
{{- $key := printf "database.readAccess.%s.%s" $reader $owner -}}
{{- if not $entry.username -}}
{{- fail (printf "%s.username is required: %s reads the views of the %s database with its own read-only user (see docs/read-access.md)" $key $reader $owner) -}}
{{- end -}}
{{- /* Only names that the read-access command of every owner accepts (the
wallet allows ^[a-z][a-z0-9_]{0,62}$; the api allows more). */ -}}
{{- if not (regexMatch "^[a-z][a-z0-9_]{0,62}$" $entry.username) -}}
{{- fail (printf "%s.username %q is not a database user name: a lower-case letter, then lower-case letters, digits or _ (at most 63)" $key $entry.username) -}}
{{- end -}}
{{- $password := $entry.password | default dict -}}
{{- toJson (dict
  "host" ($entry.host | default (include "ow.db.host" $root))
  "port" ($entry.port | default (include "ow.db.port" $root) | int)
  "name" ($entry.name | default (index $root.Values.database.databases $owner).name)
  "username" $entry.username
  "secret" ($password.existingSecret | default (include "ow.readAccess.secretName" $root))
  "key" (ternary ($password.key | default "password") (printf "%s-%s" $reader $owner) (not (empty $password.existingSecret)))) -}}
{{- end }}

{{/* Name of the chart's Secret with the read-only user passwords (key <reader>-<owner>). */}}
{{- define "ow.readAccess.secretName" -}}
{{ include "ow.name" (list . "read-access") }}
{{- end }}

{{/*
Admin user of the read access Job for one owner database
(database.readAccess.jobs.<owner>; "read-access apply --admin-user
--admin-password-file"). It creates the read-only users and grants SELECT
on the views. Empty values fall back to the admin of the server
(ow.db.admin: the "postgres" user of the bundled server, or
database.admin). Call with (list $ "<owner>"). Output: JSON {user, secret,
key}.
*/}}
{{- define "ow.readAccess.admin" -}}
{{- $root := index . 0 -}}
{{- $owner := index . 1 -}}
{{- $access := index $root.Values.database.readAccess.jobs $owner -}}
{{- $admin := include "ow.db.admin" $root | fromJson -}}
{{- $user := $access.adminUser | default $admin.user -}}
{{- $secret := $access.adminPasswordSecret -}}
{{- $key := $access.adminPasswordKey -}}
{{- if not $secret -}}
{{- $secret = $admin.secret -}}
{{- $key = $key | default $admin.key -}}
{{- end -}}
{{- $prefix := printf "database.readAccess.jobs.%s" $owner -}}
{{- toJson (dict
  "user" (required (printf "%s.adminUser (or database.admin.username) is required: the admin user that makes the read-only users" $prefix) $user)
  "secret" (required (printf "%s.adminPasswordSecret (or database.admin.password.existingSecret) is required: the Secret with the password of the admin user" $prefix) $secret)
  "key" (required (printf "%s.adminPasswordKey is required with adminPasswordSecret" $prefix) $key)) -}}
{{- end }}

{{/*
The chart's read-only users as (reader, owner) pairs: api -> wallet and
wallet -> api. Output: JSON list of [reader, owner].
*/}}
{{- define "ow.readAccess.pairs" -}}
{{- toJson (list (list "api" "wallet") (list "wallet" "api")) -}}
{{- end }}

{{/*
Fails when two read-only users of the chart (ow.readAccess.pairs) have the
same name on one database server. A PostgreSQL role belongs to the whole
server, so the second "read-access apply" would change the first user's
password and one read connection would fail. Output: nothing.
*/}}
{{- define "ow.readAccess.checkNames" -}}
{{- $root := . -}}
{{- $v := $root.Values -}}
{{- $pairs := include "ow.readAccess.pairs" $root | fromJsonArray -}}
{{- $seen := dict -}}
{{- range $pair := $pairs -}}
{{- $reader := index $pair 0 -}}
{{- $owner := index $pair 1 -}}
{{- $entry := index (index $v.database.readAccess $reader | default dict) $owner | default dict -}}
{{- if $entry.username -}}
{{- $host := $entry.host | default (include "ow.db.host" $root) -}}
{{- $port := $entry.port | default (include "ow.db.port" $root) | toString -}}
{{- $key := printf "%s|%s|%s" $host $port $entry.username -}}
{{- with get $seen $key -}}
{{- fail (printf "database.readAccess.%s.username and database.readAccess.%s.%s.username are both %q on the database server %s:%s: a PostgreSQL role belongs to the whole server, so the second read-access apply changes the password of the first. Use one name per reader and owner, for example the default <reader>_<owner>_reader" . $reader $owner $entry.username $host $port) -}}
{{- end -}}
{{- $_ := set $seen $key (printf "%s.%s" $reader $owner) -}}
{{- end -}}
{{- end -}}
{{- end }}

{{/*
terminationGracePeriodSeconds of a Go server (api, webhook handler,
gateway): the chart calculates it. The preStop hook first sleeps
preStopSeconds, so the pod keeps serving while Kubernetes removes it from
the endpoints. Then, on SIGTERM, the server drains for drainSeconds and
waits at most gracefulShutdownSeconds. Kubernetes counts the grace period
from the start of the preStop, so it is preStop + drain + graceful + a 5 s
margin. A drain or graceful value of 0 means the service's own default.
Call with (list <values with preStopSeconds, drainSeconds,
gracefulShutdownSeconds> <default drain> <default graceful>). Output: the
number of seconds.
*/}}
{{- define "ow.goGracePeriod" -}}
{{- $v := index . 0 -}}
{{- $drain := $v.drainSeconds | int | default (index . 1) -}}
{{- $graceful := $v.gracefulShutdownSeconds | int | default (index . 2) -}}
{{- add ($v.preStopSeconds | int) $drain $graceful 5 -}}
{{- end }}
