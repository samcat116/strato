# Getting Started

This guide walks through installing Strato and creating your first VM. If you
want to get running as fast as possible, the [Quick Start](/guide/quick-start)
is the condensed version. If you want to work on Strato itself, see
[Local Development](/development/local-development).

## Prerequisites

### Control plane

Pick one of the two supported deployment paths:

- **Docker Compose** — Docker Engine with the Compose plugin, on a single host
- **Kubernetes (Helm)** — a cluster (minikube, kind, or managed) and Helm v3+

Both generate strong secrets on first run; there is nothing to configure
before production except your hostname.

### Hypervisor hosts (agents)

VMs run on agents, which can be the same machine as the control plane or
separate hosts.

#### Linux (production)

- KVM kernel module (`/dev/kvm` access)
- QEMU packages: `qemu-system-x86_64`, `qemu-utils`
- OVN/OVS packages: `ovn-host`, `openvswitch-switch` — hypervisors run only
  the chassis side; the per-site NB/SB/northd central runs separately (see
  `deploy/ovn-central/`)
- Network capabilities: `NET_ADMIN`, `SYS_ADMIN`

#### macOS (development only)

- macOS 14.0 or later
- QEMU: `brew install qemu`
- Xcode Command Line Tools

Networking on macOS is QEMU user-mode only — outbound NAT, no inbound and no
VM-to-VM traffic. Use it for development and testing, not production.

## Installation

### Docker Compose

```bash
git clone https://github.com/samcat116/strato.git
cd strato/deploy/compose
./setup.sh            # generates .env with strong random secrets
docker compose up -d
```

Visit `http://localhost`. For a real hostname, run
`./setup.sh --hostname strato.example.com` and terminate TLS in front of the
proxy — WebAuthn requires HTTPS for anything other than `localhost`. See the
[Docker Compose guide](/deployment/docker-compose).

### Kubernetes (Helm)

```bash
git clone https://github.com/samcat116/strato.git
cd strato/helm/strato-control-plane
helm dependency build
helm install strato .

# In another terminal:
kubectl port-forward service/strato-strato-control-plane 8080:8080
```

Visit `http://localhost:8080`. Credentials are auto-generated into the
`strato-strato-credentials` secret and reused across upgrades. For production
values (ingress, TLS, WebAuthn hostname), see the
[Kubernetes guide](/deployment/kubernetes).

Database migrations and authorization schema loading run automatically at
startup on both paths.

## First steps

### 1. Register a user

1. Click **Register** and enter a username, email, and display name
2. Click **Register with Passkey** and follow your browser's prompts
3. **The first registered user automatically becomes the system
   administrator** — register yourself before exposing the URL to others
4. Complete onboarding to create your organization

### 2. Add a hypervisor

1. Go to **Agents → Create Registration Token** and name the host
2. Run the generated command on the hypervisor host:

   ```bash
   strato-agent join 'ws://your-control-plane/agent/ws?token=...&name=...'
   ```

The token is single-use and expires. The agent stores its rotated reconnect
credential in a state file, so plain `strato-agent` restarts reconnect
automatically. See [Deploying agents](/deployment/agents) for details,
including running the agent in Docker.

### 3. Create a virtual machine

1. Navigate to the VMs page and click **Create VM**
2. Configure the name, CPU cores, memory, disk size, and OS image
3. Click **Create** — the VM is scheduled onto an available agent
4. Click **Start**, then use the web console to connect

## Viewing logs

```bash
# Docker Compose
docker compose logs -f control-plane

# Kubernetes
kubectl logs -f deployment/strato-strato-control-plane
kubectl get pods
```

See [Logging & Log Visibility](/deployment/logging) for VM console logs and
agent journal ingestion.

## Next steps

- [Quick Start Guide](/guide/quick-start)
- [Architecture Overview](/architecture/overview)
- [Local Development](/development/local-development)
- [Kubernetes troubleshooting](/development/troubleshooting-k8s)
