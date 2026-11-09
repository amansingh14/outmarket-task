{{- define "ib.fullname" -}}
{{- .Release.Name | trunc 40 | trimSuffix "-" -}}
{{- end -}}

{{- define "ib.labels" -}}
app.kubernetes.io/part-of: idea-board
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/version: {{ .Values.image.tag | quote }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
{{- end -}}

{{- define "ib.selector" -}}
app.kubernetes.io/instance: {{ .root.Release.Name }}
app.kubernetes.io/component: {{ .component }}
{{- end -}}

{{- define "ib.image" -}}
{{ .root.Values.image.registry }}/{{ .root.Values.image.owner | lower }}/idea-board-{{ .component }}:{{ .root.Values.image.tag }}
{{- end -}}

{{- define "ib.dbSecretName" -}}
{{- if eq .Values.database.mode "embedded" -}}
{{ include "ib.fullname" . }}-embedded-db
{{- else -}}
{{ .Values.database.existingSecret }}
{{- end -}}
{{- end -}}
