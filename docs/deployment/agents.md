# Deploying Agents

Agents run on hypervisor hosts and execute VMs via QEMU (KVM on Linux, HVF on
macOS; Firecracker optionally on Linux). They connect out to the control
plane over WebSocket — no inbound ports needed on the hypervisor.

## Joining a control plane

1. In the web UI, go to **Agents → Create Registration Token**, enter a name
   for the host, and copy the generated command.
2. Run it on the hypervisor host:

```bash
strato-agent join 'ws://strato.example.com/agent/ws?token=...&name=hv-01'
```

That single command registers the agent and keeps it running. On success the
agent:

- receives a rotated reconnect token from the control plane and persists it
  to its **state file** (mode 0600):
  - Linux: `/var/lib/strato/agent-state.json`
  - macOS: `~/Library/Application Support/strato/agent-state.json`
- writes a minimal `config.toml` (Linux: `/etc/strato/config.toml`) if none
  exists, containing the control plane URL.

After that, a plain `strato-agent` (no arguments) reconnects automatically —
restarts, reboots, and control-plane restarts all just work. The reconnect
token is single-use and rotates on every successful registration.

### Tokens

- Registration tokens are **single-use** and expire (default 24h from the
  UI). Creating one requires an admin session; the API equivalent is
  `POST /api/agents/registration-tokens`.
- If an agent's stored token is rejected (expired, revoked, or the agent was
  deleted server-side), the agent exits with instructions rather than
  retrying forever. Create a new token and run `strato-agent join` again —
  it overwrites the old state.
- A corrupt state file is moved aside to `agent-state.json.corrupt` and
  treated as absent.

## Running in Docker (Linux)

```bash
docker run -d --name strato-agent --restart unless-stopped \
  --device /dev/kvm \
  -v /var/lib/strato:/var/lib/strato \
  -v /etc/strato:/etc/strato \
  ghcr.io/samcat116/strato-agent:latest \
  join 'ws://strato.example.com/agent/ws?token=...&name=hv-01'
```

The `/var/lib/strato` mount persists both VM disks and the join state, so
`docker restart strato-agent` reconnects without a new token. With
`--restart unless-stopped`, a rejected token exits the container and Docker's
backoff keeps it from hammering the control plane.

## Running as a systemd service (Linux)

After a successful `strato-agent join`, the state and config files make plain
restarts self-sufficient:

```ini
# /etc/systemd/system/strato-agent.service
[Unit]
Description=Strato Agent
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=/usr/local/bin/strato-agent
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
```

## Configuration

Most settings have platform defaults; see
[`config.toml.example`](https://github.com/samcat116/strato/blob/main/config.toml.example)
for the full list (QEMU paths, storage directories, network mode, SPIFFE/mTLS,
`state_file` location). Command-line flags override the config file.

## mTLS (SPIFFE/SPIRE)

For production fleets, agents can authenticate with X.509 SVIDs instead of
tokens via SPIRE — see the `[spiffe]` section of `config.toml.example` and
the SPIRE options in the Helm chart. Token join remains the simplest path
and is secure by default (single-use, expiring, rotating tokens).
