{{- define "ib.fullname" -}}
{{- .Release.Name | trunc 40 | trimSuffix "-" -}}
{{- end -}}

{{- define "ib.labels" -}}
app.kubernetes.io/part-of: idea-board
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- with .Values.environment }}
idea-board/environment: {{ . | quote }}
{{- end }}
app.kubernetes.io/version: {{ .Values.image.tag | quote }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
{{- end -}}

{{- define "ib.selector" -}}
app.kubernetes.io/instance: {{ .root.Release.Name }}
app.kubernetes.io/component: {{ .component }}
{{- end -}}

{{/* Per-component tag (content-addressed by CI) falls back to the shared image.tag. */}}
{{- define "ib.image" -}}
{{- $cfg := index .root.Values .component -}}
{{- $tag := .root.Values.image.tag -}}
{{- if and $cfg.image $cfg.image.tag }}{{ $tag = $cfg.image.tag }}{{ end -}}
{{ .root.Values.image.registry }}/{{ .root.Values.image.owner | lower }}/idea-board-{{ .component }}:{{ $tag }}
{{- end -}}

{{- define "ib.dbSecretName" -}}
{{- if eq .Values.database.mode "embedded" -}}
{{ include "ib.fullname" . }}-embedded-db
{{- else -}}
{{ .Values.database.existingSecret }}
{{- end -}}
{{- end -}}
