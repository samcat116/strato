# Strato Control Plane Helm Chart

This chart deploys the Strato control plane, web frontend, PostgreSQL and
Valkey dependencies, SPIRE identity stack, Envoy agent-mTLS listener, and
optional telemetry components.

The canonical installation, configuration, upgrade, security, and
troubleshooting guide is [Kubernetes deployment](../../docs/deployment/kubernetes.md).

## Quick start

```bash
helm dependency build helm/strato-control-plane
helm install strato helm/strato-control-plane
```

For a production installation, start from the values documented in the
deployment guide. In particular, configure the public WebAuthn origin and the
agent/SPIRE TLS-passthrough hostnames before exposing the release.

Chart defaults are documented inline in [`values.yaml`](values.yaml). Render and
validate local changes with:

```bash
helm lint helm/strato-control-plane
helm template strato helm/strato-control-plane
```
