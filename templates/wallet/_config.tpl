{{/*
config.yaml of one organisation wallet role (pydantic-settings with nested
keys; an unknown key stops the wallet). The wallet reads the file named by
EUDI_WALLET_CONFIG. The file holds no secrets: each <key>_file names a file
in ow.wallet.secretDir (see ow.wallet.secretFiles).
Roles: "service" (public routes), "config" (internal config routes),
"worker" (one group from organisationWallet.workers.groups, running the
actors of its queues) and "clock" (sends the cron actors).
Call with (dict "root" $ "role" "<role>"), or for a worker with (dict "root"
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
{{- /* The key management service is always the OpenBao Transit engine:
the chart's bundled OpenBao or an external one. The wallet's config section
for OpenBao is called "vault" (a key in the wallet code). */ -}}
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
{{- /* This installation's key store providers (camelCase in the values,
wallet keys here); the built-in providers come from the wallet. */ -}}
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
{{- /* The installation's local key store: the OpenBao Transit engine. */ -}}
{{- $kms := dict
    "platform" "transit"
    "local_backend" "openbao"
    "vault" $openbao
    "organisation_key_store_types" $w.keyStores.types
    "key_store_providers" (dict "add" $added "hide" $w.keyStores.providers.hide)
    "allow_private_addresses" $w.keyStores.allowPrivateAddresses
    "test_ca" (dict "enabled" $w.keyStores.testCa.enabled "leaf_validity_days" ($w.keyStores.testCa.leafValidityDays | int)) -}}
{{- /* An empty eu_lotl_url switches the EU trusted list check off (null). */ -}}
{{- $trustList := dict "eu_lotl_url" ($w.trustList.euLotlUrl | default nil) -}}
{{- /* Refresh of the organisations' list trust sources. */ -}}
{{- $ts := $w.trustSources -}}
{{- $trustSources := dict
    "refresh_max_interval_seconds" ($ts.refreshMaxIntervalSeconds | int)
    "refresh_min_interval_seconds" ($ts.refreshMinIntervalSeconds | int)
    "retry_interval_seconds" ($ts.retryIntervalSeconds | int)
    "stale_grace_seconds" ($ts.staleGraceSeconds | int)
    "manual_refresh_min_interval_seconds" ($ts.manualRefreshMinIntervalSeconds | int) -}}
{{- /* Audit log (audit.*). The retention goes into every role's file, so
every process and the migration hook use the same values. The bucket for
anchor copies and monthly exports goes only to the workers, which write
them (actors audit.anchor and audit.export) and mount the bucket
credentials (ow.wallet.secretFiles). */ -}}
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
{{- /* Retention purge (retention.*): deactivating an organisation writes
its purge date, and the workers purge. */ -}}
{{- $r := $w.retention -}}
{{- $retention := dict
    "soft_deleted_days" ($r.softDeletedDays | int)
    "deactivated_organisation_days" ($r.deactivatedOrganisationDays | int)
    "deactivated_sandbox_days" ($r.deactivatedSandboxDays | int)
    "dead_letter_days" ($r.deadLetterDays | int)
    "login_code_days" ($r.loginCodeDays | int)
    "verifier_response_key_days" ($r.verifierResponseKeyDays | int)
    "issued_credential_token_days" ($r.issuedCredentialTokenDays | int)
    "batch_size" ($r.batchSize | int) -}}
{{- $walletUnit := dict "production_checks_enabled" $w.walletUnit.productionChecksEnabled -}}
{{- /* Maximum number of organisation wallet units in the installation
(organisationWallet.walletUnit.organisationWalletUnitsMax). The key is set
only when the installer gives a value; otherwise the wallet uses its
default. The clock has no wallet_unit section. */ -}}
{{- with dig "organisationWalletUnitsMax" "" $w.walletUnit -}}
{{- $_ := set $walletUnit "organisation_wallet_units_max" (. | int) -}}
{{- end -}}
{{- /* wallet_unit.development_apps_allowed (read by the config and service
processes) is set only when the installer sets true or false; empty sets no
key (the wallet default, false). A string, even "true", fails the render
because the wallet reads a boolean. */ -}}
{{- $developmentApps := dig "developmentAppsAllowed" "" $w.walletUnit -}}
{{- if kindIs "bool" $developmentApps -}}
{{- $_ := set $walletUnit "development_apps_allowed" $developmentApps -}}
{{- else if and (not (kindIs "invalid" $developmentApps)) (ne (toString $developmentApps) "") -}}
{{- fail (printf "organisationWallet.walletUnit.developmentAppsAllowed (%q) must be true, false or empty: give a boolean, not a text" (toString $developmentApps)) -}}
{{- end -}}
{{- $p := $w.walletUnit.playIntegrity -}}
{{- $digests := $w.walletUnit.androidSigningCertificateDigests -}}
{{- if and $p.existingSecret (not $digests) -}}
{{- fail "organisationWallet.walletUnit.androidSigningCertificateDigests needs the SHA-256 of the app signing key certificate when playIntegrity.existingSecret is set" -}}
{{- end -}}
{{- /* The service pods answer the WIA and key attestation requests of
wallet units, so only their file gets the Android app digests. */ -}}
{{- if and $digests (eq $role "service") -}}
{{- $_ := set $walletUnit "android_signing_certificate_digests" $digests -}}
{{- end -}}
{{- /* App IDs of the iOS wallet apps: the service pods check the App Attest
objects in the same requests. */ -}}
{{- $appIds := $w.walletUnit.appAttest.appIds -}}
{{- if and $w.walletUnit.productionChecksEnabled (not $appIds) -}}
{{- fail "organisationWallet.walletUnit.appAttest.appIds needs at least one App ID (<Team ID>.<bundle id>) of the iOS wallet app when productionChecksEnabled is true" -}}
{{- end -}}
{{- if eq $role "service" -}}
{{- $_ := set $walletUnit "app_attest" (dict "app_ids" $appIds) -}}
{{- end -}}
{{- if hasKey $files "play-integrity-decryption-key" -}}
{{- $_ := set $walletUnit "play_integrity" (dict
    "decryption_key_file" (printf "%s/play-integrity-decryption-key" $dir)
    "verification_key_file" (printf "%s/play-integrity-verification-key" $dir)
    "package_name" $p.packageName
    "min_version_code" ($p.minVersionCode | int)) -}}
{{- end -}}
{{- /* Device roots from the ConfigMap (organisationWallet.walletUnit.
trustAnchors) in the roles that mount them; otherwise the image's roots. */ -}}
{{- if include "ow.wallet.trustAnchors" (list $root $role) -}}
{{- $_ := set $walletUnit "trust_anchors_dir" (include "ow.wallet.trustAnchorsDir" $root) -}}
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
  "trust_sources" $trustSources
  "wallet_unit" $walletUnit
  "audit" $audit
  "retention" $retention -}}
{{- /* Process pools (database.pools.wallet*; docs/database.md, "Connection
budget"): the session pool and the allocation pool of a service, config or
worker process. A worker process has one session connection per thread of
its group. The clock opens no session (only its leader connection and its
health check). */ -}}
{{- $pools := $v.database.pools -}}
{{- $pool := dict -}}
{{- if eq $role "service" -}}
{{- $pool = dict "pool_size" $pools.walletService.poolSize "max_overflow" $pools.walletService.maxOverflow "allocation_pool_size" $pools.walletService.allocationPoolSize -}}
{{- else if eq $role "config" -}}
{{- $pool = dict "pool_size" $pools.walletConfig.poolSize "max_overflow" $pools.walletConfig.maxOverflow "allocation_pool_size" $pools.walletConfig.allocationPoolSize -}}
{{- else if eq $role "worker" -}}
{{- $pool = dict "pool_size" .group.threads "max_overflow" $pools.walletWorker.maxOverflow "allocation_pool_size" $pools.walletWorker.allocationPoolSize -}}
{{- end -}}
{{- range $key, $value := $pool -}}
{{- $_ := set $config.database $key ($value | int) -}}
{{- end -}}
{{- /* Pooler (database.pooler): the session engines of processes that have
sessions connect through it; the clock has none. */ -}}
{{- with $v.database.pooler.host -}}
{{- if has $role (list "service" "config" "worker") -}}
{{- $_ := set $config.database "pooler" (dict "host" . "port" ($v.database.pooler.port | int)) -}}
{{- end -}}
{{- end -}}
{{- /* Valkey (redis): the work queue, the single-use values and the caches. */ -}}
{{- $_ := set $config "redis" (include "ow.wallet.redis" (list $root $role) | fromJson) -}}
{{- /* The clock reads only the database and Valkey settings (the wallet's
load_clock_settings): no domain, NATS, KMS, service envelope, trust list,
trust sources, wallet unit, audit log or retention settings. It mounts no
NATS seed and no OpenBao password. */ -}}
{{- if eq $role "clock" -}}
{{- range $key := list "domain" "nats" "kms" "service_envelope" "trust_list" "trust_sources" "wallet_unit" "audit" "retention" -}}
{{- $_ := unset $config $key -}}
{{- end -}}
{{- end -}}
{{- /* Health server of the workers and the clock: /healthz (heartbeat),
/readyz (Valkey and the database) and /metrics. The worker processes of a
pod share their heartbeat and metric files in state_directory (an
emptyDir). */ -}}
{{- if eq $role "worker" -}}
{{- $_ := set $config "worker" (dict "health_port" (include "ow.wallet.workerHealthPort" $root | int) "state_directory" (include "ow.wallet.workerStateDir" $root)) -}}
{{- /* Writes of the issuer status lists: only the workers' actor
status_list.write_changes reads the interval. */ -}}
{{- $_ := set $config "status_list" (dict "write_interval_seconds" ($w.statusList.writeIntervalSeconds | int)) -}}
{{- else if eq $role "clock" -}}
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
    "background_shutdown_seconds" ($w.server.backgroundShutdownSeconds | int)
    "nonce_requests_per_minute" ($w.server.nonceRequestsPerMinute | int)
    "metrics_port" (include "ow.wallet.serverMetricsPort" $root | int)
    "metrics_directory" (include "ow.wallet.serverMetricsDir" $root) -}}
{{- /* forwarded_allow_ips: the service pods sit behind your ingress
controller or Gateway. The auth gateway calls the config pods directly, so
they keep the wallet default (127.0.0.1). */ -}}
{{- if eq $role "service" -}}
{{- if not $w.forwardedAllowIps -}}
{{- fail "organisationWallet.forwardedAllowIps needs at least one entry (an IP address, a network, or only \"*\")" -}}
{{- end -}}
{{- $_ := set $server "forwarded_allow_ips" $w.forwardedAllowIps -}}
{{- end -}}
{{- $_ := set $config "server" $server -}}
{{- end -}}
{{- if and (include "ow.nats.ca" $root | fromJson).secret (ne $role "clock") -}}
{{- $_ := set $config.nats "tls_ca_file" (printf "%s/nats-ca.crt" $dir) -}}
{{- end -}}
{{- /* The config role always checks the gateway's internal token
(internal_auth; the chart's gateway is the trusted issuer) and trusts the
api's signed NATS commands (service_envelope.trusted_issuers). The service
role keeps the protocol routes public and direct. */ -}}
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
{{- /* The config role reads the api and consent database views with the
wallet's read-only users (read_access, same shape as database). */ -}}
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
{{- /* Lifetime of a stored command reply. It must be the same in every
config pod, because each one sets the reply bucket's TTL at start. */ -}}
{{- $_ := set $config.nats "command_reply_seconds" ($w.nats.commandReplySeconds | int) -}}
{{- /* Server-sent event streams of the config routes: the notifications
stream with its replay, and the presentation-status stream. The keep-alive
must stay well below the gateway's SSE idle cut, or the gateway ends quiet
streams. */ -}}
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
{{- /* Public base URL of the api host (api ApiBaseUrl): the wallet builds
public image URIs for the routes that the gateway sends to it. */ -}}
{{- $_ := set $config "gateway_api" (dict "public_api_base_url" (include "ow.publicUrlOf" (list $root "api"))) -}}
{{- end -}}
{{- /* Private hosts that the wallet's SSRF guard allows
(organisationWallet.ssrf.allowedPrivate), set only when there are entries.
The wallet refuses an entry that covers loopback, link-local or cloud
metadata addresses; the render fails on the plain cases. */ -}}
{{- with $w.ssrf.allowedPrivate -}}
{{- range $entry := . -}}
{{- $text := lower (toString $entry) -}}
{{- if or (hasPrefix "127." $text) (hasPrefix "169.254." $text) (hasPrefix "0." $text) (eq $text "localhost") (hasPrefix "::1" $text) (hasPrefix "fe80:" $text) (eq $text "::") -}}
{{- fail (printf "organisationWallet.ssrf.allowedPrivate: %q covers a loopback, link-local, metadata or unspecified address, which the wallet never allows; give the private host names or the networks of your public hosts" $entry) -}}
{{- end -}}
{{- end -}}
{{- $_ := set $config "ssrf_protection" (dict "allowed_private" .) -}}
{{- end -}}
{{- $config = mustMergeOverwrite $config (deepCopy ($w.extraConfig | default dict)) -}}
{{- include "ow.wallet.checkWritablePaths" (list $config $role) -}}
{{- $config | toYaml -}}
{{- end }}

{{/*
Render guard for the writable paths in one wallet file. The wallet pods
have a read-only root file system, so every folder a process writes to
(server.metrics_directory, worker.state_directory, also when set in
organisationWallet.extraConfig) must be on one of the pod's emptyDirs: /tmp
in every pod, /run/ows-server in service and config pods, /run/ows-worker in
worker pods. No role has a log file (log_file.path, ow.noLogFile): the
processes log to stdout. Call with (list <config> "<role>"). Output:
nothing.
*/}}
{{- define "ow.wallet.checkWritablePaths" -}}
{{- $config := index . 0 -}}
{{- $role := index . 1 -}}
{{- $mounts := list "/tmp" -}}
{{- if has $role (list "service" "config") -}}{{- $mounts = append $mounts (include "ow.wallet.serverMetricsDir" .) -}}{{- end -}}
{{- if eq $role "worker" -}}{{- $mounts = append $mounts (include "ow.wallet.workerStateDir" .) -}}{{- end -}}
{{- include "ow.noLogFile" (list "organisationWallet.extraConfig" "log_file.path" (((get $config "log_file") | default dict).path)) -}}
{{- $paths := dict
    "server.metrics_directory" (((get $config "server") | default dict).metrics_directory | default "" | toString)
    "worker.state_directory" (((get $config "worker") | default dict).state_directory | default "" | toString) -}}
{{- range $key, $path := $paths -}}
{{- if $path -}}
{{- $ok := false -}}
{{- range $mount := $mounts -}}
{{- if or (eq (clean $path) $mount) (hasPrefix (printf "%s/" $mount) (clean $path)) -}}{{- $ok = true -}}{{- end -}}
{{- end -}}
{{- if not $ok -}}
{{- fail (printf "the %s file of the wallet has %s %q: the root file system of the wallet pods is read-only; give a path below %s (an emptyDir of the pod)" $role $key $path (join " or " $mounts)) -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end }}

{{/*
Render guards for the wallet server keys:
- a service or config pod must finish stopping before Kubernetes kills the
  process: preStopSeconds + gracefulShutdownSeconds +
  backgroundShutdownSeconds must be below terminationGracePeriodSeconds;
- the gateway must not refuse a body that the wallet accepts: the gateway
  limit for the class (gateway.proxy.maxBodyBytes; 0 = the gateway's class
  default) must be at least the wallet limit (default >= S, large >= L).
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
config.yaml of the wallet hooks (roles, migration and read access): only
the database with the hook's login, and the log level (the migration hook
adds the audit log retention: ow.wallet.migrateConfig). database-roles,
migrate-database and read-access read only these keys. The hooks run before
the release's resources change, so they cannot read its new ConfigMaps.
Call with (list $ "<user>" "<password file name>").
*/}}
{{- define "ow.wallet.hookConfig" -}}
{{- toYaml (dict
    "log_level" ((index . 0).Values.organisationWallet.logLevel | upper)
    "database" (include "ow.wallet.database" . | fromJson)) }}
{{- end }}

{{/*
The wallet's database section (its own database in the chart) for one
login: the user and its password file name in ow.wallet.secretDir.
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
config.yaml of the wallet migration hook: ow.wallet.hookConfig plus the
audit log retention (ow.wallet.auditRetention). The partition step of
migrate-database drops the months of audit events older than the
retention, and only after a verified export. Call with (list $ "<user>"
"<password file name>").
*/}}
{{- define "ow.wallet.migrateConfig" -}}
{{- $config := include "ow.wallet.hookConfig" . | fromYaml -}}
{{- $_ := set $config "audit" (include "ow.wallet.auditRetention" (index . 0) | fromJson) -}}
{{- toYaml $config }}
{{- end }}

{{/*
Audit log retention (audit.retention_years and audit.scope_retention_years)
for the wallet files and the migration hook. Call with the root context.
Output: JSON.
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
Render guards for the audit log: bucket credentials need a bucket; s3 and
gcs values do not mix; type s3 needs its endpoint, region and access key
Secret. Call with the root context.
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
