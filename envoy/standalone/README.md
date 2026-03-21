# Standalone Envoy for Strato Control Plane mTLS

This directory contains the Envoy configuration for bare-metal or VM deployments where Envoy runs as a standalone process alongside the Strato control plane.

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│ Control Plane Host                                          │
│                                                             │
│  ┌──────────────────┐       ┌──────────────────────────┐   │
│  │      Envoy       │       │    Control Plane App     │   │
│  │                  │       │                          │   │
│  │ - Port 8443 mTLS │──────►│ - Port 8080 HTTP        │   │
│  │ - SDS via SPIRE  │       │ - Reads X-FCCC header    │   │
│  └──────────────────┘       └──────────────────────────┘   │
│           │                                                 │
│           ▼                                                 │
│  ┌──────────────────┐                                      │
│  │   SPIRE Agent    │                                      │
│  │ /var/run/spire/  │                                      │
│  │ sockets/workload │                                      │
│  └──────────────────┘                                      │
└─────────────────────────────────────────────────────────────┘
```

## Prerequisites

1. **SPIRE Agent** running on the same host
   - Socket at `/var/run/spire/sockets/workload.sock`
   - Joined to the SPIRE Server

2. **SPIRE Registration Entry** for the control plane
   ```bash
   spire-server entry create \
       -spiffeID spiffe://strato.local/control-plane \
       -parentID spiffe://strato.local/spire-agent \
       -selector unix:uid:0 \
       -selector unix:path:/usr/local/bin/envoy
   ```

3. **Envoy** installed on the host
   - Version 1.31.0 or later recommended
   - Download: https://www.envoyproxy.io/docs/envoy/latest/start/install

## Installation

### Option 1: systemd Service (Recommended)

1. Copy the Envoy configuration:
   ```bash
   sudo mkdir -p /etc/envoy
   sudo cp envoy.yaml /etc/envoy/envoy.yaml
   ```

2. Install the systemd service:
   ```bash
   sudo cp systemd/envoy-strato.service /etc/systemd/system/
   sudo systemctl daemon-reload
   sudo systemctl enable envoy-strato
   sudo systemctl start envoy-strato
   ```

3. Check status:
   ```bash
   sudo systemctl status envoy-strato
   journalctl -u envoy-strato -f
   ```

### Option 2: Docker Container

```bash
docker run -d \
    --name envoy-strato \
    --network host \
    -v /etc/envoy/envoy.yaml:/etc/envoy/envoy.yaml:ro \
    -v /var/run/spire/sockets:/var/run/spire/sockets:ro \
    envoyproxy/envoy:v1.31.0 \
    -c /etc/envoy/envoy.yaml
```

### Option 3: Manual

```bash
envoy -c /etc/envoy/envoy.yaml --log-level info
```

## Configuration

### Ports

| Port | Protocol | Description |
|------|----------|-------------|
| 8443 | HTTPS/mTLS | Agent WebSocket connections |
| 8444 | HTTP | Health checks |
| 9901 | HTTP | Envoy admin (localhost only) |

### Environment Variables

The configuration uses static values. To customize, edit `envoy.yaml` directly:

- **Control plane port**: Change `127.0.0.1:8080` in the `control_plane_local` cluster
- **mTLS port**: Change port 8443 in the `agent_mtls_listener`
- **Trust domain**: Update SPIFFE IDs if using a different trust domain

### SPIRE Agent Socket

The default socket path is `/var/run/spire/sockets/workload.sock`. If your SPIRE Agent uses a different path, update:

1. The `spire_agent` cluster endpoint path
2. The volume mount if using Docker

## Verification

### Check Envoy Health

```bash
curl http://localhost:8444/ready
# Expected: OK
```

### Check Envoy Admin

```bash
curl http://localhost:9901/clusters
curl http://localhost:9901/listeners
```

### Check SDS Connection

```bash
curl http://localhost:9901/config_dump | jq '.configs[] | select(.["@type"] | contains("SecretsConfigDump"))'
```

### Test Agent Connection

From an agent host with SPIFFE credentials:
```bash
# Using curl with client certificate
curl -v --cert /path/to/svid.pem --key /path/to/key.pem \
    --cacert /path/to/bundle.pem \
    https://control-plane:8443/health
```

## Troubleshooting

### Envoy Cannot Connect to SPIRE Agent

```
upstream connect error or disconnect/reset before headers
```

**Solution**: Ensure SPIRE Agent is running and the socket exists:
```bash
ls -la /var/run/spire/sockets/workload.sock
```

### No Certificate Available

```
TLS error: No certificate chain
```

**Solution**: Ensure the control plane SPIFFE entry is registered:
```bash
spire-server entry show -spiffeID spiffe://strato.local/control-plane
```

### Client Certificate Validation Failed

```
TLS error: certificate verify failed
```

**Solution**: Ensure the agent's SPIFFE ID is in the same trust domain and the trust bundle is up to date.

## Security Considerations

1. **Admin Interface**: The admin interface (port 9901) is bound to localhost only. Never expose it externally.

2. **Socket Permissions**: Ensure the SPIRE Agent socket has appropriate permissions for Envoy to access.

3. **Certificate Rotation**: SPIRE handles certificate rotation automatically via SDS. No manual intervention needed.
