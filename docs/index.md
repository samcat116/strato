---
layout: home

hero:
  name: "Strato"
  text: "Private Cloud Platform"
  tagline: Fast, secure, and easy to deploy private cloud built with Swift
  actions:
    - theme: brand
      text: Get Started
      link: /guide/getting-started
    - theme: alt
      text: View on GitHub
      link: https://github.com/samcat116/strato
  image:
    src: /logo.svg
    alt: Strato

features:
  - icon: 🚀
    title: Built with Swift
    details: Leverages Swift's performance and safety for both Control Plane (Vapor) and Agent components
  - icon: 🔒
    title: Secure by Design
    details: WebAuthn/Passkeys authentication and a built-in Cedar-based IAM system with roles, guardrails, and decision logs
  - icon: ⚡
    title: Hardware Accelerated
    details: KVM acceleration on supported Linux hypervisor nodes
  - icon: 🌐
    title: Software-Defined Networking
    details: OVN/OVS integration on Linux for multi-tenant network isolation and advanced networking features
  - icon: 📊
    title: Intelligent Scheduling
    details: Multiple scheduling strategies (least-loaded, best-fit, round-robin) for optimal resource utilization
  - icon: 🛠️
    title: Easy to Deploy
    details: Single-host Docker Compose or a Kubernetes Helm chart, both secure by default with a comprehensive API and modern web UI
---

## Quick Start

```bash
git clone https://github.com/samcat116/strato.git
cd strato/deploy/compose
./setup.sh            # generates .env with strong random secrets
docker compose up -d
```

Visit `http://localhost` and register — the first user becomes the system
administrator. For clusters, see the
[Kubernetes guide](/deployment/kubernetes).

## Architecture Overview

Strato uses a distributed **Control Plane** and **Agent** architecture:

- **Control Plane**: Vapor-based application owning the API, database, scheduler, and IAM
- **Agents**: Swift daemons on hypervisor nodes, managing VMs (QEMU) and sandboxes (Firecracker)
- **Communication**: WebSocket-based declarative state sync between components

## Platform Support

| Feature | Linux | macOS |
|---------|-------|-------|
| VM Management | ✅ Full | ❌ No hypervisor driver |
| Hardware Acceleration | ✅ KVM | ❌ Not available |
| Networking | ✅ OVN/OVS | ⚠️ Development tooling only |
| Production Ready | ✅ Yes | ❌ No |

## Learn More

- [Architecture Overview](/architecture/overview)
- [Local Development](/development/local-development)
- [Deployment Guide](/deployment/overview)
- [Logging & Log Visibility](/deployment/logging)
- [Observability: Metrics & Alerts](/deployment/observability)
