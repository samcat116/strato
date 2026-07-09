# Deploying Agents

Agents run on hypervisor hosts and execute VMs via QEMU (KVM on Linux, HVF on
macOS; Firecracker optionally on Linux). They connect out to the control
plane over WebSocket — no inbound ports needed on the hypervisor.

## One-command install (recommended)

On a fresh Linux host with nothing installed, the install script downloads the
agent binary, installs the host dependencies (QEMU, and OVN/OVS for SDN
networking), installs a systemd service, and joins the control plane — all from
the registration URL you copy out of the UI (**Agents → Create Registration
Token**):

```bash
curl -fsSL https://raw.githubusercontent.com/samcat116/strato/main/deploy/agent/install.sh \
  | sudo bash -s -- --registration-url 'wss://strato.example.com/agent/ws?token=...&name=hv-01'
```

The script detects the host OS/arch, verifies the download checksum, runs a
host preflight, enables `strato-agent.service`, and hands off to systemd so the
node survives reboots. Useful flags (`--help` lists them all):

- `--network-mode user` — skip OVN/OVS packages (dev/test, no SDN)
- `--version vX.Y.Z` — pin a release instead of `latest`
- `--no-systemd` — install the binary + deps but don't manage a service
- `--no-deps` — you manage host packages yourself

Run it **without** `--registration-url` to install the binary, dependencies,
and service now and register later (or re-run with the URL when you have a
token). No published binary exists for a given OS/arch? Use the Docker image
below, or build from source.

## Joining a control plane

If the agent is already installed (via the script above, a package, or a
manual binary drop), a single command registers it:

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

### Privileges

The default state and config paths (`/var/lib/strato`, `/etc/strato`) are
root-owned, so run `strato-agent join` as root on Linux. The join checks that
the state file is writable **before** consuming the token and exits with
instructions if it isn't; to run unprivileged, pass `--state-file` (and
`--config-file`) pointing at writable locations.

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

The [install script](#one-command-install-recommended) writes and enables this
unit for you. Write it by hand only if you installed the binary some other way.
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

### One-command node bootstrap

When the control plane is configured with access to the SPIRE server
registration API (`SPIRE_ENABLED=true` plus `SPIRE_SERVER_API_ADDRESS`,
e.g. `unix:///run/spire/server/api.sock` on a shared socket volume),
creating a registration token also provisions the node in SPIRE:

- a one-time **join token** for `spire-agent` node attestation, valid for
  the same window as the registration token, bound to the stable node
  identity `spiffe://<trust-domain>/node/<name>`, and
- a **workload registration entry** entitling the node's `strato-agent`
  to `spiffe://<trust-domain>/agent/<name>` (selectors configurable via
  `SPIRE_AGENT_SELECTORS`, default `unix:uid:0`).

The API response (and the UI dialog) then includes a ready-to-paste
bootstrap command using
[`deploy/agent/strato-node-bootstrap.sh`](https://github.com/samcat116/strato/blob/main/deploy/agent/strato-node-bootstrap.sh),
which writes the spire-agent config, waits for the Workload API socket,
and joins the control plane — one command per new hypervisor node. Both
secrets are shown exactly once, at creation time.

Revoking an unused registration token also removes the SPIRE entries, as
does deregistering an agent; both operations fail closed when the SPIRE
server is unreachable — or when SPIRE authentication is enabled without
`SPIRE_SERVER_API_ADDRESS` configured — so a removed node can never keep
renewing SVIDs. Deployments that manage SPIRE entries out of band can
acknowledge with `?skipSpireDeprovision=true`.

Control-plane environment reference:

| Variable | Meaning | Default |
| --- | --- | --- |
| `SPIRE_SERVER_API_ADDRESS` | SPIRE server registration API (`unix:///path` or loopback `host:port` bridge) | unset (provisioning off) |
| `SPIRE_SERVER_PUBLIC_ADDRESS` | Address nodes dial for attestation | `EXTERNAL_HOSTNAME:8085` |
| `SPIRE_AGENT_SELECTORS` | Comma-separated workload selectors | `unix:uid:0` |
| `SPIRE_SVID_TTL` | X.509 SVID TTL for agent entries (seconds) | `3600` |
