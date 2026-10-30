{{/*
config.yaml of one organisation wallet role (pydantic-settings, nested
keys; an unknown key stops the wallet). The wallet reads the file of
EUDI_WALLET_CONFIG. The file has no secret: each <key>_file names a file in
ow.wallet.secretDir (see ow.wallet.secretFiles).
Roles: "service" (public routes), "config" (internal configuration
routes), "worker" (a group of organisationWallet.workers.groups: the
actors of its queues), "clock" (it sends the cron actors) and "scheduler"
(no HTTP server).
Call with (dict "root" $ "role" "<role>"), for a worker with (dict "root"
$ "role" "worker" "group" <group>).
*/}}
{{- define "ow.wallet.config" -}}
{{- $root := .root -}}
{{- $role := .role -}}
{{- $v := $root.Values -}}
{{- $w := $v.organisationWallet -}}
{{- $dir := include "ow.wallet.secretDir" $root -}}
{{- $files := include "ow.wallet.secretFiles" (list $root $role) | fromJson -}}
{{- $client := include "ow.nats.client" (list $root (include "ow.wallet.natsUser" $role)) | fromJson -}}
{{- $signing := include "ow.serviceKeys.signing" (list $root $w "organisationWallet" "wallet-service-key") | fromJson -}}
{{- /* The key management service is always the Transit engine of OpenBao:
the bundled OpenBao of the chart or an external OpenBao. The wallet config
section of OpenBao is named "vault" (a key of the wallet code). */ -}}
{{- $openbao := dict
    "addr" (include "ow.openbao.address" $root)
    "user" (include "ow.openbao.walletUser" $root)
    "password_file" (printf "%s/openbao-password" $dir)
    "transit_mount" (include "ow.openbao.transitMount" $root) -}}
{{- with include "ow.openbao.namespace" $root -}}
{{- $_ := set $openbao "namespace" . -}}
{{- end -}}
{{- if hasKey $files "openbao-ca.crt" -}}
{{- $_ := set $openbao "ca_cert_file" (printf "%s/openbao-ca.crt" $dir) -}}
{{- end -}}
{{- /* The key store providers of this installation (camelCase in the
values, the wallet keys here); the built-in providers come from the wallet. */ -}}
{{- $added := list -}}
{{- range $w.keyStores.providers.add -}}
{{- $entry := dict "id" .id "category" .category "type" .type "name" .name "protection" .protection -}}
{{- with .logoUrl -}}{{- $_ := set $entry "logo_url" . -}}{{- end -}}
{{- if hasKey . "qualified" -}}{{- $_ := set $entry "qualified" .qualified -}}{{- end -}}
{{- with .region -}}{{- $_ := set $entry "region" . -}}{{- end -}}
{{- with .defaults -}}{{- $_ := set $entry "defaults" . -}}{{- end -}}
{{- if hasKey . "order" -}}{{- $_ := set $entry "order" (.order | int) -}}{{- end -}}
{{- $added = append $added $entry -}}
{{- end -}}
{{- /* The local key store of the installation: the Transit engine of
OpenBao. */ -}}
{{- $kms := dict
    "platform" "transit"
    "local_backend" "openbao"
    "vault" $openbao
    "organisation_key_store_types" $w.keyStores.types
    "key_store_providers" (dict "add" $added "hide" $w.keyStores.providers.hide)
    "allow_private_addresses" $w.keyStores.allowPrivateAddresses
    "test_ca" (dict "enabled" $w.keyStores.testCa.enabled "leaf_validity_days" ($w.keyStores.testCa.leafValidityDays | int)) -}}
{{- /* An empty eu_lotl_url switches the EU trusted list check off (null). */ -}}
{{- $trustList := dict "lookup_url" $w.trustList.lookupUrl "eu_lotl_url" ($w.trustList.euLotlUrl | default nil) -}}
{{- if hasKey $files "trust-list-lookup-token" -}}
{{- $_ := set $trustList "lookup_token_file" (printf "%s/trust-list-lookup-token" $dir) -}}
{{- end -}}
{{- /* The audit log (audit.*): the retention in the file of every role,
so that each process and the migration hook have the same values; the
bucket of the anchor copies and of the monthly exports only in the
workers, which write them (the actors audit.anchor and audit.export) and
mount the credentials of the bucket (ow.wallet.secretFiles). */ -}}
{{- include "ow.wallet.checkAudit" $root -}}
{{- $audit := include "ow.wallet.auditRetention" $root | fromJson -}}
{{- $b := $w.audit.bucket -}}
{{- if and (eq $role "worker") $b.name -}}
{{- $bucket := dict "type" $b.type "name" $b.name -}}
{{- with $b.prefix -}}
{{- $_ := set $bucket "prefix" . -}}
{{- end -}}
{{- if eq $b.type "s3" -}}
{{- $_ := set $bucket "endpoint" $b.endpoint -}}
{{- $_ := set $bucket "region" $b.region -}}
{{- $_ := set $bucket "access_key_id_file" (printf "%s/audit-bucket-access-key-id" $dir) -}}
{{- $_ := set $bucket "secret_access_key_file" (printf "%s/audit-bucket-secret-access-key" $dir) -}}
{{- if hasKey $files "audit-bucket-ca.crt" -}}
{{- $_ := set $bucket "ca_file" (printf "%s/audit-bucket-ca.crt" $dir) -}}
{{- end -}}
{{- else -}}
{{- with $b.project -}}
{{- $_ := set $bucket "project" . -}}
{{- end -}}
{{- if hasKey $files "audit-bucket-service-account.json" -}}
{{- $_ := set $bucket "credentials_file" (printf "%s/audit-bucket-service-account.json" $dir) -}}
{{- end -}}
{{- end -}}
{{- $_ := set $audit "bucket" $bucket -}}
{{- end -}}
{{- /* The retention purge (retention.*): the deactivation of an organisation
writes its purge date, the workers purge. */ -}}
{{- $r := $w.retention -}}
{{- $retention := dict
    "soft_deleted_days" ($r.softDeletedDays | int)
    "deactivated_organisation_days" ($r.deactivatedOrganisationDays | int)
    "deactivated_sandbox_days" ($r.deactivatedSandboxDays | int)
    "dead_letter_days" ($r.deadLetterDays | int)
    "login_code_days" ($r.loginCodeDays | int)
    "verifier_response_key_days" ($r.verifierResponseKeyDays | int)
    "batch_size" ($r.batchSize | int) -}}
{{- $walletUnit := dict "production_checks_enabled" $w.walletUnit.productionChecksEnabled -}}
{{- if hasKey $files "play-integrity-service-account.json" -}}
{{- $_ := set $walletUnit "play_integrity_credentials_file" (printf "%s/play-integrity-service-account.json" $dir) -}}
{{- end -}}
{{- $config := dict
  "domain" (include "ow.publicUrlOf" (list $root "organisationWallet"))
  "log_level" ($w.logLevel | upper)
  "database" (include "ow.wallet.database" (list $root (include "ow.wallet.databaseUser" (list $root (include "ow.wallet.databaseRole" $role))) "database-password") | fromJson)
  "nats" (dict
    "url" (include "ow.nats.url" $root)
    "nkey_seed_file" (printf "%s/nats-seed" $dir)
    "inbox_prefix" $client.inbox
    "stream_replicas" (include "ow.nats.jetstreamReplicas" $root | int)
    "connect_retry_seconds" ($w.nats.connectRetrySeconds | int))
  "service_envelope" (dict
    "service_name" "eudi-wallet"
    "api_service_name" "igrant-api"
    "consent_service_name" "igrant-consent-management"
    "signing_jwks_file" (printf "%s/service-envelope-jwks.json" $dir)
    "active_kid" $signing.activeKid
    "lifetime_seconds" ($w.serviceEnvelope.lifetimeSeconds | int)
    "clock_skew_seconds" ($w.serviceEnvelope.clockSkewSeconds | int))
  "kms" $kms
  "trust_list" $trustList
  "wallet_unit" $walletUnit
  "audit" $audit
  "retention" $retention -}}
{{- /* Valkey (redis): the work queue, the single-use values and the caches. */ -}}
{{- $_ := set $config "redis" (include "ow.wallet.redis" (list $root $role) | fromJson) -}}
{{- /* The clock reads only the database and Valkey: no service envelope (it
publishes nothing), no trust list, wallet unit, audit log or retention
settings. The clock connects to no NATS and starts no KMS, but the file of
every wallet process names the NATS address and kms.vault; the clock
mounts no NATS seed and no OpenBao password. */ -}}
{{- if eq $role "clock" -}}
{{- range $key := list "service_envelope" "trust_list" "wallet_unit" "audit" "retention" -}}
{{- $_ := unset $config $key -}}
{{- end -}}
{{- end -}}
{{- /* The health server of the workers and of the clock: /healthz (the
heartbeat), /readyz (Valkey and the database) and /metrics. The worker
processes of a pod share their heartbeat and metric files in
state_directory (an emptyDir). */ -}}
{{- if eq $role "worker" -}}
{{- $_ := set $config "worker" (dict "health_port" (include "ow.wallet.workerHealthPort" $root | int) "state_directory" (include "ow.wallet.workerStateDir" $root)) -}}
{{- else if eq $role "clock" -}}
{{- $_ := set $config "nats" (dict "url" (include "ow.nats.url" $root)) -}}
{{- $_ := set $config "clock" (dict "health_port" (include "ow.wallet.clockHealthPort" $root | int)) -}}
{{- end -}}
{{- if has $role (list "service" "config") -}}
{{- include "ow.wallet.checkServer" $root -}}
{{- $server := dict
    "route_group" $role
    "port" 8080
    "max_request_body_bytes" ($w.server.maxRequestBodyBytes | int64)
    "max_batch_request_body_bytes" ($w.server.maxBatchRequestBodyBytes | int64)
    "max_large_request_body_bytes" ($w.server.maxLargeRequestBodyBytes | int64)
    "graceful_shutdown_seconds" ($w.server.gracefulShutdownSeconds | int)
    "background_shutdown_seconds" ($w.server.backgroundShutdownSeconds | int) -}}
{{- /* The service pods are behind your ingress controller or Gateway. The
auth gateway calls the config pods directly, so they keep the wallet default
(127.0.0.1). */ -}}
{{- if eq $role "service" -}}
{{- if not $w.forwardedAllowIps -}}
{{- fail "organisationWallet.forwardedAllowIps needs at least one entry (an IP address, a network, or only \"*\")" -}}
{{- end -}}
{{- $_ := set $server "forwarded_allow_ips" $w.forwardedAllowIps -}}
{{- end -}}
{{- $_ := set $config "server" $server -}}
{{- end -}}
{{- if and $root.Values.nats.tlsCa.existingSecret (ne $role "clock") -}}
{{- $_ := set $config.nats "tls_ca_file" (printf "%s/nats-ca.crt" $dir) -}}
{{- end -}}
{{- /* The config role always checks the internal token of the gateway
(internal_auth; the gateway of the chart is the trusted issuer) and trusts
the signed NATS commands of the api (service_envelope.trusted_issuers). The
service role keeps the protocol routes public and direct. */ -}}
{{- if eq $role "config" -}}
{{- include "ow.gateway.checkGatewayJwks" $root -}}
{{- $_ := set $config "internal_auth" (dict
    "audience" $v.gateway.internalToken.audiences.walletConfig
    "clock_skew_seconds" ($w.internalAuth.clockSkewSeconds | int)
    "trusted_issuers" (list (dict
      "issuer" $v.gateway.internalToken.issuer
      "jwks_file" (printf "%s/gateway-jwks.json" (include "ow.gateway.keysDir" $root))))) -}}
{{- $trusted := list -}}
{{- range $item := include "ow.serviceKeys.trusted" (list $root "igrant-api") | fromJsonArray -}}
{{- $trusted = append $trusted (dict "issuer" $item.issuer "jwks_file" $item.jwksFile) -}}
{{- end -}}
{{- $_ := set $config.service_envelope "trusted_issuers" $trusted -}}
{{- /* The config role reads the views of the api and consent databases with
the read-only users of the wallet (read_access, the shape of database). */ -}}
{{- $readAccess := dict -}}
{{- range $owner := include "ow.wallet.readAccessOwners" $root | splitList "," -}}
{{- $reader := include "ow.readAccess.reader" (list $root "wallet" $owner) | fromJson -}}
{{- $_ := set $readAccess $owner (include "ow.db.wallet" (dict
    "root" $root
    "host" $reader.host
    "port" $reader.port
    "name" $reader.name
    "user" $reader.username
    "passwordFile" (printf "%s/read-access-%s-password" $dir $owner)
    "caFile" (printf "%s/%s" $dir (include "ow.db.caFileName" $root))) | fromJson) -}}
{{- end -}}
{{- $_ := set $config "read_access" $readAccess -}}
{{- /* The server-sent event streams of the config routes: the
notifications stream and its replay, the presentation-status stream. The
keep-alive must stay well below the SSE idle cut of the gateway, else the
gateway ends quiet streams. */ -}}
{{- if lt ($v.gateway.proxy.sseIdleTimeoutSeconds | int) (mul 2 ($w.sse.keepAliveSeconds | int)) -}}
{{- fail (printf "gateway.proxy.sseIdleTimeoutSeconds (%v) must be at least 2 x organisationWallet.sse.keepAliveSeconds (%v): the gateway would end quiet server-sent event streams" $v.gateway.proxy.sseIdleTimeoutSeconds $w.sse.keepAliveSeconds) -}}
{{- end -}}
{{- $_ := set $config "sse" (dict
    "keep_alive_seconds" ($w.sse.keepAliveSeconds | int)
    "retry_milliseconds" ($w.sse.retryMilliseconds | int)
    "max_streams_per_worker" ($w.sse.maxStreamsPerWorker | int)
    "client_queue_size" ($w.sse.clientQueueSize | int)) -}}
{{- $_ := set $config "notifications_sse" (dict
    "replay_max_events" ($w.notificationsSse.replayMaxEvents | int)
    "replay_lookback_seconds" ($w.notificationsSse.replayLookbackSeconds | int)) -}}
{{- $_ := set $config "presentation_status_sse" (dict
    "recheck_seconds" ($w.presentationStatusSse.recheckSeconds | int)
    "max_stream_seconds" ($w.presentationStatusSse.maxStreamSeconds | int)) -}}
{{- /* The public base URL of the api host (api ApiBaseUrl): the wallet
builds the public image URIs of the routes that the gateway sends to it. */ -}}
{{- $_ := set $config "gateway_api" (dict "public_api_base_url" (include "ow.publicUrlOf" (list $root "api"))) -}}
{{- end -}}
{{- mustMergeOverwrite $config (deepCopy ($w.extraConfig | default dict)) | toYaml -}}
{{- end }}

{{/*
Render guards of the wallet server keys:
- the stop of a service or config pod must end before Kubernetes kills the
  process: preStopSeconds + gracefulShutdownSeconds +
  backgroundShutdownSeconds below terminationGracePeriodSeconds;
- the gateway must not refuse a body that the wallet accepts: the gateway
  limit of the class (gateway.proxy.maxBodyBytes; 0 = the class default of
  the gateway) at least the wallet limit (default >= S, large >= L).
Call with the root context.
*/}}
{{- define "ow.wallet.checkServer" -}}
{{- $s := .Values.organisationWallet.server -}}
{{- $stop := add ($s.preStopSeconds | int) ($s.gracefulShutdownSeconds | int) ($s.backgroundShutdownSeconds | int) -}}
{{- if ge $stop ($s.terminationGracePeriodSeconds | int) -}}
{{- fail (printf "organisationWallet.server: preStopSeconds (%v) + gracefulShutdownSeconds (%v) + backgroundShutdownSeconds (%v) = %v must be below terminationGracePeriodSeconds (%v): Kubernetes would kill the wallet before it stops" $s.preStopSeconds $s.gracefulShutdownSeconds $s.backgroundShutdownSeconds $stop $s.terminationGracePeriodSeconds) -}}
{{- end -}}
{{- $gateway := .Values.gateway.proxy.maxBodyBytes -}}
{{- $default := $gateway.default | int64 | default 1048576 -}}
{{- $large := $gateway.large | int64 | default 10485760 -}}
{{- if lt $default ($s.maxRequestBodyBytes | int64) -}}
{{- fail (printf "gateway.proxy.maxBodyBytes.default (%v) must be at least organisationWallet.server.maxRequestBodyBytes (%v): the gateway would refuse a body that the wallet accepts" $default $s.maxRequestBodyBytes) -}}
{{- end -}}
{{- if lt $large ($s.maxLargeRequestBodyBytes | int64) -}}
{{- fail (printf "gateway.proxy.maxBodyBytes.large (%v) must be at least organisationWallet.server.maxLargeRequestBodyBytes (%v): the gateway would refuse a body that the wallet accepts" $large $s.maxLargeRequestBodyBytes) -}}
{{- end -}}
{{- end }}

{{/*
config.yaml of the wallet hooks (the roles, migration and read access
hooks): only the database, with the login of the hook, and the log level
(the migration hook adds the retention of the audit log:
ow.wallet.migrateConfig). database-roles, migrate-database and read-access
read only these keys; the hooks run before the resources of the release
change, so they cannot read the new ConfigMaps of the release. Call with
(list $ "<user>" "<password file name>").
*/}}
{{- define "ow.wallet.hookConfig" -}}
{{- toYaml (dict
    "log_level" ((index . 0).Values.organisationWallet.logLevel | upper)
    "database" (include "ow.wallet.database" . | fromJson)) }}
{{- end }}

{{/*
The database section of the wallet (its own database in the chart) for one
login: the user and the name of its password file in ow.wallet.secretDir.
Call with (list $ "<user>" "<password file name>"). Output: JSON.
*/}}
{{- define "ow.wallet.database" -}}
{{- $root := index . 0 -}}
{{- $dir := include "ow.wallet.secretDir" $root -}}
{{- include "ow.db.wallet" (dict
  "root" $root
  "host" (include "ow.db.host" $root)
  "port" (include "ow.db.port" $root)
  "name" $root.Values.database.databases.wallet.name
  "user" (index . 1)
  "passwordFile" (printf "%s/%s" $dir (index . 2))
  "caFile" (printf "%s/%s" $dir (include "ow.db.caFileName" $root))) -}}
{{- end }}

{{/*
config.yaml of the migration hook of the wallet: ow.wallet.hookConfig and
the retention of the audit log (ow.wallet.auditRetention): the partition
step of migrate-database drops the months of the audit events that are
older than the retention, only after a verified export. Call with (list $
"<user>" "<password file name>").
*/}}
{{- define "ow.wallet.migrateConfig" -}}
{{- $config := include "ow.wallet.hookConfig" . | fromYaml -}}
{{- $_ := set $config "audit" (include "ow.wallet.auditRetention" (index . 0) | fromJson) -}}
{{- toYaml $config }}
{{- end }}

{{/*
The retention of the audit log (audit.retention_years and
audit.scope_retention_years) of the wallet files and of the migration hook.
Call with the root context. Output: JSON.
*/}}
{{- define "ow.wallet.auditRetention" -}}
{{- $a := .Values.organisationWallet.audit -}}
{{- $audit := dict "retention_years" ($a.retentionYears | int) -}}
{{- if $a.scopeRetentionYears -}}
{{- $scopes := dict -}}
{{- range $scope, $years := $a.scopeRetentionYears -}}
{{- $_ := set $scopes $scope ($years | int) -}}
{{- end -}}
{{- $_ := set $audit "scope_retention_years" $scopes -}}
{{- end -}}
{{- toJson $audit -}}
{{- end }}

{{/*
Render guards of the audit log: the credentials of the bucket need the
bucket; the values of type s3 and of type gcs do not mix; type s3 needs its
endpoint, its region and the Secret of its access key. Call with the root
context.
*/}}
{{- define "ow.wallet.checkAudit" -}}
{{- $b := .Values.organisationWallet.audit.bucket -}}
{{- $p := "organisationWallet.audit.bucket" -}}
{{- if not $b.name -}}
{{- range $value := list "credentials" "accessKey" "ca" -}}
{{- if (index $b $value).existingSecret -}}
{{- fail (printf "%s.%s.existingSecret needs %s.name: the Secret is the one of the audit bucket" $p $value $p) -}}
{{- end -}}
{{- end -}}
{{- else if eq $b.type "s3" -}}
{{- if not $b.endpoint -}}
{{- fail (printf "%s.endpoint is required with type s3 (the default): the S3 API of the store. For a Google Cloud Storage bucket through the Google client, set %s.type: gcs" $p $p) -}}
{{- end -}}
{{- if not $b.region -}}
{{- fail (printf "%s.region is required with type s3: the region of the signatures" $p) -}}
{{- end -}}
{{- if not $b.accessKey.existingSecret -}}
{{- fail (printf "%s.accessKey.existingSecret is required with type s3: the Secret with the access key of the wallet" $p) -}}
{{- end -}}
{{- if not (regexMatch "^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$" $b.name) -}}
{{- fail (printf "%s.name %q is not an S3 bucket name (3 to 63 lower-case letters, digits, dots and hyphens)" $p $b.name) -}}
{{- end -}}
{{- if or $b.project $b.credentials.existingSecret -}}
{{- fail (printf "%s.project and .credentials are values of type gcs, not of type s3" $p) -}}
{{- end -}}
{{- else if or $b.endpoint $b.region $b.accessKey.existingSecret $b.ca.existingSecret -}}
{{- fail (printf "%s.endpoint, .region, .accessKey and .ca are values of type s3, not of type gcs" $p) -}}
{{- end -}}
{{- end }}
