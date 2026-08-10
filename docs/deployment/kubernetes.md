# Kubernetes Deployment

Strato's control plane ships as a Helm chart at
[`helm/strato-control-plane/`](https://github.com/samcat116/strato/tree/main/helm/strato-control-plane),
bundling PostgreSQL and Valkey. It is secure by default: a bare
`helm install` generates strong random credentials — there are no default
passwords to remember to change.

## Install

```bash
git clone https://github.com/samcat116/strato.git
cd strato/helm/strato-control-plane
helm dependency build
helm install strato .
```

Every control-plane pod applies pending database migrations before it starts
serving. PostgreSQL advisory locking serializes concurrent replicas; a migration
failure leaves the new pod unready and is reported in its logs.

## Generated credentials

On first install the chart creates the `<release>-strato-credentials` secret
with:

| Key | Used by |
|---|---|
| `db-password` | PostgreSQL and the control plane |
| `postgres-admin-password` | PostgreSQL superuser |

The same values are reused on every upgrade, and the secret is kept on
`helm uninstall` so a reinstall keeps matching a retained database volume.

Retrieve values:

```bash
kubectl get secret strato-strato-credentials \
  -o jsonpath='{.data.db-password}' | base64 -d
```

To supply your own instead, set `postgresql.auth.password` and/or
`postgresql.auth.postgresPassword` — explicit values always win and are
stored in the same secret so every consumer stays in sync.

## Production configuration

External exposure goes through the **Gateway API** (Envoy Gateway): one
LoadBalancer on `:443` carries the web UI/API, agent mTLS, and SPIRE node
attestation, routed by SNI. TLS for the web host terminates at the Gateway;
the agent and SPIRE hosts pass through untouched, because agent mTLS is
end-to-end — an edge that terminated it would strip the client certificate
(the SVID) and the control plane would reject every agent.

```yaml
# my-values.yaml
gateway:
  enabled: true
  # The conventional split: your infrastructure owns the Gateway (e.g. an
  # Argo app deploying Envoy Gateway) and the chart attaches its routes to it
  # (create: false, the default). Set create: true to have the chart render
  # the Gateway itself:
  create: true
  gatewayClassName: eg          # Envoy Gateway's default GatewayClass
  tls:
    certManager:
      enabled: true             # issue the web-host cert via the Gateway shim
      issuerRef:
        name: letsencrypt-prod
        kind: ClusterIssuer

strato:
  # Reachable by hypervisor hosts; derives the SNI hostnames below and is
  # embedded in agent join commands.
  externalHostname: strato.example.com
  webauthn:
    relyingPartyId: strato.example.com
    relyingPartyOrigin: https://strato.example.com
```

```bash
helm install strato . -f my-values.yaml
```

The install notes print the resulting URL — `https://strato.example.com`,
TLS terminated at the Gateway on `:443`.

Three SNI hosts share that one listener. Leave `gateway.hostnames.*` empty
and they derive from `strato.externalHostname`:

| SNI host | Gateway route | Terminates where | Backend |
| --- | --- | --- | --- |
| `<host>` | `HTTPRoute` | at the Gateway | control plane / frontend (web UI and JSON API) |
| `agents.<host>` | `TLSRoute` passthrough | at the Envoy sidecar (sees the SVID) | control-plane `agent-mtls` `:8443` |
| `spire.<host>` | `TLSRoute` passthrough | at the SPIRE server | SPIRE node API `:8081` |

An SVID node therefore connects to `wss://agents.<host>/agent/ws` and attests
against `spire.<host>:443` — outbound-443-only, the friendliest shape for
nodes behind home networks. The chart points `EXTERNAL_HOSTNAME` at
`agents.<host>`, so the bootstrap command and telemetry-ingest origin the UI
hands you already target the passthrough listener — no manual rewrite needed.
`TLSRoute` is an experimental Gateway API channel; the chart pins
`gateway.networking.k8s.io/v1alpha2` for it, matching Envoy Gateway's
experimental install. Deploying Envoy Gateway itself, and DNS for the three
hosts (external-dns needs `--source=gateway-httproute` and
`--source=gateway-tlsroute`), are infrastructure concerns handled outside the
chart.

WebAuthn requires the origin to exactly match the URL users visit (and HTTPS
for anything other than localhost). With `gateway.enabled` the chart derives
sensible WebAuthn defaults from the gateway web host, but setting them
explicitly is recommended.

To provision users yourself rather than letting anyone sign up, add
`strato.selfRegistrationEnabled: false`. The first account is still creatable,
so first-run setup works with it disabled — see
[Self-registration](/deployment/overview#self-registration).

### Image storage: use S3 in production

`strato.imageStorage` decides where uploaded VM image bytes (disks, kernels,
rootfs artifacts) live. The default `filesystem` backend writes into the
container's ephemeral filesystem — the chart mounts no persistent volume for
images, so uploads are lost whenever the pod restarts, and multiple replicas
each hold a different, partial set (an agent can be handed a download URL
that whichever replica answers has never heard of). The default is kept only
so a single-replica install still starts.

Production should use the `s3` backend. Any S3 API implementation works
(MinIO, Garage, Ceph RGW, R2, or AWS itself); none is bundled:

```yaml
strato:
  imageStorage:
    backend: s3
    s3:
      bucket: strato-images
      endpoint: http://minio.storage.svc:9000  # empty for AWS S3
      existingSecret: strato-s3-credentials    # or leave keys empty for
                                               # IRSA / workload identity
```

### Other production values

| Value | What it does |
| --- | --- |
| `externalDatabase.*` | Use an external PostgreSQL (`postgresql.enabled: false`). `existingSecret` sources the password from a pre-provisioned Secret; `strato.database.tls` defaults to `require` for external databases. |
| `externalValkey.*` | Use an external Valkey (`valkey.enabled: false`) — Valkey is required either way. |
| `strato.secretEncryption` | Points `existingSecret` at a Secret holding the 32-byte key (`openssl rand -hex 32`) that encrypts stored secrets — OIDC client secrets, SSF stream tokens, registry pull secrets, webhook signing secrets — at rest. Without it the control plane warns and stores them unencrypted. |

Further hardening options (network policies, pod disruption budgets,
resource limits) are documented in the
[chart README](https://github.com/samcat116/strato/blob/main/helm/strato-control-plane/README.md).

### Separating session storage from coordination

The bundled Valkey backs two stores with opposite failure contracts.
Coordination (agent presence, sweep locks, scheduler reservations) is fail-open:
`/health/ready` reports it `degraded` and the replica keeps serving. Session
storage is not: losing it logs every signed-in user out, and readiness grades it
fatal (503). Sharing one instance therefore lets the store that is allowed to
fail take down the one that must not.

`sessionValkey` points session storage at its own endpoint. Leave `host` empty
(the default) and sessions share the coordination instance, exactly as before:

```yaml
sessionValkey:
  host: sessions-valkey-master.sessions.svc.cluster.local
  port: 6379
  password: <session-valkey-password>
  database: 0
```

The chart bundles only one Valkey — this block configures an *external* endpoint
you provide. The fields are all-or-nothing: `host` does not inherit the port or
password from `externalValkey`, so set each one the endpoint needs. Pointing
`host` at the coordination server with a different `database` is the cheap
middle ground — separate keyspaces on one instance.

## Workload identity (SPIRE)

The chart always deploys a SPIRE server (StatefulSet), a spire-agent
DaemonSet, and an Envoy mTLS sidecar next to the control plane — agents
authenticate exclusively with SPIRE-issued SVIDs, so the chart refuses to
render with `spire.enabled=false`.

::: warning Envoy >= v1.39.0 required
The mTLS listener prefers `X25519MLKEM768` (hybrid post-quantum key
exchange) so recorded handshakes stay confidential against a future quantum
attacker. That group needs **Envoy v1.39.0 or newer**, which the chart pins
by default.

If you override `spire.envoy.image.tag` with something older — an
air-gapped mirror, a conservative pin — the sidecar refuses to start with
`Failed to initialize ECDH curves` and every agent loses the control
channel. Drop the group in that case:

```yaml
spire:
  envoy:
    tlsParams:
      ecdhCurves: [X25519, P-256]
```

Agents need no configuration either way: swift-nio-ssl offers the group by
default from 2.37.1, and older agents fall back to X25519 automatically, so
control plane and agents can be upgraded in either order.
:::

Two pieces make the control plane a first-class member of its own trust
domain:

- A post-install/post-upgrade **entry bootstrap Job** creates the
  registration entries the chart's own pods need (via `kubectl exec` of the
  `spire-server` CLI inside the server pod, since the SPIRE images are
  distroless): a node alias covering every `k8s_psat`-attested agent, the
  control-plane container's `admin = true` entry, and the Envoy sidecar's
  server-certificate entry. Toggle with `spire.entryBootstrap.enabled`.
- The control-plane container mounts the node's **SPIFFE Workload API
  socket** (`spire.controlPlane.workloadApi`) and uses its own SVID to reach
  the SPIRE server's admin API over mTLS — that is what powers agent
  enrollment (join tokens, entry revocation) and the Workload Identity view.
  The plaintext admin socket never crosses the network.

## Rollouts

The chart ships startup/liveness/readiness probes and a `preStop` drain delay
tuned for zero-downtime rollouts. See
[Health checks & zero-downtime deploys](/deployment/health-checks) for what each
probe promises and which knobs to raise for a slow database or a slow ingress.

## Adding hypervisors

Agents typically run on hypervisor hardware outside the cluster. Set
`strato.externalHostname` so generated join commands point at an address
your hypervisor hosts can reach, then follow
[Deploying agents](/deployment/agents).
