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
Resolvable host for the database readiness wait (nc). The bundled Postgres is an
in-cluster Service, so qualify it with the cluster domain; an external database
host is already a routable FQDN and must be used verbatim (qualifying it yields a
bogus name like `db.example.com.<ns>.svc.cluster.local`).
*/}}
{{- define "strato-control-plane.databaseWaitHost" -}}
{{- if .Values.postgresql.enabled }}
{{- printf "%s.%s.svc.cluster.local" (include "strato-control-plane.databaseHost" .) .Release.Namespace }}
{{- else }}
{{- .Values.externalDatabase.host }}
{{- end }}
{{- end }}

{{/*
Effective PostgreSQL TLS mode (disable|prefer|require) for both the control
plane (DATABASE_TLS) and SpiceDB (sslmode), so a single knob governs both.
An explicit strato.database.tls wins. Otherwise it defaults by topology: the
bundled in-cluster Postgres serves no TLS and its traffic never leaves the
cluster, so `disable`; an external database is presumed remote, so `require`.
See issue #56.
*/}}
{{- define "strato-control-plane.databaseTLS" -}}
{{- if .Values.strato.database.tls }}
{{- .Values.strato.database.tls }}
{{- else if .Values.postgresql.enabled }}
{{- "disable" }}
{{- else }}
{{- "require" }}
{{- end }}
{{- end }}

{{/*
The `sslmode`/`sslrootcert` query string for SpiceDB's datastore-conn-uri,
derived from the effective TLS mode. SpiceDB uses pgx (libpq semantics), where
plain `sslmode=require` encrypts but does NOT validate the server certificate
or hostname — so it would accept any cert and leak the datastore password to a
MITM. To match the control plane (which verifies under require), `require` maps
to `verify-full`: pgx then verifies against the system trust roots, or against
the supplied CA bundle via sslrootcert when one is mounted. `prefer` stays
best-effort (may fall back to plaintext); `disable` is plaintext.
*/}}
{{- define "strato-control-plane.spicedbSslQuery" -}}
{{- $mode := include "strato-control-plane.databaseTLS" . -}}
{{- if eq $mode "disable" -}}
sslmode=disable
{{- else if .Values.strato.database.tlsCACert -}}
sslmode=verify-full&sslrootcert=/etc/spicedb/db-tls/ca.crt
{{- else if eq $mode "require" -}}
sslmode=verify-full
{{- else -}}
sslmode={{ $mode }}
{{- end -}}
{{- end }}

{{/*
Get the database port
*/}}
{{- define "strato-control-plane.databasePort" -}}
{{- if .Values.postgresql.enabled }}
{{- .Values.strato.database.port }}
{{- else }}
{{- .Values.externalDatabase.port }}
{{- end }}
{{- end }}

{{/*
Get the database password secret name.
When the bundled PostgreSQL is enabled this is the release credentials secret
(see credentials-secret.yaml), which the bitnami subchart also reads via
auth.existingSecret so there is a single source of truth.
*/}}
{{- define "strato-control-plane.databaseSecretName" -}}
{{- if .Values.postgresql.enabled }}
{{- printf "%s-strato-credentials" .Release.Name }}
{{- else if .Values.externalDatabase.existingSecret }}
{{- .Values.externalDatabase.existingSecret }}
{{- else }}
{{- printf "%s-external-db" (include "strato-control-plane.fullname" .) }}
{{- end }}
{{- end }}

{{/*
Get the database password secret key
*/}}
{{- define "strato-control-plane.databaseSecretKey" -}}
{{- if and (not .Values.postgresql.enabled) .Values.externalDatabase.existingSecret }}
{{- .Values.externalDatabase.existingSecretPasswordKey | default "password" }}
{{- else }}
{{- "db-password" }}
{{- end }}
{{- end }}

{{/*
The Secret name + key holding SpiceDB's datastore connection URI. With the
bundled Postgres (or an inline external password) the chart builds this into its
own <spicedb>-config Secret; with externalDatabase.existingSecret it comes from
the pre-provisioned Secret instead, so no password is templated into git-tracked
state.
*/}}
{{- define "strato-control-plane.spicedbDatastoreSecretName" -}}
{{- if and (not .Values.postgresql.enabled) .Values.externalDatabase.existingSecret }}
{{- .Values.externalDatabase.existingSecret }}
{{- else }}
{{- printf "%s-config" (include "strato-control-plane.spicedb.fullname" .) }}
{{- end }}
{{- end }}

{{- define "strato-control-plane.spicedbDatastoreSecretKey" -}}
{{- if and (not .Values.postgresql.enabled) .Values.externalDatabase.existingSecret }}
{{- .Values.externalDatabase.existingSecretDatastoreUriKey | default "datastore-conn-uri" }}
{{- else }}
{{- "datastore-conn-uri" }}
{{- end }}
{{- end }}

{{/*
SpiceDB labels
*/}}
{{- define "strato-control-plane.spicedb.name" -}}
{{- $suffix := default "spicedb" .Values.spicedb.nameOverride -}}
{{- printf "%s-%s" (include "strato-control-plane.name" .) $suffix | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "strato-control-plane.spicedb.fullname" -}}
{{- if .Values.spicedb.fullnameOverride }}
{{- .Values.spicedb.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $suffix := default "spicedb" .Values.spicedb.nameOverride -}}
{{- printf "%s-%s" (include "strato-control-plane.fullname" .) $suffix | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}

{{- define "strato-control-plane.spicedb.labels" -}}
helm.sh/chart: {{ include "strato-control-plane.chart" . }}
app.kubernetes.io/name: {{ include "strato-control-plane.spicedb.name" . }}
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
app.kubernetes.io/name: {{ include "strato-control-plane.spicedb.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/component: spicedb
{{- end }}

{{/*
SpiceDB datastore connection-pool env vars, shared by the serve container and
the migrate initContainer. SpiceDB binds every flag to a SPICEDB_-prefixed env
var (dashes -> underscores), so these map to --datastore-conn-pool-read-max-open
etc. Values come from spicedb.datastore.connPool; see values.yaml for the
sizing rationale.
*/}}
{{- define "strato-control-plane.spicedb.connPoolEnv" -}}
{{- with .Values.spicedb.datastore.connPool -}}
- name: SPICEDB_DATASTORE_CONN_POOL_READ_MAX_OPEN
  value: {{ .read.maxOpen | quote }}
- name: SPICEDB_DATASTORE_CONN_POOL_READ_MIN_OPEN
  value: {{ .read.minOpen | quote }}
- name: SPICEDB_DATASTORE_CONN_POOL_WRITE_MAX_OPEN
  value: {{ .write.maxOpen | quote }}
- name: SPICEDB_DATASTORE_CONN_POOL_WRITE_MIN_OPEN
  value: {{ .write.minOpen | quote }}
{{- end }}
{{- end }}

{{/*
SpiceDB base labels (without component)
*/}}
{{- define "strato-control-plane.spicedb.baseLabels" -}}
helm.sh/chart: {{ include "strato-control-plane.chart" . }}
app.kubernetes.io/name: {{ include "strato-control-plane.spicedb.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Get the primary hostname
*/}}
{{- define "strato-control-plane.hostname" -}}
{{- if .Values.ingress.enabled }}
{{- (first .Values.ingress.hosts).host }}
{{- else }}
{{- "localhost" }}
{{- end }}
{{- end }}

{{/*
Get the WebAuthn relying party ID (domain without protocol/port)
*/}}
{{- define "strato-control-plane.webauthnRelyingPartyId" -}}
{{- if .Values.strato.webauthn.relyingPartyId }}
{{- .Values.strato.webauthn.relyingPartyId }}
{{- else }}
{{- include "strato-control-plane.hostname" . }}
{{- end }}
{{- end }}

{{/*
Get the WebAuthn origin URL (protocol + domain + port)
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
Whether browsers reach the control plane over HTTPS, used to gate the Secure
session cookie + HSTS (HTTP_TLS_ENABLED). Derived from the resolved WebAuthn
origin's scheme so it can never disagree with it — this covers an explicit
https:// relyingPartyOrigin (e.g. TLS terminated by an external gateway) as well
as the ingress.tls case. An explicit strato.httpTlsEnabled overrides the default.
*/}}
{{- define "strato-control-plane.tlsEnabled" -}}
{{- if not (kindIs "invalid" .Values.strato.httpTlsEnabled) }}
{{- .Values.strato.httpTlsEnabled }}
{{- else if hasPrefix "https://" (include "strato-control-plane.webauthnOrigin" .) }}
{{- true }}
{{- else }}
{{- false }}
{{- end }}
{{- end }}

{{/*
Get the Valkey host
*/}}
{{- define "strato-control-plane.valkeyHost" -}}
{{- if .Values.valkey.enabled }}
{{- printf "%s-valkey-master" .Release.Name }}
{{- else }}
{{- required "Valkey is required for control-plane coordination: set valkey.enabled=true or provide externalValkey.host" .Values.externalValkey.host }}
{{- end }}
{{- end }}

{{/*
Get the Valkey port
*/}}
{{- define "strato-control-plane.valkeyPort" -}}
{{- if .Values.valkey.enabled }}
{{- 6379 }}
{{- else }}
{{- .Values.externalValkey.port | default 6379 }}
{{- end }}
{{- end }}

{{/*
Get the Valkey password secret name
*/}}
{{- define "strato-control-plane.valkeySecretName" -}}
{{- if .Values.valkey.enabled }}
{{- if .Values.valkey.auth.existingSecret }}
{{- .Values.valkey.auth.existingSecret }}
{{- else }}
{{- printf "%s-valkey" .Release.Name }}
{{- end }}
{{- else }}
{{- printf "%s-external-valkey" (include "strato-control-plane.fullname" .) }}
{{- end }}
{{- end }}

{{/*
Get the Valkey password secret key
*/}}
{{- define "strato-control-plane.valkeySecretKey" -}}
{{- if .Values.valkey.enabled }}
{{- .Values.valkey.auth.existingSecretPasswordKey | default "redis-password" }}
{{- else }}
{{- "valkey-password" }}
{{- end }}
{{- end }}

{{/*
Valkey labels
*/}}
{{- define "strato-control-plane.valkey.labels" -}}
helm.sh/chart: {{ include "strato-control-plane.chart" . }}
app.kubernetes.io/name: {{ include "strato-control-plane.name" . }}-valkey
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/component: valkey
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}
