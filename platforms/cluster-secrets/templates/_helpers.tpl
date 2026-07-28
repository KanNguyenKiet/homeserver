{{- define "cluster-secrets.labels" -}}
app.kubernetes.io/name: cluster-secrets
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: homeserver
{{- end }}

{{- define "cluster-secrets.dockerconfigjson" -}}
{{`{{ printf "{\"auths\":{\"`}}{{ .Values.registry.host }}{{`\":{\"username\":\"%s\",\"password\":\"%s\",\"auth\":\"%s\"}}}" .registryUsername .registryPassword (printf "%s:%s" .registryUsername .registryPassword | b64enc) }}`}}
{{- end }}
