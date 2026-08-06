# What is Strato?

Strato is a private cloud platform: a control plane, a fleet of hypervisor
agents, and a web UI that together give you VMs, microVM sandboxes,
software-defined networking, and fine-grained access control on your own
hardware. It aims to be fast, secure by default, and genuinely easy to
deploy — a fresh install generates its own secrets and is production-shaped
from the first `docker compose up`.

## How it's shaped

Strato splits into a **control plane** and per-node **agents**:

- **Control plane** — the JSON API, PostgreSQL database, scheduler, IPAM,
  and built-in IAM. Declarative: the database stores each workload's
  *desired* state, and agents converge on it.
- **Agents** — run on each hypervisor node and manage workloads through
  hypervisor drivers (QEMU for VMs, Firecracker for sandboxes and
  lightweight VMs). Agents dial out to the control plane over a WebSocket;
  hypervisor nodes need no inbound connectivity.
- **Frontend** — a Next.js web app consuming the same JSON API, with
  in-browser serial and graphics consoles.

The [architecture overview](/architecture/overview) is the full map.

## What you get

### Virtual machines

Full-lifecycle VM management on QEMU with hardware acceleration — KVM on
Linux, Hypervisor.framework on macOS (dev/test). Images carry typed
artifacts per hypervisor and architecture; VMs get cloud-init provisioning,
snapshots and checkpoints, online resize, virtio-balloon memory management,
Secure Boot/vTPM for [Windows guests](/guide/windows-guests), and optional
VNC [graphics consoles](/guide/graphics-console).

### Sandboxes

Disposable Firecracker microVMs booted directly from OCI container images —
create, exec, fork, snapshot/restore — with TTL-based auto-expiry. Built for
fast, isolated code execution alongside your longer-lived VMs.

### Software-defined networking

Production networking on Linux via OVN/OVS: multi-node overlay networks,
security groups, floating IPs, IPv4/IPv6 dual-stack, DHCP, and routing —
with the control plane doing IPAM and DNS zone modeling. macOS falls back to
user-mode (SLIRP) networking for development.

### Identity and access

- **WebAuthn/Passkeys** for passwordless human login, plus API keys for
  automation and optional OIDC/SCIM federation
- **Built-in Cedar-based IAM**: roles, guardrails, and decision logs over an
  organization → folder → project hierarchy — no external authorization
  service to run
- **SPIFFE/SPIRE mTLS** as the only agent authentication path — no join
  tokens or shared secrets

### Scheduling

VMs are placed across agents by resource availability with pluggable
strategies (`least_loaded` by default; `best_fit`, `round_robin`, `random`),
honoring hard constraints like hypervisor support, site pinning, and vTPM
capability.

## The stack

Swift end to end on the server — the control plane is
[Vapor](https://vapor.codes) on PostgreSQL, and the agent is a Swift daemon
driving QEMU, Firecracker, and OVN. The web frontend is Next.js/React. Both
supported deployments — single-host Docker Compose and a Kubernetes Helm
chart — ship the full stack including SPIRE.

## Use cases

- **Private cloud infrastructure** — self-hosted, multi-tenant VM
  infrastructure with real isolation between projects
- **Development and testing** — disposable environments, multiple OS
  targets, sandboxed code execution
- **Learning** — a readable, modern codebase for understanding how clouds
  are built: scheduling, SDN, IAM, and reconciliation loops in one repo

## License

Strato is released under the Functional Source License (FSL-1.1-MIT):
source-available, converting to MIT after two years.

## Next steps

- [Getting Started](/guide/getting-started) — install and boot your first VM
- [Architecture Overview](/architecture/overview) — how it all fits together
