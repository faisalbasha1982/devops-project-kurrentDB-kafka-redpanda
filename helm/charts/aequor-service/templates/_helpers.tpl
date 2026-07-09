{{/*
Resource base name: aequor-<service> (e.g. aequor-settlement). Kept stable across
releases so metrics/ServiceMonitor selectors don't churn.
*/}}
{{- define "aequor-service.name" -}}
{{- printf "aequor-%s" .Values.service | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "aequor-service.fullname" -}}
{{- include "aequor-service.name" . -}}
{{- end -}}

{{/*
Fully-qualified image reference: <registry>/aequor-<service>:<tag>.
Empty tag falls back to the chart appVersion.
*/}}
{{- define "aequor-service.image" -}}
{{- $tag := .Values.image.tag | default .Chart.AppVersion -}}
{{- printf "%s/aequor-%s:%s" .Values.image.registry .Values.service $tag -}}
{{- end -}}

{{/*
ServiceAccount name: explicit override, else aequor-<service>.
*/}}
{{- define "aequor-service.serviceAccountName" -}}
{{- if .Values.serviceAccount.name -}}
{{- .Values.serviceAccount.name -}}
{{- else -}}
{{- include "aequor-service.name" . -}}
{{- end -}}
{{- end -}}

{{/*
Common labels (Helm + Kubernetes recommended set).
*/}}
{{- define "aequor-service.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
app.kubernetes.io/name: {{ include "aequor-service.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: aequor
app.kubernetes.io/component: {{ .Values.service }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
{{- end -}}

{{/*
Selector labels (stable subset used by Service + ServiceMonitor).
*/}}
{{- define "aequor-service.selectorLabels" -}}
app.kubernetes.io/name: {{ include "aequor-service.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}
