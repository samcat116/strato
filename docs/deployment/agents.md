# Deploying Agents

Agents run on Linux hypervisor hosts and execute VMs via QEMU (KVM), with
Firecracker as an optional second backend. They connect out to the control
plane over WebSocket — no inbound ports needed on the hypervisor.

Agents authenticate **only** by SPIFFE/SPIRE-issued X.509 SVID over mTLS.
Every node is enrolled through the control plane, which provisions its
identity in SPIRE; there is no token or password join, and an unattested
host cannot connect at all. Enrolling requires the control plane to be
configured for SPIRE (see [Enrolling a node](#enrolling-a-node)).

## Enrolling a node

Enrollment is one API call — or **Agents → Enroll node** in the web UI:

```bash
curl -X POST https://strato.example.com/api/agents/enrollments \
  -H 'Authorization: Bearer <api-key>' -H 'Content-Type: application/json' \
  -d '{"agentName": "hv-01", "organizationId": "<uuid>"}'
```

The control plane provisions the node in SPIRE — a one-time **join token**
for `spire-agent` node attestation and a **workload registration entry**
entitling the node's `strato-agent` to its SPIFFE ID — and returns a
`bootstrapCommand`: a single copy-paste line to run on the new host.

- `GET /api/agents/enrollments` lists enrollments; `DELETE
  /api/agents/enrollments/:id` revokes one, removing its SPIRE entries.
- Every enrollment names the organization (or organizational unit) whose
  dedicated capacity the agent becomes, via
  `organizationId`/`organizationalUnitId`; an enrollment with no
  organization is rejected. `siteId` pins the node to a
  [site](../architecture/networking.md).
- The join token is a one-time secret shown **once**, at creation time. It
  is redeemed the first time `spire-agent` attests and is inert afterwards.
- Enrollment fails if the control plane has no SPIRE server configured.
  There is no fallback: see [mTLS (SPIFFE/SPIRE)](#mtls-spiffe-spire) for
  the required settings.

## One-command install

The `bootstrapCommand` from the enrollment above is the install script,
pre-filled:

```bash
curl -fsSL https://raw.githubusercontent.com/samcat116/strato/main/deploy/agent/install.sh \
  | sudo bash -s -- \
  --control-plane-url 'wss://strato.example.com/agent/ws' \
  --agent-name 'hv-01' \
  --spire-join-token '...' \
  --spire-server-address 'strato.example.com:8085' \
  --trust-domain 'strato.local'
```

All five flags are required. `--agent-name` must match the name the
enrollment was created for — the control plane resolves the enrollment row
by name, and names are restricted to ASCII letters, digits, `-`, `_`, and
`.`. `--control-plane-url` is the agent WebSocket endpoint, always `wss://`
in a SPIRE deployment since Envoy terminates mTLS in front of it.

On a fresh Linux host with nothing installed, it downloads the `strato-agent`
and `spire-agent` binaries, installs the host dependencies (QEMU, and OVN/OVS
for SDN networking), attests the node to SPIRE with the join token, writes
`/etc/strato/config.toml`, brings up host telemetry, and enables
`strato-agent.service` so the node survives reboots. It detects the host
OS/arch, verifies download checksums, and runs a host preflight first.

Useful flags (`--help` lists them all):

- `--network-mode user` — skip OVN/OVS packages (dev/test, no SDN)
- `--version vX.Y.Z` — pin a release instead of `latest`
- `--no-systemd` — install the binary + deps but don't manage a service
- `--no-deps` — you manage host packages yourself
- `--trust-bundle PATH` — pin the SPIRE trust bundle instead of
  trust-on-first-use bootstrap
- `--no-telemetry` — skip the host telemetry stack

The installer is **Linux-only**: `spire-agent`, systemd, and KVM all are, so
macOS is not a supported agent platform. No published binary for a given
Linux arch? Use the Docker image below, or build from source.

### State and configuration

The installer writes `/etc/strato/config.toml` (if absent) with the control
plane URL, network mode, and the `[spiffe]` block pointing at the SPIRE
Workload API socket, and pins the enrolled name on the service's command
line with `--agent-id`. The agent keeps **no credential state on disk**: its
identity is the short-lived SVID it fetches from SPIRE on every start.

Restarts, reboots, and control-plane restarts therefore all just work with
no bookkeeping. If the node's SPIRE identity is revoked (the enrollment was
deleted, or the agent was deregistered), the connection is refused and the
agent exits with instructions rather than retrying forever; enroll the node
again to re-provision it.

### Privileges

The default storage, config, and SPIRE paths (`/var/lib/strato`,
`/etc/strato`, `/etc/spire`) are root-owned, and the default workload
selector is `unix:uid:0`, so run the agent as root. To run unprivileged,
pass `--config-file` and `--vm-storage-dir` pointing at writable locations
and set `SPIRE_AGENT_SELECTORS` on the control plane to match the uid you
use.

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

The container needs a SPIFFE identity, which it gets from a `spire-agent`
running on the **host**: mount its Workload API socket in and point the
`[spiffe]` block of `/etc/strato/config.toml` at the mounted path. Enroll the
node and run the install script with `--no-systemd --no-deps` first (or run
`spire-agent` yourself) so the socket exists.

```bash
docker run -d --name strato-agent --restart unless-stopped \
  --user root --device /dev/kvm \
  -v /var/lib/strato:/var/lib/strato \
  -v /etc/strato:/etc/strato \
  -v /var/run/spire/sockets:/var/run/spire/sockets:ro \
  ghcr.io/samcat116/strato-agent:main \
  run --config-file /etc/strato/config.toml
```

`--user root` is required: the image runs as the non-root `strato` user by
default, but the root-owned `/var/lib/strato` and `/etc/strato` paths — and
the default `unix:uid:0` workload selector — need root.

The `/var/lib/strato` mount persists both VM disks and the agent's state, so
`docker restart strato-agent` reconnects with no further setup. With
`--restart unless-stopped`, a revoked identity exits the container and
Docker's backoff keeps it from hammering the control plane.

## Running as a systemd service (Linux)

The [install script](#one-command-install) writes and enables this unit for
you. Write it by hand only if you installed the binary some other way. The
agent must not start before `spire-agent`, since its mTLS credential comes
from the Workload API:

```ini
# /etc/systemd/system/strato-agent.service
[Unit]
Description=Strato Agent
After=network-online.target spire-agent.service
Wants=network-online.target
Requires=spire-agent.service

[Service]
ExecStart=/usr/local/bin/strato-agent run --config-file /etc/strato/config.toml
Restart=on-failure
RestartSec=10
# Signal only the agent on stop, never the whole cgroup — see below.
KillMode=process
TimeoutStopSec=30

[Install]
WantedBy=multi-user.target
```

`KillMode=process` is required, not optional. QEMU and Firecracker run as
children of the agent, so they share its cgroup; with systemd's default
`KillMode=control-group` every `systemctl stop`, `systemctl restart`, or
automatic `Restart=on-failure` would kill every VM on the host. VMs are
designed to outlive the agent — the agent persists a VM manifest and re-adopts
the hypervisor processes it left running when it starts back up — so the unit
must leave them alone.

Agents installed before this directive existed have units without it. Re-run
the install script, or add the two lines by hand and
`systemctl daemon-reload`; the change takes effect on the next stop, so do it
before the next restart rather than after losing a node's VMs to one.

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

Agents authenticate with X.509 SVIDs issued by SPIRE, presented as the mTLS
client certificate to the Envoy listener in front of the control plane — see
the `[spiffe]` section of `config.toml.example` and the SPIRE options in the
Helm chart. SVIDs are short-lived and rotate automatically, so there is no
long-lived agent credential anywhere on the host.

### What enrollment provisions

Enrollment requires the control plane to have access to the SPIRE server
registration API (`SPIRE_ENABLED=true` plus `SPIRE_SERVER_API_ADDRESS`,
e.g. `unix:///run/spire/server/api.sock` on a shared socket volume);
without it, `POST /api/agents/enrollments` fails. Creating an enrollment
provisions the node in SPIRE:

- a one-time **join token** for `spire-agent` node attestation, bound to
  the stable node identity `spiffe://<trust-domain>/node/<name>`, and
- a **workload registration entry** entitling the node's `strato-agent`
  to `spiffe://<trust-domain>/agent/<name>` (selectors configurable via
  `SPIRE_AGENT_SELECTORS`, default `unix:uid:0`).

The API response (and the UI dialog) then includes a ready-to-paste
bootstrap command that curls
[`deploy/agent/install.sh`](https://github.com/samcat116/strato/blob/main/deploy/agent/install.sh)
with the SPIRE flags: it downloads the `strato-agent` and `spire-agent`
binaries, writes the spire-agent config, waits for the Workload API
socket, starts the agent, and brings up host telemetry — one command per
new hypervisor node. The join token is shown exactly once, at creation
time.

### Host telemetry (Alloy)

The installer also sets up host telemetry (skip with `--no-telemetry`):

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
once and then left alone on re-runs, so local edits stick.

Revoking an unredeemed enrollment also removes the SPIRE entries, as
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
  | `<host>` | `HTTPRoute` | at the Gateway | control plane / frontend (web UI and JSON API) |
  | `agents.<host>` | `TLSRoute` passthrough | at the Envoy sidecar (sees the SVID) | control-plane `agent-mtls` `:8443` |
  | `spire.<host>` | `TLSRoute` passthrough | at the SPIRE server | SPIRE node API `:8081` |

  So an SVID node connects to `wss://agents.<host>/agent/ws` and attests against
  `spire.<host>:443` — outbound-443-only, the friendliest shape for nodes behind
  home networks. The chart points
  `EXTERNAL_HOSTNAME` at `agents.<host>`, so the bootstrap command and
  telemetry-ingest origin the UI hands you already target the
  passthrough listener — no manual rewrite needed. `TLSRoute` is an experimental
  Gateway API channel; the chart pins `gateway.networking.k8s.io/v1alpha2` for
  it, matching Envoy Gateway's experimental install. See the `gateway:` block in
  the chart's `values.yaml`.

  > Deploying Envoy Gateway and cutting the LoadBalancer/DNS over from
  > ingress-nginx are infrastructure concerns handled outside the chart; by
  > default the chart only attaches its routes to an operator-provided Gateway
  > (`gateway.create=false`).
