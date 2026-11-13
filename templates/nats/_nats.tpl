{{/*
The NATS StatefulSet of this release in the cluster (lookup), or an empty
map: at an install, in "helm template" and with a tool that renders
without a cluster. Call with the root context. Output: JSON.
*/}}
{{- define "ow.nats.liveStatefulSet" -}}
{{- $root := . -}}
{{- $live := lookup "apps/v1" "StatefulSet" $root.Release.Namespace (include "ow.name" (list $root "nats")) -}}
{{- toJson ($live | default dict) -}}
{{- end }}

{{/*
"true" when the rollout of this render must give the group (fsGroup) and
the group rights to each file of the JetStream store again
(fsGroupChangePolicy Always), else "". The kubelet makes this change with
OnRootMismatch only when the top folder of the volume does not have the
group. That is not sufficient when NATS ran as root after the first
change: the files of root have the mode 0600, and the top folder has the
group already. Thus this render gives Always when the NATS StatefulSet in
the cluster:
- runs NATS as root (no runAsUser, or 0, for the container nats): a release
  before the non-root containers, or a rollback to it; or
- has a rollout that is not complete (a pod of an earlier template can
  still run as root, and the next pod of this template must change its
  files).
A later upgrade, when the rollout of Always is complete, gives
nats.podSecurityContext.fsGroupChangePolicy again (one more rolling
restart of NATS). Without a StatefulSet in the cluster (an install, or
"helm template"), it gives "". The init container store-check stops the
start of a pod whose store has a file that NATS cannot read (for example a
rollback to a revision of this chart with "helm rollback"). Call with the
root context.
*/}}
{{- define "ow.nats.repairStore" -}}
{{- $live := include "ow.nats.liveStatefulSet" . | fromJson -}}
{{- if $live -}}
{{- $spec := (($live.spec | default dict).template | default dict).spec | default dict -}}
{{- $user := ($spec.securityContext | default dict).runAsUser -}}
{{- range ($spec.containers | default list) -}}
{{- if and (eq (.name | toString) "nats") (hasKey (.securityContext | default dict) "runAsUser") -}}
{{- $user = .securityContext.runAsUser -}}
{{- end -}}
{{- end -}}
{{- $asRoot := or (kindIs "invalid" $user) (eq (int64 $user) 0) -}}
{{- $status := $live.status | default dict -}}
{{- $generation := int64 (($live.metadata | default dict).generation | default 0) -}}
{{- $replicas := int64 (($live.spec | default dict).replicas | default 1) -}}
{{- $complete := and
    (eq (int64 ($status.observedGeneration | default 0)) $generation)
    (eq (toString ($status.currentRevision | default "")) (toString ($status.updateRevision | default "none")))
    (ge (int64 ($status.updatedReplicas | default 0)) $replicas) -}}
{{- if or $asRoot (not $complete) -}}true{{- end -}}
{{- end -}}
{{- end }}

{{/*
The pod values of the NATS pods (for ow.podSpecCommon): the values of
nats, with fsGroupChangePolicy Always when this rollout must change the
files of the store again (ow.nats.repairStore). Call with (list $ <nats
values>). Output: JSON.
*/}}
{{- define "ow.nats.podValues" -}}
{{- $root := index . 0 -}}
{{- $values := deepCopy (index . 1) -}}
{{- if include "ow.nats.repairStore" $root -}}
{{- $context := deepCopy ($values.podSecurityContext | default dict) -}}
{{- $_ := set $context "fsGroupChangePolicy" "Always" -}}
{{- $_ := set $values "podSecurityContext" $context -}}
{{- end -}}
{{- toJson $values -}}
{{- end }}
