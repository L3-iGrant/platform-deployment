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
A ControllerRevision of this release in the cluster (lookup), or an empty
map. Call with (list $ <name>). Output: JSON.
*/}}
{{- define "ow.nats.liveRevision" -}}
{{- $root := index . 0 -}}
{{- $revision := lookup "apps/v1" "ControllerRevision" $root.Release.Namespace (index . 1) -}}
{{- toJson ($revision | default dict) -}}
{{- end }}

{{/*
"true" when a pod template spec (a dict) runs the container nats as root:
no runAsUser, or 0 (the container value over the pod value). Call with the
spec. Output: "true" or "".
*/}}
{{- define "ow.nats.specRunsAsRoot" -}}
{{- $spec := . | default dict -}}
{{- $user := ($spec.securityContext | default dict).runAsUser -}}
{{- range ($spec.containers | default list) -}}
{{- if and (eq (.name | toString) "nats") (hasKey (.securityContext | default dict) "runAsUser") -}}
{{- $user = .securityContext.runAsUser -}}
{{- end -}}
{{- end -}}
{{- if or (kindIs "invalid" $user) (eq (int64 $user) 0) -}}true{{- end -}}
{{- end }}

{{/*
"true" when the rollout of this render must give the group (fsGroup) and
the group rights to each file of the JetStream store again
(fsGroupChangePolicy Always), else "". The kubelet makes this change with
OnRootMismatch only when the top folder of the volume does not have the
group. That is not sufficient when NATS ran as root after the first
change: the files of root have the mode 0600, and the top folder has the
group already. Thus this render gives Always only when NATS runs or can
still run as root:
- the template of the NATS StatefulSet in the cluster runs NATS as root (a
  release before the non-root containers, or a rollback to it); or
- its rollout is not complete, and the pods of the current revision (the
  ControllerRevision of status.currentRevision, the pods that the rollout
  has not replaced yet) run NATS as root. Without that ControllerRevision
  (it cannot be read), the render gives Always (the safe side).
A rollout that is not complete with pods that do not run as root (for
example an upgrade some seconds after an upgrade) gives no Always: an
Always would walk the ownership of the whole store at each pod start and
cost two more rollouts of NATS. A later upgrade, when the rollout of Always
is complete, gives nats.podSecurityContext.fsGroupChangePolicy again (one
more rolling restart of NATS). Without a StatefulSet in the cluster (an
install, or "helm template"), it gives "". The init container store-check
stops the start of a pod whose store has a file that NATS cannot read (for
example a rollback to a revision of this chart with "helm rollback"). Call
with the root context.
*/}}
{{- define "ow.nats.repairStore" -}}
{{- $live := include "ow.nats.liveStatefulSet" . | fromJson -}}
{{- if $live -}}
{{- $spec := (($live.spec | default dict).template | default dict).spec | default dict -}}
{{- $status := $live.status | default dict -}}
{{- $generation := int64 (($live.metadata | default dict).generation | default 0) -}}
{{- $replicas := int64 (($live.spec | default dict).replicas | default 1) -}}
{{- $complete := and
    (eq (int64 ($status.observedGeneration | default 0)) $generation)
    (eq (toString ($status.currentRevision | default "")) (toString ($status.updateRevision | default "none")))
    (ge (int64 ($status.updatedReplicas | default 0)) $replicas) -}}
{{- if include "ow.nats.specRunsAsRoot" $spec -}}
true
{{- else if not $complete -}}
{{- $name := toString ($status.currentRevision | default "") -}}
{{- $current := dict -}}
{{- if $name -}}{{- $current = include "ow.nats.liveRevision" (list . $name) | fromJson -}}{{- end -}}
{{- if not $current.data -}}
true
{{- else if include "ow.nats.specRunsAsRoot" (((($current.data | default dict).spec | default dict).template | default dict).spec | default dict) -}}
true
{{- end -}}
{{- end -}}
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
