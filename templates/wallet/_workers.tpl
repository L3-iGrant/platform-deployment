{{/*
Helpers of the workers and of the clock of the organisation wallet
(docs/workers.md). A worker group of organisationWallet.workers.groups is
one Deployment of "dramatiq ows.worker.run:start" for some of the queues;
the clock is one Deployment of start-clock.
*/}}

{{/* The queues of the worker kit of the wallet (ows.kit.worker.actor.QUEUES). Output: comma-separated. */}}
{{- define "ow.wallet.workerQueues" -}}
realtime,attestation,status,kms,maintenance
{{- end }}

{{/* The port of the Prometheus metrics of a server pod (server.metrics_port): /metrics only. */}}
{{- define "ow.wallet.serverMetricsPort" -}}
9190
{{- end }}

{{/*
The folder of the metrics files of the processes of a server pod
(server.metrics_directory): an emptyDir in memory.
*/}}
{{- define "ow.wallet.serverMetricsDir" -}}
/run/ows-server
{{- end }}

{{/* The port of the health server of a worker pod (worker.health_port): /healthz, /readyz and /metrics. */}}
{{- define "ow.wallet.workerHealthPort" -}}
9191
{{- end }}

{{/* The port of the health server of a clock pod (clock.health_port). */}}
{{- define "ow.wallet.clockHealthPort" -}}
9192
{{- end }}

{{/*
The folder of the heartbeat and metric files of the worker processes of a
pod (worker.state_directory): an emptyDir in memory.
*/}}
{{- define "ow.wallet.workerStateDir" -}}
/run/ows-worker
{{- end }}

{{/* The component (and the name suffix) of the Deployment of one worker group. Call with the group. */}}
{{- define "ow.wallet.workerComponent" -}}
wallet-worker-{{ .name }}
{{- end }}

{{/*
Render guards of the worker groups (organisationWallet.workers.groups),
also without the schema:
- a name: lower-case letters, digits and -; each name once (not in the
  schema); a Deployment name of at most 63 characters (not in the schema:
  ow.name cuts a longer name, so two groups could get one name);
- the queues of a group: queues of the kit, each once;
- replicas, processes and threads: 1 or more;
- a stop: terminationGracePeriodSeconds at least shutdownTimeoutSeconds +
  30 (not in the schema), else Kubernetes kills the worker while it waits
  for its actors;
- together the groups run every queue of the kit (not in the schema): the
  messages of a queue that no group runs stay in Valkey and grow.
Call with the root context. Output: nothing.
*/}}
{{- define "ow.wallet.checkWorkers" -}}
{{- $groups := .Values.organisationWallet.workers.groups | default list -}}
{{- $kit := include "ow.wallet.workerQueues" . | splitList "," -}}
{{- $names := list -}}
{{- $served := list -}}
{{- range $i, $g := $groups -}}
{{- $key := printf "organisationWallet.workers.groups[%d]" $i -}}
{{- if not (regexMatch "^[a-z0-9]([-a-z0-9]*[a-z0-9])?$" ($g.name | default "")) -}}
{{- fail (printf "%s.name %q is not a name: lower-case letters, digits and -, not - at the start or at the end" $key ($g.name | default "")) -}}
{{- end -}}
{{- if has $g.name $names -}}
{{- fail (printf "%s.name %q is the name of another group: each group has its own Deployment" $key $g.name) -}}
{{- end -}}
{{- $names = append $names $g.name -}}
{{- $deployment := printf "%s-%s" (include "ow.fullname" $) (include "ow.wallet.workerComponent" $g) -}}
{{- if gt (len $deployment) 63 -}}
{{- fail (printf "%s.name %q gives the Deployment name %s (%d characters): a name has at most 63 characters; use a shorter group name or fullnameOverride" $key $g.name $deployment (len $deployment)) -}}
{{- end -}}
{{- if not $g.queues -}}
{{- fail (printf "%s.queues is empty: give the queues of the group (%s)" $key (join ", " $kit)) -}}
{{- end -}}
{{- range $queue := $g.queues -}}
{{- if not (has $queue $kit) -}}
{{- fail (printf "%s.queues: %q is not a queue of the wallet (%s)" $key $queue (join ", " $kit)) -}}
{{- end -}}
{{- end -}}
{{- if ne (len $g.queues) (len (uniq $g.queues)) -}}
{{- fail (printf "%s.queues names a queue two times" $key) -}}
{{- end -}}
{{- $served = concat $served $g.queues -}}
{{- range $value := list "replicas" "processes" "threads" -}}
{{- if lt (index $g $value | int) 1 -}}
{{- fail (printf "%s.%s (%v) must be 1 or more" $key $value (index $g $value)) -}}
{{- end -}}
{{- end -}}
{{- $shutdown := $g.shutdownTimeoutSeconds | int -}}
{{- if lt $shutdown 1 -}}
{{- fail (printf "%s.shutdownTimeoutSeconds (%v) must be 1 or more" $key $g.shutdownTimeoutSeconds) -}}
{{- end -}}
{{- if lt ($g.terminationGracePeriodSeconds | int) (add $shutdown 30) -}}
{{- fail (printf "%s.terminationGracePeriodSeconds (%v) must be at least shutdownTimeoutSeconds (%v) + 30: Kubernetes would kill the worker while it waits for its running actors" $key $g.terminationGracePeriodSeconds $g.shutdownTimeoutSeconds) -}}
{{- end -}}
{{- end -}}
{{- $missing := list -}}
{{- range $queue := $kit -}}
{{- if not (has $queue $served) -}}{{- $missing = append $missing $queue -}}{{- end -}}
{{- end -}}
{{- if $missing -}}
{{- fail (printf "organisationWallet.workers.groups: no group runs the queue %s: its messages would stay in Valkey; each queue of the wallet needs a group (%s)" (join ", " $missing) (join ", " $kit)) -}}
{{- end -}}
{{- end }}
