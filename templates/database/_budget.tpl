{{/*
The connection budget of the database server (docs/database.md,
"Connection budget"; WORKERS-AND-REDIS-PLAN.md item H1): the most
connections that the pools of the processes of this release can open,
with the most pods of each Deployment (the maximum of an autoscaler).
Each process: the largest number of connections of one pod
(docs/database.md, "The pools of each process"). With a pooler
(database.pooler.host), the sessions of the wallet go through it: the
wallet processes count only their connections to the server, and the
pooler counts database.pooler.serverConnections. Output: JSON {processes:
[{name, pods, each}], total}.
*/}}
{{- define "ow.db.budget" -}}
{{- $v := .Values -}}
{{- $p := $v.database.pools -}}
{{- $processes := list -}}
{{- /* The readers of the views of a service that is not installed open no
connection (ow.installation.has). */ -}}
{{- $walletViews := include "ow.installation.has" (list . "wallet") -}}
{{- $consentViews := include "ow.installation.has" (list . "consent") -}}
{{- /* The api core, the webhook handler, the gateway and consent: also one
health connection of each pod, outside the pools (a check of the database
every 2 s). */ -}}
{{- if $v.api.enabled -}}
{{- $apiReader := ternary ($p.apiReadAccess.maxConns | int) 0 (eq $walletViews "true") -}}
{{- $processes = append $processes (dict "name" "api core" "pods" ($v.api.replicas | int) "each" (add $p.api.maxConns $p.oidc.maxConns $apiReader 1)) -}}
{{- $processes = append $processes (dict "name" "webhook handler" "pods" ($v.api.webhook.replicas | int) "each" (add $p.webhook.maxConns $p.oidc.maxConns $apiReader 1)) -}}
{{- $processes = append $processes (dict "name" "gateway" "pods" ($v.gateway.replicas | int) "each" (add $p.gateway.maxConns 1)) -}}
{{- end -}}
{{- if $v.consent.enabled -}}
{{- /* consent: its pool and its readers (the api views, and the wallet
views when the wallet is installed) of 5 each. */ -}}
{{- $processes = append $processes (dict "name" "consent" "pods" ($v.consent.replicas | int) "each" (add $p.consent.maxConns (ternary 10 5 (eq $walletViews "true")) 1)) -}}
{{- end -}}
{{- if $v.organisationWallet.enabled -}}
{{- $w := $v.organisationWallet -}}
{{- $pooled := not (empty $v.database.pooler.host) -}}
{{- /* service and config: the session pool, the allocation pool and the
synchronous engine (one at a time); config also its readers (the api
views, and the consent views when consent is installed) of 10 each and one
WIA pool mint (the route of the wallet unit attestation holds its lock on
a connection of its own). */ -}}
{{- $s := $p.walletService -}}
{{- $servicePods := $w.service.replicas | int -}}
{{- if ($w.service.autoscaling | default dict).enabled -}}{{- $servicePods = $w.service.autoscaling.maxReplicas | int -}}{{- end -}}
{{- $sessions := ternary 0 (add $s.poolSize $s.maxOverflow 1) $pooled -}}
{{- $processes = append $processes (dict "name" "wallet service" "pods" $servicePods "each" (add $sessions $s.allocationPoolSize)) -}}
{{- $c := $p.walletConfig -}}
{{- $sessions = ternary 0 (add $c.poolSize $c.maxOverflow 1) $pooled -}}
{{- $processes = append $processes (dict "name" "wallet config" "pods" ($w.config.replicas | int) "each" (add $sessions $c.allocationPoolSize (ternary 20 10 (eq $consentViews "true")) 1)) -}}
{{- /* a worker process: one session for each thread, maxOverflow, the
allocation pool, at most 2 lock connections for each thread and the
synchronous engine; a pod: its processes and its health server. */ -}}
{{- $k := $p.walletWorker -}}
{{- range $g := $w.workers.groups -}}
{{- $threads := $g.threads | int -}}
{{- $process := add $k.allocationPoolSize (mul 2 $threads) -}}
{{- if not $pooled -}}{{- $process = add $process $threads $k.maxOverflow 1 -}}{{- end -}}
{{- $pods := $g.replicas | int -}}
{{- $keda := (($g.autoscaling | default dict).keda | default dict) -}}
{{- if $keda.enabled -}}{{- $pods = $keda.maxReplicaCount | int -}}{{- end -}}
{{- $processes = append $processes (dict "name" (printf "workers %s" $g.name) "pods" $pods "each" (add (mul ($g.processes | int) $process) 1)) -}}
{{- end -}}
{{- /* the clock: the leader connection and its health server. */ -}}
{{- $processes = append $processes (dict "name" "clock" "pods" ($w.clock.replicas | int) "each" 2) -}}
{{- if $pooled -}}
{{- $processes = append $processes (dict "name" "connection pooler" "pods" 1 "each" ($v.database.pooler.serverConnections | int)) -}}
{{- end -}}
{{- end -}}
{{- $total := 0 -}}
{{- range $process := $processes -}}
{{- $total = add $total (mul $process.pods $process.each) -}}
{{- end -}}
{{- toJson (dict "processes" $processes "total" $total) -}}
{{- end }}

{{/*
The connections that the release keeps free on the database server: the
hook Jobs of an install or an upgrade (the migration, the roles step and
the read access steps, one after the other: at most 5 at a time).
*/}}
{{- define "ow.db.budgetReserve" -}}
5
{{- end }}

{{/*
Render guard of the bundled server: the pools of the release and the
reserve of the hooks must fit in max_connections less the connections of
the superuser (superuser_reserved_connections, default 3) and
reserved_connections (default 0) of database.postgresql.parameters.
Call with the root context.
*/}}
{{- define "ow.db.checkBudget" -}}
{{- $pooler := .Values.database.pooler -}}
{{- if and $pooler.host (lt ($pooler.serverConnections | int) 1) -}}
{{- fail "database.pooler.serverConnections is required with database.pooler.host and the bundled server: the most connections that the pooler opens to the server for the wallet database (the connection budget counts them)" -}}
{{- end -}}
{{- $parameters := .Values.database.postgresql.parameters | default dict -}}
{{- $max := (index $parameters "max_connections" | default "100") | int -}}
{{- $reserved := add ((index $parameters "superuser_reserved_connections" | default "3") | int) ((index $parameters "reserved_connections" | default "0") | int) -}}
{{- $budget := include "ow.db.budget" . | fromJson -}}
{{- $need := add ($budget.total | int) (include "ow.db.budgetReserve" . | int) -}}
{{- if gt $need (sub $max $reserved | int) -}}
{{- $parts := list -}}
{{- range $process := $budget.processes -}}
{{- $parts = append $parts (printf "%s %v x %v" $process.name $process.pods $process.each) -}}
{{- end -}}
{{- fail (printf "the pools of the release can open %v connections to the bundled database server (%s), and the hooks need %v more: %v, more than database.postgresql.parameters.max_connections (%v) less the %v reserved connections. Lower database.pools or the replicas, or raise max_connections and database.resources together (docs/database.md, \"Connection budget\")" ($budget.total | int) (join ", " $parts) (include "ow.db.budgetReserve" . | int) $need $max $reserved) -}}
{{- end -}}
{{- end }}
