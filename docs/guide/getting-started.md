# Getting Started

This guide takes you from nothing to a running Strato install with a
hypervisor enrolled and your first VM booted. Both deployment paths are
secure by default: strong secrets are generated automatically on first run —
there is nothing to change before going to production except your hostname.

(For hacking on Strato itself, see
[Local Development](/development/local-development) instead.)

## Choose a path

| | Best for | Details |
|---|---|---|
| **Docker Compose** | A single host, trying Strato out | [Docker Compose guide](/deployment/docker-compose) |
| **Kubernetes (Helm)** | Clusters, HA control plane | [Kubernetes guide](/deployment/kubernetes) |

## Prerequisites

### Control plane

- **Docker Compose** — Docker Engine with the Compose plugin, on a single host
- **Kubernetes (Helm)** — a cluster (minikube, kind, or managed) and Helm v3+

### Hypervisor hosts (agents)

VMs run on agents, which can be the same machine as the control plane or
separate hosts.

#### Linux (production)

- KVM kernel module (`/dev/kvm` access)
- Outbound connectivity to the control plane — agents dial out; no inbound
  ports are needed on the hypervisor

The enrollment install script (below) installs everything else the agent
needs: QEMU (`qemu-system-x86`, `qemu-utils`), the client-only Ceph RBD tools
(`ceph-common`), libvirt (11.5+),
OVN/OVS chassis packages (`ovn-host`, `openvswitch-switch`), and
swtpm/OVMF for Windows guests. Hypervisors run only the OVN chassis side;
the per-site NB/SB/northd central runs separately (see
`deploy/ovn-central/`).

Libvirt 11.5 is the local-disk QEMU floor. QEMU with project-namespaced RBD
needs libvirt 11.6+; Firecracker clients that map RBD through krbd do not need
libvirt.

#### macOS (control-plane and client development only)

- macOS 15.0 or later
- QEMU utilities: `brew install qemu`
- Xcode Command Line Tools

The agent has no macOS hypervisor driver and cannot host VMs or sandboxes.
Use macOS for control-plane, CLI, and simulation-mode development only.

## Installation

### Docker Compose

```bash
git clone https://github.com/samcat116/strato.git
cd strato/deploy/compose
./setup.sh            # generates .env with strong random secrets
docker compose up -d
```

Visit `http://localhost`. Database migrations run automatically.

For a real hostname, run `./setup.sh --hostname strato.example.com` instead
and terminate TLS in front of the proxy — WebAuthn requires HTTPS for
anything other than `localhost`. See the
[Docker Compose guide](/deployment/docker-compose).

### Kubernetes (Helm)

```bash
git clone https://github.com/samcat116/strato.git
cd strato/helm/strato-control-plane
helm dependency build
helm install strato .

# In another terminal (the UI is served by the frontend service):
kubectl port-forward service/strato-strato-control-plane-frontend 8080:3000
```

Visit `http://localhost:8080`. Credentials are auto-generated into the
`strato-strato-credentials` secret and reused across upgrades. For production
values (Gateway exposure, TLS, WebAuthn hostname), see the
[Kubernetes guide](/deployment/kubernetes).

## First login

1. Click **Register** and enter a username, email, and display name
2. Click **Create Passkey** and follow your browser's prompts (Touch ID,
   security key, etc.)
3. **The first registered user automatically becomes the system
   administrator** — register yourself before exposing the URL to others, or
   turn off [self-registration](/deployment/overview#self-registration)
   altogether and create the rest of your users by invitation
4. Complete onboarding to create your organization

## Install the CLI

`strato` is a single binary that drives the same API the UI uses — VMs,
sandboxes, volumes, images, networks, projects, and quotas from a terminal.
It is optional; everything in this guide can also be done in the browser.

### Homebrew (recommended on macOS)

```bash
brew install stratocloud/strato/strato
```

The formula installs the released binary — nothing is compiled — and
`brew upgrade` picks up each new stable release. macOS builds are Apple
Silicon only.

The same tap works under Homebrew on Linux (x86_64 and arm64), with one
caveat: only the Swift runtime is statically linked, so the binaries still
link the host's glibc and are built on current Ubuntu (24.04 for arm64). A
distribution older than that will not run them, even though Homebrew itself
supports it.

### Direct download

Every release also publishes a CLI-only tarball per platform
(`strato-cli-macos-arm64`, `strato-cli-linux-x86_64`,
`strato-cli-linux-arm64`), each with a `.sha256` sidecar:

```bash
base=https://github.com/samcat116/strato/releases/latest/download
curl -fsSLO "$base/strato-cli-macos-arm64.tar.gz"
curl -fsSLO "$base/strato-cli-macos-arm64.tar.gz.sha256"
shasum -a 256 -c strato-cli-macos-arm64.tar.gz.sha256
tar xzf strato-cli-macos-arm64.tar.gz
sudo install strato /usr/local/bin/strato
```

(On Linux, `sha256sum -c` instead of `shasum -a 256 -c`.)

### Sign in

```bash
strato login --server https://strato.example.com
strato vm list
```

`login` opens your browser to approve the device code and stores the token
per context, so `strato context` can switch between control planes.

For a running sandbox, execute a script-grade command or open a fresh
interactive shell:

```bash
strato sandbox exec --env MODE=check --workdir /workspace <sandbox-id> -- make test
strato sandbox attach --shell /bin/bash <sandbox-id>
```

`exec` keeps stdout and stderr separate, forwards redirected stdin, and exits
with the command's status. `attach` requires a local terminal and starts a new
PTY shell; it does not reconnect to the sandbox's main process or an earlier
session.

## Add a hypervisor

VMs run on agents — Linux hosts with KVM.

1. Go to **Agents → Add Agent** and name the host
2. Run the generated bootstrap command on the hypervisor host:

   ```bash
   curl -fsSL https://your-control-plane/api/agent-enrollments/install \
     | sudo bash -s -- 'enroll_v1_...'
   ```

That one command installs the agent and its host dependencies, attests the
host to SPIRE, and starts it under systemd. From then on the agent
authenticates with its automatically rotating SVID, so restarts reconnect on
their own. See [Deploying agents](/deployment/agents) for details, including
running the agent in Docker.

## Create your first VM

1. Navigate to the VMs page and click **Create VM**
2. Configure the name, CPU cores, memory, disk size, and OS image
3. Optionally paste an SSH public key and **cloud-init user data**
4. Click **Create** — the VM is scheduled onto an available agent
5. Click **Start**, then use the web console to connect

### Cloud-init user data

The optional user-data field is passed to the guest verbatim and runs at
first boot, so you can install packages, write files, create users, or run
arbitrary scripts. Any format cloud-init understands is accepted — a
`#cloud-config` document, a `#!` shell script, `#include` URL lists, a
`## template: jinja` template, or a complete MIME multipart document you
composed yourself:

```yaml
#cloud-config
packages:
  - nginx
write_files:
  - path: /etc/motd
    content: "provisioned by strato\n"
runcmd:
  - systemctl enable --now nginx
```

Your user data is combined with Strato's own provisioning (serial-console
setup, console password, the SSH key from the form); on conflicting
cloud-config keys your values win. Supplying a full MIME multipart document
instead replaces Strato's provisioning entirely — cloud-init then processes
exactly what you wrote, and console/SSH setup is up to you.

New x86_64 QEMU VMs read this configuration from the instance metadata service
by default. ARM64 QEMU and Firecracker VMs default to ISO. See
[Instance metadata and bootstrap](/guide/instance-metadata) for the
compatibility option and the replacement workflow for an existing VM.

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

- [Graphics consoles](/guide/graphics-console) and
  [Windows guests](/guide/windows-guests)
- [Architecture Overview](/architecture/overview)
- [Deployment guides](/deployment/overview)
- [Local Development](/development/local-development)
