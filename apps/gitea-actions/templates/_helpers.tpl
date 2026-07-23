{{- define "gitea-actions.labels" -}}
app.kubernetes.io/name: gitea-actions
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: homeserver
{{- end }}
