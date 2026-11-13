{{/*
NetworkPolicy helpers. The rules come from policies/network-matrix.yaml;
the platform data (Ingress controller and DNS selectors, external databases
and NATS, egress profiles) comes from networkPolicy.*.
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
Network labels of one pod template: the role, plus one label per egress
profile (networkPolicy.egress.roles.<role> and the profiles passed in).
They are always rendered, so turning the policies on restarts no pods. The
render fails when the matrix does not allow a profile for the role.
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
Roles that run in this release (the chart's pods). Output: JSON list.
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
Port number or name of one connection in the matrix. The database port is
the database.engine port (a number, so it does not depend on the server's
container port name). Call with (list $ "<role>" "<port name>"). Output:
the port.
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
Peer for an external source or destination (ingressController, monitoring,
dns, nats) from its values: namespaceSelector and podSelector (empty means
all). Call with the values dict. Output: one list item at column 0.
*/}}
{{- define "ow.netpol.selectorPeer" -}}
{{- toYaml (list (dict "namespaceSelector" (.namespaceSelector | default dict) "podSelector" (.podSelector | default dict))) -}}
{{- end }}

{{/*
The except list for an ipBlock that covers a whole address family
(0.0.0.0/0 or ::/0, as in a public internet egress profile): the profile's
except entries plus networkPolicy.clusterCidrs, limited to that family (an
IPv6 entry has a colon). Kubernetes rejects an except outside its cidr.
Other cidrs get no except. Call with (list <cidr> <except list> <cluster
cidrs>). Output: JSON list.
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
