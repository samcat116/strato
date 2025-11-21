# Quick Start

Get Strato running in under 5 minutes.

## Prerequisites

- Docker
- Kubernetes (minikube recommended)
- Helm
- Skaffold

## Installation

```bash
# 1. Start minikube
minikube start --memory=4096 --cpus=2

# 2. Clone repository
git clone https://github.com/samcat116/strato.git
cd strato

# 3. Build Helm dependencies
cd helm/strato && helm dependency build && cd ../..

# 4. Start Strato
skaffold dev
```

## Access the Application

```bash
# Port forward to localhost
kubectl port-forward service/strato-control-plane 8080:8080
```

Visit `http://localhost:8080`

## Create Your First VM

1. **Register**: Click "Register" and create an account with a passkey
2. **Login**: Authenticate with your passkey
3. **Create VM**:
   - Click "Create VM"
   - Enter a name
   - Set CPU: 2 cores, Memory: 2GB
   - Choose an OS image
   - Click "Create"
4. **Start VM**: Click "Start" on your new VM
5. **Connect**: Use the web console to access your VM

## Common Commands

```bash
# View logs
kubectl logs -f deployment/strato-control-plane

# Check pods
kubectl get pods

# Restart deployment
kubectl rollout restart deployment/strato-control-plane

# Stop Strato
# Press Ctrl+C in the skaffold dev terminal

# Clean up
skaffold delete
minikube stop
```

## What's Next?

- [Complete Getting Started Guide](/guide/getting-started)
- [Architecture Overview](/architecture/overview)
- [Development Guide](/development/skaffold)

## Troubleshooting

### Pods not starting?

```bash
kubectl describe pod <pod-name>
kubectl logs <pod-name>
```

### Database issues?

```bash
# Restart database
kubectl delete pod -l app=postgresql

# Check database logs
kubectl logs -l app=postgresql
```

### Need to reset everything?

```bash
skaffold delete
minikube delete
minikube start --memory=4096 --cpus=2
```

See [Troubleshooting Guide](/development/troubleshooting-k8s) for more help.
