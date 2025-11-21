# What is Strato?

Strato is a fast, secure, and easy to deploy private cloud platform based on battle-tested technologies and built for modern infrastructure. It enables operators to run efficient, secure, and powerful infrastructure with ease.

## Key Features

### Distributed Architecture

Strato uses a **Control Plane** and **Agent** architecture for distributed VM management:

- **Control Plane**: Web UI, REST API, database, and orchestration
- **Agents**: Run on hypervisor nodes, manage VMs via QEMU
- **Communication**: Real-time WebSocket protocol

### Hardware-Accelerated Virtualization

Near-native VM performance through:

- **Linux**: KVM (Kernel-based Virtual Machine)
- **macOS**: Hypervisor.framework (HVF)
- **Cross-platform**: QEMU with TCG for different architectures

### Software-Defined Networking

Production-ready networking on Linux:

- **OVN/OVS**: Software-defined networking with SwiftOVN
- **Features**: Network isolation, security groups, DHCP, routing
- **Multi-tenancy**: Isolated networks for different users/organizations

macOS uses user-mode (SLIRP) networking for development.

### Authentication & Authorization

Enterprise-grade security:

- **WebAuthn/Passkeys**: Modern passwordless authentication
- **Permify**: Fine-grained authorization and permissions
- **RBAC**: Role-based access control for users and organizations

### Intelligent VM Scheduling

Multiple scheduling strategies for optimal resource placement:

- **least_loaded**: Balance VMs across agents (default)
- **best_fit**: Pack VMs to minimize fragmentation
- **round_robin**: Even distribution
- **random**: For testing

### Modern Development Stack

Built with modern technologies:

- **Swift**: Control Plane (Vapor 4) and Agent
- **PostgreSQL**: Database with Fluent ORM
- **HTMX**: Dynamic frontend interactions
- **TailwindCSS**: Utility-first styling
- **Kubernetes**: Production deployment with Helm

## Use Cases

### Development & Testing

- Run multiple OS environments locally
- Test across different platforms
- Isolated development environments

### Private Cloud Infrastructure

- Self-hosted VM infrastructure
- Multi-tenant environments
- Edge computing deployments

### Education & Learning

- Learn cloud infrastructure
- Experiment with networking
- Understand virtualization

## Why Strato?

### Performance

- Hardware acceleration for near-native speed
- Efficient resource utilization
- Intelligent scheduling algorithms

### Security

- Modern authentication (WebAuthn/Passkeys)
- Fine-grained authorization (Permify)
- Network isolation (OVN/OVS)

### Developer Experience

- Hot-reload development (Skaffold)
- Comprehensive documentation
- Active development

### Open Source

- ISC License
- Community-driven
- Transparent development

## Next Steps

- [Getting Started](/guide/getting-started)
- [Quick Start Guide](/guide/quick-start)
- [Architecture Overview](/architecture/overview)
