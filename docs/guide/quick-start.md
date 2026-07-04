# Quick Start

Get Strato running in under 5 minutes. Both paths are secure by default:
strong secrets are generated automatically on first run — there is nothing to
change before going to production except your hostname.

## Choose a path

| | Best for | Guide |
|---|---|---|
| **Docker Compose** | A single host, trying Strato out | this page + [details](/deployment/docker-compose) |
| **Kubernetes (Helm)** | Clusters, HA control plane | this page + [details](/deployment/kubernetes) |

(For hacking on Strato itself, see the [development guide](/development/skaffold) instead.)

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

VMs run on agents — Linux hosts with KVM (or macOS hosts with HVF, for
development).

1. In the web UI, go to **Agents → Create Registration Token** and enter a
   name for the host.
2. Copy the generated command and run it on the hypervisor host:

   ```bash
   strato-agent join 'ws://your-control-plane/agent/ws?token=...&name=...'
   ```

The token is single-use and expires; the agent stores its rotated reconnect
credential in a state file, so plain `strato-agent` restarts reconnect
automatically. See [Deploying agents](/deployment/agents) for details,
including running the agent in Docker.

## Create your first VM

1. Click **Create VM**
2. Enter a name, set CPU and memory, choose an OS image
3. Click **Create**, then **Start**
4. Use the web console to access your VM

## What's Next?

- [Docker Compose deployment](/deployment/docker-compose)
- [Kubernetes deployment](/deployment/kubernetes)
- [Deploying agents](/deployment/agents)
- [Architecture Overview](/architecture/overview)
