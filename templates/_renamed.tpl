{{/*
The stop for changed values (docs/upgrade.md). The table
files/renamed-values.yaml has one entry for each value that changed in a
release; scripts/upgrade-values.py writes a new values file from the same
table. The render (helm template, install, upgrade, lint) stops with one
message that lists every old value of your values files, never only the
first. The chart never reads an old value as the new one.

Each entry has:
- old: the path of the old value;
- after: the release after which the value changed;
- new: the new path (or a list of paths) of the same value; or
- removed: why the value is not a value any more; or
- shape: what to do, when the value has a new shape (for example a plain
  password that is now a Secret reference);
- kind (optional): the type of the old value (string, bool, slice, map,
  float64). The path stays, so only an old value of this type stops;
- values (optional): old value -> new value. Only these old values stop;
- note (optional): more words for the message;
- convert, secret (optional): for scripts/upgrade-values.py only.

values.schema.json keeps each old path (deprecated, any type) for two
releases after the change, so that the schema does not stop the render
first with a general message. Call with the root context. Output: nothing.
*/}}
{{- define "ow.renamedValues.check" -}}
{{- $table := .Files.Get "files/renamed-values.yaml" | fromYamlArray -}}
{{- $lines := list -}}
{{- $releases := list -}}
{{- range $entry := $table -}}
{{- $node := $.Values -}}
{{- $found := true -}}
{{- range $part := splitList "." $entry.old -}}
{{- if and $found (kindIs "map" $node) (hasKey $node $part) -}}
{{- $node = index $node $part -}}
{{- else -}}
{{- $found = false -}}
{{- end -}}
{{- end -}}
{{- if and $found $entry.kind -}}
{{- $found = kindIs $entry.kind $node -}}
{{- end -}}
{{- if and $found $entry.values -}}
{{- $found = hasKey $entry.values (toString $node) -}}
{{- end -}}
{{- if $found -}}
{{- $text := "" -}}
{{- if $entry.new -}}
{{- $text = printf "use %s" (join " and " $entry.new) -}}
{{- else if $entry.removed -}}
{{- $text = printf "remove it (%s)" $entry.removed -}}
{{- else -}}
{{- $text = $entry.shape -}}
{{- end -}}
{{- if $entry.values -}}
{{- $text = printf "%s (%s is now %s)" $text (toString $node) (get $entry.values (toString $node)) -}}
{{- end -}}
{{- with $entry.note -}}
{{- $text = printf "%s (%s)" $text . -}}
{{- end -}}
{{- $lines = append $lines (printf "- %s: %s" $entry.old $text) -}}
{{- $releases = append $releases (toString $entry.after) -}}
{{- end -}}
{{- end -}}
{{- if $lines -}}
{{- $releases = $releases | uniq | sortAlpha -}}
{{- $sections := list -}}
{{- range $release := $releases -}}
{{- $sections = append $sections (printf "\"From %s\"" $release) -}}
{{- end -}}
{{- fail (printf "%d %s of your values files changed after release %s (docs/upgrade.md, section %s):\n%s\nRun scripts/upgrade-values.py <your values file> to write the new file, or change the values by hand." (len $lines) (ternary "value" "values" (eq (len $lines) 1)) (join " and " $releases) (join " and " $sections) (join "\n" $lines)) -}}
{{- end -}}
{{- end }}
