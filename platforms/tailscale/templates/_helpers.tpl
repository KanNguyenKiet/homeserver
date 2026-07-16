{{- define "tailscale-platform.labels" -}}
app.kubernetes.io/name: tailscale
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: homeserver
{{- end }}
