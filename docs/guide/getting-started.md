# Getting Started

This guide will help you set up Strato for development or production use.

## Prerequisites

### Required

- **Kubernetes**: minikube, kind, or production cluster
- **Helm**: v3.0 or later
- **Skaffold**: v2.0 or later (for development)
- **Docker**: For building container images

### Platform-Specific

#### Linux (Production)

- KVM kernel module (`/dev/kvm` access)
- QEMU packages: `qemu-system-x86_64`, `qemu-utils`
- OVN/OVS packages: `ovn-central`, `ovn-host`, `openvswitch-switch`
- Network capabilities: `NET_ADMIN`, `SYS_ADMIN`

#### macOS (Development)

- macOS 14.0 or later
- QEMU: `brew install qemu`
- Xcode Command Line Tools

### Swift Development (Optional)

- Swift 6.0 or later
- Vapor CLI (optional): `brew install vapor`

## Installation

### Development Setup with Skaffold

1. **Start Kubernetes cluster:**

```bash
minikube start --memory=4096 --cpus=2
```

2. **Clone the repository:**

```bash
git clone https://github.com/samcat116/strato.git
cd strato
```

3. **Build Helm dependencies:**

```bash
cd helm/strato
helm dependency build
cd ../..
```

4. **Start development environment:**

```bash
# Full environment
skaffold dev

# Or minimal environment (Control Plane + PostgreSQL + Permify only)
skaffold dev --profile=minimal

# Or with debug logging
skaffold dev --profile=debug
```

The development environment includes:
- Control Plane (web UI and API)
- PostgreSQL database
- Permify authorization service
- Agents (in full mode)
- OVN/OVS networking (Linux only, in full mode)

### Production Deployment

See the [Deployment Guide](/deployment/overview) for production installation instructions.

## Accessing the Application

### During Development

Get the Control Plane URL:

```bash
# Port forward (recommended)
kubectl port-forward service/strato-control-plane 8080:8080

# Or get minikube URL
minikube service strato-control-plane --url
```

Access the web UI at `http://localhost:8080`

### View Logs

```bash
# Control Plane logs
kubectl logs -f deployment/strato-control-plane

# Agent logs
kubectl logs -f deployment/strato-agent

# All pods
kubectl get pods
```

## First Steps

### 1. Register a User

Visit the registration page and create an account using WebAuthn/Passkeys:

1. Navigate to `/register`
2. Enter username, email, and display name
3. Click "Register with Passkey"
4. Follow your browser's prompts to create a passkey

### 2. Create a Virtual Machine

After logging in:

1. Navigate to the VMs page
2. Click "Create VM"
3. Configure:
   - Name and description
   - CPU cores and memory
   - Disk size
   - OS image
4. Click "Create"

The VM will be automatically scheduled to an available agent.

### 3. Start and Connect

1. Click "Start" on your VM
2. Wait for it to boot
3. Use the web console to interact with your VM

## Development Workflow

### Hot Reload

Skaffold provides automatic rebuilding and redeployment:

1. Edit Swift code in `control-plane/` or `agent/`
2. Save the file
3. Skaffold detects changes and rebuilds
4. New containers are deployed automatically

### Running Tests

```bash
# Control Plane tests
cd control-plane
swift test

# Agent tests
cd agent
swift test

# Shared package tests
cd shared
swift test

# JavaScript linting
cd control-plane
npm run lint
```

### Building Locally

```bash
# Control Plane
cd control-plane
swift build

# Agent
cd agent
swift build
```

## Next Steps

- [Quick Start Guide](/guide/quick-start)
- [Architecture Overview](/architecture/overview)
- [Development with Skaffold](/development/skaffold)
- [Troubleshooting](/development/troubleshooting-k8s)
