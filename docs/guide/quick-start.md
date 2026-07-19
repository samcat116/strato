# Quick Start

Get Strato running in under 5 minutes. Both paths are secure by default:
strong secrets are generated automatically on first run — there is nothing to
change before going to production except your hostname.

## Choose a path

| | Best for | Guide |
|---|---|---|
| **Docker Compose** | A single host, trying Strato out | this page + [details](/deployment/docker-compose) |
| **Kubernetes (Helm)** | Clusters, HA control plane | this page + [details](/deployment/kubernetes) |

(For hacking on Strato itself, see the [development guide](/development/local-development) instead.)

## Docker Compose

```bash
git clone https://github.com/samcat116/strato.git
cd strato/deploy/compose
./setup.sh            # generates .env with strong random secrets
docker compose up -d
```

Visit `http://localhost`. Database migrations and authorization schema
loading run automatically.

For a real hostname, run `./setup.sh --hostname strato.example.com` instead
and terminate TLS in front of the proxy — WebAuthn requires HTTPS for
anything other than localhost. See the
[Docker Compose guide](/deployment/docker-compose).

## Kubernetes (Helm)

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
(ingress, TLS, WebAuthn hostname), see the
[Kubernetes guide](/deployment/kubernetes).

## First login

1. Click **Register** and create an account with a passkey (Touch ID,
   security key, etc.).
2. **The first registered user automatically becomes the system
   administrator** — register yourself before exposing the URL to others.
3. Complete the onboarding flow to create your organization.

## Add a hypervisor

VMs run on agents — Linux hosts with KVM.

1. In the web UI, go to **Agents → Enroll node** and enter a name for the
   host.
2. Copy the generated bootstrap command and run it on the hypervisor host:

   ```bash
   curl -fsSL https://raw.githubusercontent.com/samcat116/strato/main/deploy/agent/install.sh \
     | sudo bash -s -- --control-plane-url 'wss://your-control-plane/agent/ws' \
     --agent-name 'hv-01' --spire-join-token '...' \
     --spire-server-address '...' --trust-domain '...'
   ```

The command installs the agent, attests the host to SPIRE, and starts it
under systemd. The agent then authenticates with a short-lived SVID that
rotates on its own, so restarts reconnect without further setup. See
[Deploying agents](/deployment/agents) for details, including running the
agent in Docker.

## Create your first VM

1. Click **Create VM**
2. Enter a name, set CPU and memory, choose an OS image
3. Optionally paste an SSH public key and **cloud-init user data**
4. Click **Create**, then **Start**
5. Use the web console to access your VM

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

## What's Next?

- [Docker Compose deployment](/deployment/docker-compose)
- [Kubernetes deployment](/deployment/kubernetes)
- [Deploying agents](/deployment/agents)
- [Architecture Overview](/architecture/overview)
