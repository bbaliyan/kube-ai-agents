{{- define "substrate-idle-suspend.fullname" -}}
{{- if contains .Chart.Name .Release.Name -}}
{{- .Release.Name | trunc 40 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name .Chart.Name | trunc 40 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}

{{- define "substrate-idle-suspend.serviceAccountName" -}}
{{- default (include "substrate-idle-suspend.fullname" .) .Values.serviceAccount.name -}}
{{- end -}}

{{- define "substrate-idle-suspend.labels" -}}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/part-of: substrate-idle-suspend
{{- end -}}

{{- define "substrate-idle-suspend.image" -}}
{{ .Values.image.repository }}@{{ .Values.image.digest }}
{{- end -}}

{{- /* One line for each actor: atespace/name. */ -}}
{{- define "substrate-idle-suspend.actors" -}}
{{- range $actor := .Values.actors -}}
{{ $actor.atespace }}/{{ $actor.name }}
{{ end -}}
{{- end -}}

{{- define "substrate-idle-suspend.prometheusUrl" -}}
{{- .Values.prometheus.url | trimSuffix "/" -}}
{{- end -}}

{{- /* Names the ConfigMap. Anything that the script reads gives a new name, so a run never mixes two versions. */ -}}
{{- define "substrate-idle-suspend.hash" -}}
{{- $inputs := dict "script" (.Files.Get "files/idle-suspend.sh") "actors" (include "substrate-idle-suspend.actors" .) "queries" .Values.queries "idleMinutes" .Values.idleMinutes "idleCpuCores" .Values.idleCpuCores "busy" .Values.busy "suspendMode" .Values.suspendMode "url" (include "substrate-idle-suspend.prometheusUrl" .) "timeout" .Values.prometheus.timeoutSeconds -}}
{{- toJson $inputs | sha256sum | trunc 10 -}}
{{- end -}}

{{- define "substrate-idle-suspend.containerSecurity" -}}
allowPrivilegeEscalation: false
readOnlyRootFilesystem: true
capabilities:
  drop: [ALL]
{{- end -}}
