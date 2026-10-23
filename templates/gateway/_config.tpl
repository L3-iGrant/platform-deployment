{{/*
config.yaml of the auth gateway: its own file, not the api config. The
sections that the gateway shares with the api have the same keys and values
as api.yaml: ClientAddress comes from clientAddress, and IndividualAuth,
Cors and OutboundHttp come from api.extraConfig, so the gateway and the api
core apply the same rules. An unknown key stops the
gateway, and the gateway reads every <Name>File at start: the file names only
the secrets of the gateway (ow.gateway.secretFiles), not the token signing
keys of the api. The file has no secret. The gateway decides every request,
counts the rate limits and writes the action log; it resolves the client
address with ClientAddress and sends it in the token (claim cip). It sends
the consent routes to the consent service, the wallet config routes to the
wallet config role and all other routes to the api core.
*/}}
{{- define "ow.gateway.config" -}}
{{- $root := . -}}
{{- $v := .Values -}}
{{- $api := $v.api -}}
{{- $g := $v.gateway -}}
{{- $dir := include "ow.gateway.secretDir" . -}}
{{- $coreUrl := $g.upstreams.core.url | default (printf "http://%s.%s.svc:80" (include "ow.name" (list $root "api")) $root.Release.Namespace) -}}
{{- $consentUrl := $g.upstreams.consent.url -}}
{{- if and (not $consentUrl) $v.consent.enabled -}}
{{- $consentUrl = printf "http://%s.%s.svc:80" (include "ow.name" (list $root "consent")) $root.Release.Namespace -}}
{{- end -}}
{{- $consentUrl = required "gateway.upstreams.consent.url is required when consent.enabled is false: the gateway sends the consent routes to the consent service" $consentUrl -}}
{{- $walletConfigUrl := $g.upstreams.walletConfig.url -}}
{{- if and (not $walletConfigUrl) $v.organisationWallet.enabled -}}
{{- $walletConfigUrl = printf "http://%s.%s.svc:80" (include "ow.name" (list $root "wallet-config")) $root.Release.Namespace -}}
{{- end -}}
{{- $walletConfigUrl = required "gateway.upstreams.walletConfig.url is required when organisationWallet.enabled is false: the gateway sends the wallet config routes to the wallet config role" $walletConfigUrl -}}
{{- /* The file body limit of the gateway must not refuse an image that the
api accepts (ImageUpload.maxBytes + 64 KiB of multipart framing), else the
client gets the 413 of the gateway with another text. 0 = the defaults
(5 MiB + 64 KiB and 5 MiB). */ -}}
{{- $imageMax := (dig "ImageUpload" "maxBytes" 0 ($api.extraConfig | default dict)) | int64 | default 5242880 -}}
{{- $fileLimit := $g.proxy.maxBodyBytes.file | int64 | default (add 5242880 65536) -}}
{{- if lt $fileLimit (add $imageMax 65536) -}}
{{- fail (printf "gateway.proxy.maxBodyBytes.file (%v) must be at least the api ImageUpload.maxBytes (%v) + 65536: the gateway would refuse an image that the api accepts" $fileLimit $imageMax) -}}
{{- end -}}
{{- $config := dict
  "ApplicationMode" "multi-tenant"
  "ApiBaseUrl" (include "ow.publicUrlOf" (list $root "api"))
  "ApiSecretKeyFile" (printf "%s/api-secret-key" $dir)
  "DataBase" (include "ow.db.goOwner" (dict "root" $root "db" "api" "secretDir" $dir "passwordFile" "db-password" "pool" $v.database.pools.gateway) | fromJson)
  "KeyStorage" (dict
    "tokenHashSecretFile" (printf "%s/token-hash-secret.json" $dir)
    "tokenVerificationJwksFile" (printf "%s/token-verification-jwks.json" (include "ow.gateway.configPath" $root | dir))
    "allowPlainApiKeys" false)
  "ClientAddress" (include "ow.clientAddress" $root | fromJson)
  "Log" (dict "level" ($g.logLevel | default $api.logLevel))
  "Gateway" (dict
    "listenPort" ($g.listenPort | int)
    "drainSeconds" ($g.drainSeconds | int)
    "gracefulShutdownSeconds" ($g.gracefulShutdownSeconds | int)
    "upstreams" (dict
      "core" (dict "url" $coreUrl)
      "consent" (dict
        "url" $consentUrl
        "requestTimeoutSeconds" ($g.upstreams.consent.requestTimeoutSeconds | int))
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
{{- $shared := pick ($api.extraConfig | default dict) "IndividualAuth" "Cors" "OutboundHttp" -}}
{{- $config = mustMergeOverwrite $config (deepCopy $shared) -}}
{{- mustMergeOverwrite $config (deepCopy ($g.extraConfig | default dict)) | toYaml -}}
{{- end }}
