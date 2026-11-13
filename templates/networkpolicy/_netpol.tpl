{{/*
NetworkPolicy helpers. The rules come from
policies/network-matrix.yaml; the platform data (the selectors of the Ingress controller and
of DNS, external databases and NATS, the egress profiles) comes from
networkPolicy.*.
*/}}

{{/* The connection matrix (policies/network-matrix.yaml) as a dict. */}}
{{- define "ow.netpol.matrix" -}}
{{- $raw := .Files.Get "policies/network-matrix.yaml" -}}
{{- if not $raw -}}
{{- fail "policies/network-matrix.yaml is missing from the chart" -}}
{{- end -}}
{{- $raw -}}
{{- end }}

{{/*
The network labels of one pod template: the role and one label per egress
profile (networkPolicy.egress.roles.<role>, plus the profiles of the call).
They are rendered always, so turning the policies on restarts no pod. The
render stops when the matrix does not allow a profile for the role.
Call with (list $ "<role>" (list "<profile>" ...)). Output: label lines at
column 0.
*/}}
{{- define "ow.netpol.labels" -}}
{{- $root := index . 0 -}}
{{- $role := index . 1 -}}
{{- $extra := index . 2 | default list -}}
{{- $matrix := include "ow.netpol.matrix" $root | fromYaml -}}
{{- if not (hasKey $matrix.roles $role) -}}
{{- fail (printf "network role %q is not in policies/network-matrix.yaml" $role) -}}
{{- end -}}
{{- range $key, $_ := $root.Values.networkPolicy.egress.roles -}}
{{- if not (hasKey $matrix.roles $key) -}}
{{- fail (printf "networkPolicy.egress.roles.%s: %q is not a network role of policies/network-matrix.yaml (the wallet has no scheduler any more: remove wallet-scheduler)" $key $key) -}}
{{- end -}}
{{- end -}}
{{- $profiles := concat (index $root.Values.networkPolicy.egress.roles $role | default list) $extra | uniq -}}
netpol.igrant.io/role: {{ $role }}
{{- range $profile := $profiles }}
{{- $allowed := (index $matrix.profiles $profile | default dict).roles | default list }}
{{- if not (has $role $allowed) }}
{{- fail (printf "the egress profile %q is not allowed for the network role %q (policies/network-matrix.yaml profiles.%s.roles)" $profile $role $profile) }}
{{- end }}
netpol.igrant.io/egress-{{ $profile }}: "true"
{{- end }}
{{- end }}

{{/*
The roles that run in this release (the pods of the chart). Output: JSON
list.
*/}}
{{- define "ow.netpol.presentRoles" -}}
{{- $v := .Values -}}
{{- $roles := list "job" -}}
{{- if $v.api.enabled -}}{{- $roles = concat $roles (list "gateway" "api" "webhook") -}}{{- end -}}
{{- if $v.consent.enabled -}}{{- $roles = append $roles "consent" -}}{{- end -}}
{{- if $v.organisationWallet.enabled -}}{{- $roles = concat $roles (list "wallet-service" "wallet-config" "wallet-worker" "wallet-clock") -}}{{- end -}}
{{- if $v.enterpriseDashboard.enabled -}}{{- $roles = append $roles "dashboard" -}}{{- end -}}
{{- if include "ow.db.bundled" . -}}{{- $roles = append $roles "db" -}}{{- end -}}
{{- if $v.nats.enabled -}}{{- $roles = append $roles "nats" -}}{{- end -}}
{{- if include "ow.openbao.bundled" . -}}{{- $roles = append $roles "openbao" -}}{{- end -}}
{{- if include "ow.redis.bundled" . -}}{{- $roles = append $roles "redis" -}}{{- end -}}
{{- toJson $roles -}}
{{- end }}

{{/*
The port number or name of one connection of the matrix: the database port
is the port of database.engine (a number, so it does not depend on the
container port name of the server). Call with (list $ "<role>" "<port
name>"). Output: the port.
*/}}
{{- define "ow.netpol.port" -}}
{{- $root := index . 0 -}}
{{- if and (eq (index . 1) "db") (eq (index . 2) "database") -}}
{{ include "ow.db.defaultPort" $root }}
{{- else -}}
{{ index . 2 }}
{{- end -}}
{{- end }}

{{/*
The peer of an external source or destination (ingressController,
monitoring, dns, nats) from its values: namespaceSelector and podSelector
(empty: all). Call with the values dict. Output: one list item at column 0.
*/}}
{{- define "ow.netpol.selectorPeer" -}}
{{- toYaml (list (dict "namespaceSelector" (.namespaceSelector | default dict) "podSelector" (.podSelector | default dict))) -}}
{{- end }}

{{/*
The except list of an ipBlock of all addresses of one family (0.0.0.0/0 or
::/0; an egress profile of the public internet): the entries of the except
list of the profile and of networkPolicy.clusterCidrs of the same family (an
IPv6 entry has a colon). Kubernetes refuses an except outside its cidr. Other
cidrs get no except. Call with (list <cidr> <except list> <cluster cidrs>).
Output: JSON list.
*/}}
{{- define "ow.netpol.anyExcept" -}}
{{- $cidr := index . 0 -}}
{{- $except := list -}}
{{- if or (eq $cidr "0.0.0.0/0") (eq $cidr "::/0") -}}
{{- $v6 := contains ":" $cidr -}}
{{- range $entry := concat (index . 1) (index . 2) | uniq -}}
{{- if eq $v6 (contains ":" $entry) -}}{{- $except = append $except $entry -}}{{- end -}}
{{- end -}}
{{- end -}}
{{- toJson $except -}}
{{- end }}
