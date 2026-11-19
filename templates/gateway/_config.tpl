{{/*
config.yaml of the auth gateway: its own file, not the api config.
- Sections shared with the api have the same keys and values as api.yaml:
  ClientAddress comes from clientAddress, and Cors and OutboundHttp come
  from api.extraConfig, so the gateway and the api core apply the same
  rules.
- An unknown key stops the gateway, and the gateway reads every <Name>File
  at start, so the file names only the gateway's secrets
  (ow.gateway.secretFiles), never the api token signing keys. The file
  itself holds no secrets.
- The gateway decides every request, counts the rate limits and writes the
  action log. It resolves the client address with ClientAddress and passes
  it in the token (claim cip).
- Features (the feature gate, gateway.features.enforce) is only in this
  file.
- Routing: wallet config routes go to the wallet config role, and all
  other routes to the api core.
- Installation is in this file and in the api file (ow.installation.config).
*/}}
{{- define "ow.gateway.config" -}}
{{- $root := . -}}
{{- $v := .Values -}}
{{- $api := $v.api -}}
{{- $g := $v.gateway -}}
{{- $dir := include "ow.gateway.secretDir" . -}}
{{- $coreUrl := $g.upstreams.core.url | default (printf "http://%s.%s.svc:80" (include "ow.name" (list $root "api")) $root.Release.Namespace) -}}
{{- /* Upstream for the wallet config role: its Service in this release. */ -}}
{{- $installation := include "ow.installation.config" $root | fromJson -}}
{{- $walletConfigUrl := printf "http://%s.%s.svc:80" (include "ow.name" (list $root "wallet-config")) $root.Release.Namespace -}}
{{- /* The gateway's file body limit must not refuse an image that the api
accepts (ImageUpload.maxBytes + 64 KiB of multipart framing), or the client
gets the gateway's 413 with a different text. 0 = the defaults (5 MiB +
64 KiB and 5 MiB). */ -}}
{{- $imageMax := (dig "ImageUpload" "maxBytes" 0 ($api.extraConfig | default dict)) | int64 | default 5242880 -}}
{{- $fileLimit := $g.proxy.maxBodyBytes.file | int64 | default (add 5242880 65536) -}}
{{- if lt $fileLimit (add $imageMax 65536) -}}
{{- fail (printf "gateway.proxy.maxBodyBytes.file (%v) must be at least the api ImageUpload.maxBytes (%v) + 65536: the gateway would refuse an image that the api accepts" $fileLimit $imageMax) -}}
{{- end -}}
{{- /* Feature gate: on unless gateway.features.enforce is false (a values
file without the key keeps the gateway default). */ -}}
{{- $enforce := true -}}
{{- if kindIs "bool" (dig "features" "enforce" true $g) -}}
{{- $enforce = dig "features" "enforce" true $g -}}
{{- end -}}
{{- $config := dict
  "ApiBaseUrl" (include "ow.publicUrlOf" (list $root "api"))
  "ApiSecretKeyFile" (printf "%s/api-secret-key" $dir)
  "DataBase" (include "ow.db.goOwner" (dict "root" $root "db" "api" "secretDir" $dir "passwordFile" "db-password" "pool" $v.database.pools.gateway) | fromJson)
  "KeyStorage" (dict
    "tokenHashSecretFile" (printf "%s/token-hash-secret.json" $dir)
    "tokenVerificationJwksFile" (printf "%s/token-verification-jwks.json" (include "ow.gateway.configPath" $root | dir)))
  "ClientAddress" (include "ow.clientAddress" $root | fromJson)
  "Log" (dict "level" ($g.logLevel | default $api.logLevel))
  "Features" (dict "enforce" $enforce)
  "Gateway" (dict
    "listenPort" ($g.listenPort | int)
    "drainSeconds" ($g.drainSeconds | int)
    "gracefulShutdownSeconds" ($g.gracefulShutdownSeconds | int)
    "upstreams" (dict
      "core" (dict "url" $coreUrl)
      "walletConfig" (dict
        "url" $walletConfigUrl
        "requestTimeoutSeconds" ($g.upstreams.walletConfig.requestTimeoutSeconds | int)))
    "internalToken" (dict
      "issuer" $g.internalToken.issuer
      "signingJwksFile" (printf "%s/internal-token-jwks.json" $dir)
      "activeKid" (required "gateway.internalToken.activeKid is required (the kid of the active key in the internal token JWKS)" $g.internalToken.activeKid | toString)
      "lifetimeSeconds" ($g.internalToken.lifetimeSeconds | int)
      "audiences" $g.internalToken.audiences)
    "proxy" (dict
      "dialTimeoutSeconds" ($g.proxy.dialTimeoutSeconds | int)
      "responseHeaderTimeoutSeconds" ($g.proxy.responseHeaderTimeoutSeconds | int)
      "idleConnTimeoutSeconds" ($g.proxy.idleConnTimeoutSeconds | int)
      "maxIdleConnsPerHost" ($g.proxy.maxIdleConnsPerHost | int)
      "sseIdleTimeoutSeconds" ($g.proxy.sseIdleTimeoutSeconds | int)
      "maxBodyBytes" (dict
        "default" ($g.proxy.maxBodyBytes.default | int64)
        "file" ($g.proxy.maxBodyBytes.file | int64)
        "large" ($g.proxy.maxBodyBytes.large | int64))))
-}}
{{- $_ := set $config "Installation" $installation -}}
{{- $shared := pick ($api.extraConfig | default dict) "Cors" "OutboundHttp" -}}
{{- $config = mustMergeOverwrite $config (deepCopy $shared) -}}
{{- /* gateway.extraConfig cannot set Installation (ow.installation.config). */ -}}
{{- $extra := deepCopy ($g.extraConfig | default dict) -}}
{{- $_ := unset $extra "Installation" -}}
{{- $config = mustMergeOverwrite $config $extra -}}
{{- /* No log file (ow.noLogFile): the gateway logs to stdout. */ -}}
{{- include "ow.noLogFile" (list "gateway.extraConfig" "Log.file.path" (((get $config "Log") | default dict).file | default dict).path) -}}
{{- $config | toYaml -}}
{{- end }}
