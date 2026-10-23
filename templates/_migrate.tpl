{{/*
Migration hook of one owner service (helm pre-upgrade): the schema migrations of the owner (with
the views of the read-only users) and its backfills run to the end BEFORE any
Deployment of the release changes. So a new reader never starts before the
views and rows that it reads exist. A failed hook stops the upgrade: the old
pods stay. The hook runs at each upgrade; the commands are idempotent.

A new installation has no hook (no old data, and the bundled database server
does not exist yet when a pre-install hook runs): each owner migrates when its pod
starts, and the /readyz of each reader checks that the views that it reads
exist, so a reader gets no traffic before the owner has migrated.

The hook has its own configuration file with only the database (a
pre-upgrade hook cannot read the new ConfigMaps of the release) and only the
database passwords.

A service can also run the same command after the upgrade (hook
"post-upgrade"): consent writes the read model of the revisions that a pod
of the earlier release wrote during the rolling update.

Call with (dict
  "root" $
  "hook" "pre-upgrade"|"post-upgrade"    optional; default pre-upgrade
  "component" "<name suffix>"            the ConfigMap and the Job
  "values" <service values>              image, podSecurityContext, containerSecurityContext, ...
  "jobs" <jobs values>                   ttlSecondsAfterFinished, resources, podSecurityContext, containerSecurityContext (empty: the service values)
  "configPath" "<file in the pod>"
  "config" "<YAML text>"
  "env" (list ...)                       optional container environment
  "steps" (list (dict "name" "<container>" "command" (list ...) "args" (list ...)) ...)
                                         the last step is the container, the others are init containers, in this order
  "secrets" (list (dict "secret" "<Secret>" "key" "<key>" "path" "<file>") ...)
  "secretDir" "<folder of the secret files>").
*/}}
{{- define "ow.migrateHook" -}}
{{- $root := .root -}}
{{- $name := include "ow.name" (list $root .component) -}}
{{- $jobs := .jobs | default dict -}}
{{- $jobPod := deepCopy .values -}}
{{- $_ := set $jobPod "podSecurityContext" ($jobs.podSecurityContext | default .values.podSecurityContext) -}}
{{- $_ := set $jobPod "containerSecurityContext" ($jobs.containerSecurityContext | default .values.containerSecurityContext) -}}
{{- $steps := .steps -}}
{{- $hook := . -}}
{{- $when := .hook | default "pre-upgrade" -}}
{{- if not (has $when (list "pre-upgrade" "post-upgrade")) -}}
{{- fail (printf "ow.migrateHook: hook %q must be pre-upgrade or post-upgrade" $when) -}}
{{- end -}}
apiVersion: v1
kind: ConfigMap
metadata:
  name: {{ $name }}
  namespace: {{ $root.Release.Namespace }}
  labels:
    {{- include "ow.labels" (list $root .component) | nindent 4 }}
  annotations:
    helm.sh/hook: {{ $when }}
    helm.sh/hook-weight: "-10"
    helm.sh/hook-delete-policy: before-hook-creation
data:
  {{ base .configPath }}: |
    {{- .config | nindent 4 }}
---
apiVersion: batch/v1
kind: Job
metadata:
  name: {{ $name }}
  namespace: {{ $root.Release.Namespace }}
  labels:
    {{- include "ow.labels" (list $root .component) | nindent 4 }}
  annotations:
    helm.sh/hook: {{ $when }}
    helm.sh/hook-weight: "-5"
    helm.sh/hook-delete-policy: before-hook-creation
spec:
  backoffLimit: 1
  ttlSecondsAfterFinished: {{ $jobs.ttlSecondsAfterFinished | default 86400 }}
  template:
    metadata:
      labels:
        {{- include "ow.labels" (list $root .component) | nindent 8 }}
        {{- include "ow.netpol.labels" (list $root "job" list) | nindent 8 }}
    spec:
      restartPolicy: Never
      # The Job does not call the Kubernetes API.
      automountServiceAccountToken: false
      {{- include "ow.podSpecCommon" (list $root $jobPod) | nindent 6 }}
      {{- if gt (len $steps) 1 }}
      initContainers:
        {{- range $step := initial $steps }}
        {{- include "ow.migrateHook.container" (list $root $hook $jobPod $step) | nindent 8 }}
        {{- end }}
      {{- end }}
      containers:
        {{- include "ow.migrateHook.container" (list $root $hook $jobPod (last $steps)) | nindent 8 }}
      volumes:
        - name: config
          configMap:
            name: {{ $name }}
        - name: secrets
          projected:
            defaultMode: 0440
            sources:
              {{- range $file := .secrets }}
              - secret:
                  name: {{ $file.secret }}
                  items:
                    - key: {{ $file.key }}
                      path: {{ $file.path }}
              {{- end }}
        - name: tmp
          emptyDir:
            medium: Memory
            sizeLimit: 64Mi
{{- end }}

{{/*
The "secrets" list of ow.migrateHook from a file map ("<file name>" ->
{secret, key}, for example ow.db.secretFiles). Output: JSON list.
*/}}
{{- define "ow.migrateHook.secrets" -}}
{{- $out := list -}}
{{- range $path, $file := . -}}
{{- $out = append $out (dict "secret" $file.secret "key" $file.key "path" $path) -}}
{{- end -}}
{{- toJson $out -}}
{{- end }}

{{/* One container of ow.migrateHook. Call with (list $ <hook dict> <job pod values> <step>). */}}
{{- define "ow.migrateHook.container" -}}
{{- $root := index . 0 -}}
{{- $hook := index . 1 -}}
{{- $jobPod := index . 2 -}}
{{- $step := index . 3 -}}
- name: {{ $step.name }}
  image: {{ include "ow.image" (list $root $hook.values.image) }}
  imagePullPolicy: {{ include "ow.imagePullPolicy" (list $root $hook.values.image) }}
  {{- with $step.command }}
  command:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  {{- with $step.args }}
  args:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  {{- with $hook.env }}
  env:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  {{- include "ow.containerSecurityContext" (list $root $jobPod) | nindent 2 }}
  {{- with ($hook.jobs | default dict).resources }}
  resources:
    {{- toYaml . | nindent 4 }}
  {{- end }}
  volumeMounts:
    - name: config
      mountPath: {{ dir $hook.configPath }}
      readOnly: true
    - name: secrets
      mountPath: {{ $hook.secretDir }}
      readOnly: true
    - name: tmp
      mountPath: /tmp
{{- end }}
