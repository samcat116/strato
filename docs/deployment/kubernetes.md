# Kubernetes Deployment

Strato's control plane ships as a Helm chart at
[`helm/strato-control-plane/`](https://github.com/samcat116/strato/tree/main/helm/strato-control-plane),
bundling PostgreSQL, SpiceDB, and Valkey. It is secure by default: a bare
`helm install` generates strong random credentials — there are no default
passwords to remember to change.

## Install

```bash
git clone https://github.com/samcat116/strato.git
cd strato/helm/strato-control-plane
helm dependency build
helm install strato .
```

Database migrations and authorization schema loading run automatically as
Helm hooks.

## Generated credentials

On first install the chart creates the `<release>-strato-credentials` secret
with:

| Key | Used by |
|---|---|
| `db-password` | PostgreSQL, control plane, migration job, SpiceDB datastore |
| `postgres-admin-password` | PostgreSQL superuser |
| `spicedb-preshared-key` | SpiceDB, schema job, control plane |

The same values are reused on every upgrade, and the secret is kept on
`helm uninstall` so a reinstall keeps matching a retained database volume.

Retrieve values:

```bash
kubectl get secret strato-strato-credentials \
  -o jsonpath='{.data.db-password}' | base64 -d
```

To supply your own instead, set `postgresql.auth.password`,
`postgresql.auth.postgresPassword`, and/or `spicedb.presharedKey` — explicit
values always win and are stored in the same secret so every consumer stays
in sync.

## Production configuration

The only values you must set for a production install are the external
hostname ones:

```yaml
# my-values.yaml
ingress:
  enabled: true
  className: nginx
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-prod
  hosts:
    - host: strato.example.com
      paths:
        - path: /
          pathType: Prefix
  tls:
    - secretName: strato-tls
      hosts:
        - strato.example.com

strato:
  # Reachable by hypervisor hosts; embedded in agent join commands.
  externalHostname: strato.example.com
  webauthn:
    relyingPartyId: strato.example.com
    relyingPartyOrigin: https://strato.example.com
```

```bash
helm install strato . -f my-values.yaml
```

WebAuthn requires the origin to exactly match the URL users visit (and HTTPS
for anything other than localhost). When `ingress.tls` is set, the chart
derives sensible WebAuthn defaults from the first ingress host, but setting
them explicitly is recommended.

Further hardening options (network policies, pod disruption budgets,
resource limits, external database) are documented in the
[chart README](https://github.com/samcat116/strato/blob/main/helm/strato-control-plane/README.md).

## Workload identity (SPIRE)

The chart always deploys a SPIRE server (StatefulSet), a spire-agent
DaemonSet, and an Envoy mTLS sidecar next to the control plane — agents
authenticate exclusively with SPIRE-issued SVIDs, so the chart refuses to
render with `spire.enabled=false`.

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

## Adding hypervisors

Agents typically run on hypervisor hardware outside the cluster. Set
`strato.externalHostname` so generated join commands point at an address
your hypervisor hosts can reach, then follow
[Deploying agents](/deployment/agents).
