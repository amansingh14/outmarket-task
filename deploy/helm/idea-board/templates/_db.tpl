{{- define "ib.appUser" -}}
{{- default (printf "%s_app" .Values.database.name) .Values.database.appUser -}}
{{- end -}}

{{/* Secret holding the app's DATABASE_URL (least-privilege login, or the embedded DB). */}}
{{- define "ib.dbSecretName" -}}
{{- if eq .Values.database.mode "embedded" -}}
{{ include "ib.fullname" . }}-embedded-db
{{- else -}}
{{ include "ib.fullname" . }}-db
{{- end -}}
{{- end -}}

{{- define "ib.validateDb" -}}
{{- range $label, $v := dict "database.name" .Values.database.name "database.appUser" (include "ib.appUser" .) -}}
{{- if not (regexMatch "^[a-z_][a-z0-9_]{0,62}$" $v) -}}
{{- fail (printf "%s %q is not a valid identifier" $label $v) -}}
{{- end -}}
{{- end -}}
{{- if and (eq .Values.database.mode "external") (not .Values.database.host) -}}
{{- fail "database.host is required in external mode (set by scripts/deploy.sh from Terraform outputs)" -}}
{{- end -}}
{{- end -}}
