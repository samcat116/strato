# Strato

[![Build Status](https://github.com/samcat116/strato/actions/workflows/build.yaml/badge.svg)](https://github.com/samcat116/strato/actions/workflows/build.yaml)
[![License: FSL-1.1-MIT](https://img.shields.io/badge/License-FSL--1.1--MIT-blue.svg)](LICENSE.md)
[![Swift 6.3](https://img.shields.io/badge/Swift-6.3%2B-orange.svg)](https://swift.org)

Strato is a fast, secure, and easy to deploy private cloud platform based on battle tested technologies and built for modern infrastructure. It enables operators to run efficient, secure, and powerful infrastructure easily.

## Features

- 🚀 **High Performance**: Swift control plane and agent, QEMU with KVM/HVF acceleration
- 🔒 **WebAuthn/Passkey Authentication**: Modern passwordless authentication
- 🏗️ **VM Management**: Full lifecycle management via QEMU (and Firecracker on Linux)
- 🔐 **Fine-grained Authorization**: SpiceDB-backed relationship-based access control
- 🛡️ **Secure by Default**: Deployments generate strong secrets on first run — no baked-in credentials
- 🌐 **Software-defined Networking**: OVN/OVS integration on Linux hypervisors
- 📊 **PostgreSQL Backend**: Reliable data persistence with Fluent ORM

## Quick Start

Secrets (database password, authorization keys) are generated automatically in
both paths — a fresh install is secure by default with zero secret
configuration.

### Single host (Docker Compose)

```bash
git clone https://github.com/samcat116/strato.git
cd strato/deploy/compose
./setup.sh            # generates .env with strong random secrets
docker compose up -d
```

Open `http://localhost` and register — the first user automatically becomes
the system administrator. Database migrations and authorization schema loading
happen automatically. See [deploy/compose/README.md](deploy/compose/README.md)
for real-hostname/TLS deployments.

### Kubernetes (Helm)

```bash
git clone https://github.com/samcat116/strato.git
cd strato/helm/strato-control-plane
helm dependency build
helm install strato .
```

Strong credentials are auto-generated on first install and reused across
upgrades (stored in the `<release>-strato-credentials` secret). See
[helm/strato-control-plane/README.md](helm/strato-control-plane/README.md)
for production values (ingress, TLS, WebAuthn hostname).

### Adding a hypervisor

In the web UI: **Agents → Create Registration Token**, then run the shown
command on the hypervisor host:

```bash
strato-agent join 'ws://your-control-plane/agent/ws?token=...&name=...'
```

The agent registers, persists its rotated reconnect token, and reconnects
automatically after restarts.

### Local development

The three Swift packages build and test with no infrastructure at all — the
control-plane test suite runs against in-memory SQLite:

```bash
swift test --package-path control-plane
swift test --package-path agent
swift test --package-path shared
```

To run the full stack, use the Docker Compose deployment above; it can build
the control plane from your working tree instead of pulling the published
image. See the [local development guide](docs/development/local-development.md).

## Core Technologies

- **[Swift](https://swift.org)** - Modern, safe, and performant programming language
- **[Vapor](https://vapor.codes)** - Server-side Swift web framework
- **[QEMU](https://www.qemu.org)** - VM execution with KVM (Linux) / HVF (macOS) acceleration
- **[PostgreSQL](https://www.postgresql.org)** - Advanced open source database
- **[SpiceDB](https://authzed.com/spicedb)** - Zanzibar-style fine-grained authorization
- **[OVN/OVS](https://www.ovn.org)** - Software-defined networking (Linux)
- **[Next.js](https://nextjs.org)** - Web frontend

## Authentication

Strato uses WebAuthn/Passkeys for secure, passwordless authentication. Users can register and authenticate using:

- Security keys (YubiKey, etc.)
- Platform authenticators (Touch ID, Face ID, Windows Hello)
- Cross-platform authenticators

The WebAuthn origin must exactly match the URL users visit; both deployment
paths configure it from your hostname (see the deployment docs).

## Project Structure

```
strato/
├── control-plane/       # Web UI, API, database, user management (Vapor)
│   └── web/             # Next.js frontend
├── agent/               # Hypervisor node agent (QEMU/Firecracker)
├── shared/              # Common models and WebSocket protocol
├── deploy/compose/      # Single-host Docker Compose deployment
├── helm/                # Kubernetes Helm chart
├── spicedb/             # Authorization schema
└── docs/                # VitePress documentation site
```

## Documentation

Full documentation lives in [docs/](docs/) (VitePress site), including
architecture, deployment guides, and troubleshooting.

## Contributing

1. Fork the repository
2. Create a feature branch: `git checkout -b feature/amazing-feature`
3. Make your changes and add tests
4. Ensure all tests pass: `swift test`
5. Submit a pull request

## License

This project is licensed under the Functional Source License 1.1 with MIT Future License - see the [LICENSE.md](LICENSE.md) file for details.

## Support

- 📖 [Documentation](docs/)
- 🐛 [Report Issues](https://github.com/samcat116/strato/issues)
- 💬 [Discussions](https://github.com/samcat116/strato/discussions)
