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
- `--spire-join-token` / `--spire-server-address` — SPIRE mode: the node
  attests to SPIRE and authenticates by SVID over mTLS (the UI emits these
  for you, see [One-command node bootstrap](#one-command-node-bootstrap))
- `--no-telemetry` — SPIRE mode only: skip the host telemetry stack

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
  `POST /api/agents/registration-tokens`. Every token names the organization
  (or organizational unit) whose dedicated capacity the agent becomes, via
  `organizationId`/`organizationalUnitId` — a brand-new agent whose token
  carries no organization is refused registration.
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

## Release binaries and the agent manifest

Every tagged release publishes one **combined** binary tarball per supported
platform, each with a `.sha256` sidecar the installer (and the agent update
flow) verifies before use:

| Asset | Platform |
| --- | --- |
| `strato-linux-x86_64.tar.gz` | Linux x86_64 (static Swift stdlib — no toolchain needed on the host) |
| `strato-linux-arm64.tar.gz` | Linux arm64/aarch64 (static Swift stdlib) |
| `strato-macos-arm64.tar.gz` | macOS Apple Silicon (dev/test) |

Each tarball contains both `strato-control-plane` and `strato-agent`. There is
deliberately **no separate agent-only asset**: every consumer extracts just the
`strato-agent` member (`install.sh` and the agent self-update flow both do a
single-member `tar -xzf ... strato-agent`), and one asset per platform keeps
the release matrix and checksum handling simple. If download size ever matters
for large fleets, a lean per-arch agent asset can be added later without
breaking consumers — the manifest below names assets explicitly rather than by
convention.

### agent-manifest.json

Each release also publishes `agent-manifest.json`, a machine-readable pointer
to the release's binaries. The latest release's manifest is always at a stable
URL:

```
https://github.com/samcat116/strato/releases/latest/download/agent-manifest.json
```

```json
{
  "schemaVersion": 1,
  "version": "v1.2.3",
  "gitSHA": "abc123...",
  "assets": [
    {
      "os": "linux",
      "arch": "arm64",
      "asset": "strato-linux-arm64.tar.gz",
      "url": "https://github.com/samcat116/strato/releases/download/v1.2.3/strato-linux-arm64.tar.gz",
      "sha256": "…",
      "size": 123456789,
      "agentBinaryPath": "strato-agent"
    }
  ]
}
```

The control plane uses this to discover the newest agent version and the
per-platform download URL + checksum to hand an agent when instructing it to
update. `agentBinaryPath` is the tarball member to extract, so a future
asset-shape change is just a manifest change.

Air-gapped deployments are an open question: the control plane may need to
proxy or mirror release assets rather than hand agents `github.com` URLs. The
manifest's URLs are absolute, so a mirror can serve a rewritten
`agent-manifest.json` pointing at itself without any agent-side changes.

## Running in Docker (Linux)

The agent image is published from the `main` branch as
`ghcr.io/samcat116/strato-agent:main` (moving) and `main-<sha>` (immutable),
linux/amd64 only — the same convention as the control-plane and frontend
images used by the compose deployment. On other architectures, build the
image from source (`docker build -f agent/Dockerfile .` at the repo root).

```bash
docker run -d --name strato-agent --restart unless-stopped \
  --user root --device /dev/kvm \
  -v /var/lib/strato:/var/lib/strato \
  -v /etc/strato:/etc/strato \
  ghcr.io/samcat116/strato-agent:main \
  join 'ws://strato.example.com/agent/ws?token=...&name=hv-01'
```

`--user root` is required: the image runs as the non-root `strato` user by
default, but the root-owned `/var/lib/strato` and `/etc/strato` paths — and
the join state-file write check — need root, matching the same-as-`strato-agent
join`-on-Linux guidance below.

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

## Updating agents

The control plane compares each agent's reported build version against its
target version (its own version, or `AGENT_TARGET_VERSION` when agents are
pinned separately) and shows an **Update available** badge on the Agents page
when they differ.

### Remote update (bare-binary installs)

For agents installed as a bare binary under systemd (the install-script
layout), click **Update** on the agent row or detail page — or call the API:

```bash
curl -X POST https://strato.example.com/api/agents/<agent-id>/actions/update \
  -H 'Authorization: Bearer <api-key>' -H 'Content-Type: application/json' -d '{}'
```

The control plane resolves the artifact for the agent's OS/arch from the
release's [`agent-manifest.json`](#agent-manifestjson) (falling back to the
`strato-<os>-<arch>.tar.gz` naming convention plus `.sha256` sidecar for
releases that predate the manifest; `AGENT_UPDATE_ARTIFACT_BASE_URL` points
both at a mirror) and sends the agent an update command. The agent then:

1. downloads the artifact into a staging workspace next to its own binary,
2. verifies the SHA-256 checksum and extracts the `strato-agent` member,
3. runs the staged binary's `--version` as a sanity probe,
4. preserves the current binary as `strato-agent.prev`, atomically renames
   the new one over its own executable path,
5. reports success, shuts down cleanly, and exits with code 75 so systemd
   (`Restart=on-failure`) starts the new binary.

The updated agent proves itself by re-registering with its new version; the
control plane logs the old→new transition and the badge clears. Any failure
before the final rename (download error, checksum mismatch, failed probe)
aborts with the running binary untouched and is reported back as the request's
error. A crash-looping update can be rolled back by hand:
`mv /usr/local/bin/strato-agent.prev /usr/local/bin/strato-agent`.

Caveats the UI confirms before dispatching:

- The agent disconnects briefly and re-registers on restart.
- Running VMs keep running and are re-adopted via their deterministic control
  sockets (QMP for QEMU, the Firecracker API socket for Firecracker).
- Running **sandboxes are not yet re-adopted** — they keep running as orphans
  that can only be deleted afterwards. The endpoint refuses in this case
  unless `{"force": true}` is passed.

Request-body overrides for air-gapped deployments or unreleased builds
(**system admin only** — an explicit artifact is arbitrary code the host will
run as the agent, so delegated org admins are limited to the release path):
`{"artifactUrl": "...", "sha256": "<hex>"}` skips artifact resolution and
hands the agent exactly that file (the URL must be reachable *from the agent
host*; a `file:///path/on/the/host` URL works for artifacts already copied
onto the node). The override defaults to the release tarball shape; add
`"artifactKind": "binary"` when the URL points at a bare `strato-agent`
executable, or `"tarballMember": "..."` for a tarball whose agent binary
lives at a different member path. Main-branch builds have no release
tarballs, so updating to them always requires this override.

Remote updates need an agent new enough to understand the command (wire
protocol v6+); older agents must be updated manually once — re-run install.sh
or replace the binary — after which remote updates work.

### Docker / Kubernetes (managed externally)

Agents running in a container refuse remote updates with a "managed
externally" error: the binary is part of an immutable image layer, so the
image is the update mechanism. Pull the new image and recreate the container
(or roll the Deployment). The refusal is automatic — the agent image carries
`STRATO_INSTALL_MODE=container`, and agents also detect standard container
fingerprints (`/.dockerenv`, container cgroups) when the marker is absent.

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
bootstrap command that curls
[`deploy/agent/install.sh`](https://github.com/samcat116/strato/blob/main/deploy/agent/install.sh)
with the SPIRE flags: it downloads the `strato-agent` and `spire-agent`
binaries, writes the spire-agent config, waits for the Workload API
socket, joins the control plane, and brings up host telemetry — one
command per new hypervisor node. Both secrets are shown exactly once, at
creation time.

### Host telemetry (Alloy)

In SPIRE mode the installer also sets up host telemetry (skip with
`--no-telemetry`):

- **Grafana Alloy** (`alloy.service`) collects node metrics
  (node_exporter set) and the `strato-agent`/`spire-agent` journals, and
  pushes them to the control plane's Envoy mTLS listener —
  `/ingest/metrics` lands in Prometheus, `/ingest/logs` in Loki (see
  `deploy/compose`).
- **spiffe-helper** (`spiffe-helper.service`) materializes the node's
  SVID as PEM files under `/var/lib/alloy/certs/` for Alloy's
  `tls_config`; Alloy re-reads them on every TLS handshake, so SVID
  rotation needs no reloads.

The client credential is the node's own SPIFFE identity
(`spiffe://<trust-domain>/agent/<name>`) — Envoy only accepts telemetry
writes from `agent/` identities. `/etc/alloy/config.alloy` is written
once and then left alone on re-runs, so local edits stick. Nodes joined
with a plain token URL (no SPIRE) get no telemetry stack.

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
| `SPIRE_SERVER_PUBLIC_ADDRESS` | Address nodes dial for attestation | `EXTERNAL_HOSTNAME:8085` (compose); the Helm chart sets `spire.<host>:443` when `gateway.enabled` |
| `SPIRE_AGENT_SELECTORS` | Comma-separated workload selectors | `unix:uid:0` |
| `SPIRE_SVID_TTL` | X.509 SVID TTL for agent entries (seconds) | `3600` |

### Connectivity (remote nodes)

Agents only ever dial **out**, so a hypervisor behind a home/ISP network needs
no inbound ports — but the control plane must be reachable. How that reachability
is exposed depends on the deployment:

- **Compose** (`deploy/compose`) publishes distinct ports on the host: the web
  UI/API, the Envoy mTLS listener (`:8443`), and the SPIRE node API (`:8085`).
  Each must be reachable from the hypervisor.
- **Kubernetes (Helm chart, `gateway.enabled`)** collapses all three onto a
  single LoadBalancer on **:443**, routed by SNI with Gateway API (Envoy
  Gateway) so nothing extra needs opening:

  | SNI host | Gateway route | Terminates where | Backend |
  | --- | --- | --- | --- |
  | `<host>` | `HTTPRoute` | at the Gateway | control plane / frontend (token join at `wss://<host>/agent/ws`) |
  | `agents.<host>` | `TLSRoute` passthrough | at the Envoy sidecar (sees the SVID) | control-plane `agent-mtls` `:8443` |
  | `spire.<host>` | `TLSRoute` passthrough | at the SPIRE server | SPIRE node API `:8081` |

  So an SVID node connects to `wss://agents.<host>/agent/ws` and attests against
  `spire.<host>:443` — outbound-443-only, the friendliest shape for nodes behind
  home networks. `TLSRoute` is an experimental Gateway API channel; the chart
  pins `gateway.networking.k8s.io/v1alpha2` for it, matching Envoy Gateway's
  experimental install. See the `gateway:` block in the chart's `values.yaml`.

  > Deploying Envoy Gateway and cutting the LoadBalancer/DNS over from
  > ingress-nginx are infrastructure concerns handled outside the chart; by
  > default the chart only attaches its routes to an operator-provided Gateway
  > (`gateway.create=false`).
