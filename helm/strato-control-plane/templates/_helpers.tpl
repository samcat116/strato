{{/*
Expand the name of the chart.
*/}}
{{- define "strato-control-plane.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
*/}}
{{- define "strato-control-plane.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "strato-control-plane.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "strato-control-plane.labels" -}}
helm.sh/chart: {{ include "strato-control-plane.chart" . }}
{{ include "strato-control-plane.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "strato-control-plane.selectorLabels" -}}
app.kubernetes.io/name: {{ include "strato-control-plane.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Create the name of the service account to use
*/}}
{{- define "strato-control-plane.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "strato-control-plane.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Get the database host
*/}}
{{- define "strato-control-plane.databaseHost" -}}
{{- if .Values.postgresql.enabled }}
{{- printf "%s-postgresql" .Release.Name }}
{{- else }}
{{- .Values.externalDatabase.host }}
{{- end }}
{{- end }}

{{/*
Get the database password secret name
*/}}
{{- define "strato-control-plane.databaseSecretName" -}}
{{- if .Values.postgresql.enabled }}
{{- printf "%s-postgresql" .Release.Name }}
{{- else }}
{{- printf "%s-external-db" (include "strato-control-plane.fullname" .) }}
{{- end }}
{{- end }}

{{/*
Get the database password secret key
*/}}
{{- define "strato-control-plane.databaseSecretKey" -}}
{{- if .Values.postgresql.enabled -}}
password
{{- else -}}
db-password
{{- end -}}
{{- end }}

{{/*
SpiceDB labels
*/}}
{{- define "strato-control-plane.spicedb.labels" -}}
helm.sh/chart: {{ include "strato-control-plane.chart" . }}
app.kubernetes.io/name: {{ include "strato-control-plane.name" . }}-spicedb
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/component: spicedb
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
SpiceDB selector labels
*/}}
{{- define "strato-control-plane.spicedb.selectorLabels" -}}
app.kubernetes.io/name: {{ include "strato-control-plane.name" . }}-spicedb
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/component: spicedb
{{- end }}

{{/*
Get the WebAuthn origin URL
*/}}
{{- define "strato-control-plane.webauthnOrigin" -}}
{{- if .Values.strato.webauthn.relyingPartyOrigin }}
{{- .Values.strato.webauthn.relyingPartyOrigin }}
{{- else if .Values.ingress.enabled }}
{{- if .Values.ingress.tls }}
{{- printf "https://%s" (first .Values.ingress.hosts).host }}
{{- else }}
{{- printf "http://%s" (first .Values.ingress.hosts).host }}
{{- end }}
{{- else }}
{{- printf "http://localhost:%d" (int .Values.service.port) }}
{{- end }}
{{- end }}

{{/*
Get the SpiceDB connection string
*/}}
{{- define "strato-control-plane.spicedbConnectionString" -}}
{{- if .Values.postgresql.enabled }}
{{- printf "postgres://%s:%s@%s:%v/%s?sslmode=disable" .Values.strato.database.username .Values.postgresql.auth.password (include "strato-control-plane.databaseHost" .) .Values.strato.database.port .Values.strato.database.name }}
{{- else }}
{{- printf "postgres://%s:%s@%s:%v/%s?sslmode=disable" .Values.strato.database.username .Values.externalDatabase.password (include "strato-control-plane.databaseHost" .) .Values.strato.database.port .Values.strato.database.name }}
{{- end }}
{{- end }}

{{/*
Common security context
*/}}
{{- define "strato-control-plane.securityContext" -}}
runAsNonRoot: true
runAsUser: 10001
runAsGroup: 10001
fsGroup: 10001
{{- end }}

{{/*
Common pod security context
*/}}
{{- define "strato-control-plane.podSecurityContext" -}}
runAsNonRoot: true
runAsUser: 10001
runAsGroup: 10001
fsGroup: 10001
seccompProfile:
  type: RuntimeDefault
{{- end }}