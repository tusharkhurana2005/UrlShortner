{{- define "urlshortener.name" -}}
{{- .Chart.Name | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "urlshortener.fullname" -}}
{{- if contains .Chart.Name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name .Chart.Name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}

{{/* The image tag is the deployed version: the git SHA set by the deploy script / CI. */}}
{{- define "urlshortener.version" -}}
{{- .Values.image.tag | default .Chart.AppVersion }}
{{- end }}

{{- define "urlshortener.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version }}
app.kubernetes.io/name: {{ include "urlshortener.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ include "urlshortener.version" . | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: urlshortener
{{- end }}

{{/* Selector labels must never change between releases (immutable on Deployments). */}}
{{- define "urlshortener.selectorLabels" -}}
app.kubernetes.io/name: {{ include "urlshortener.name" .root }}
app.kubernetes.io/instance: {{ .root.Release.Name }}
app.kubernetes.io/component: {{ .component }}
{{- end }}

{{- define "urlshortener.image" -}}
{{- $registry := .root.Values.image.registry -}}
{{- $tag := include "urlshortener.version" .root -}}
{{- if $registry }}{{ printf "%s/%s:%s" $registry .repository $tag }}{{ else }}{{ printf "%s:%s" .repository $tag }}{{ end }}
{{- end }}

{{- define "urlshortener.mongodbHost" -}}
{{- printf "%s-mongodb-0.%s-mongodb.%s.svc.cluster.local" (include "urlshortener.fullname" .) (include "urlshortener.fullname" .) .Release.Namespace }}
{{- end }}

{{/* Hardened container defaults shared by every workload (restricted Pod Security profile). */}}
{{- define "urlshortener.containerSecurityContext" -}}
allowPrivilegeEscalation: false
readOnlyRootFilesystem: true
capabilities:
  drop: ["ALL"]
{{- end }}
