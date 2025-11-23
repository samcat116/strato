# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Development Commands

### Control Plane (Swift/Vapor Commands)
- `cd control-plane && swift build` - Build the control plane application
- `cd control-plane && swift test` - Run control plane tests
- `cd control-plane && swift run` - Run the control plane locally
- `cd control-plane && vapor serve` - Start the Vapor development server (if Vapor CLI is installed)

### Agent (Swift Commands)
- `cd agent && swift build` - Build the agent application
- `cd agent && swift test` - Run agent tests
- `cd agent && swift run StratoAgent` - Run the agent locally (uses HVF on macOS, KVM on Linux)
- `cd agent && swift run StratoAgent --config-file /etc/strato/config.toml` - Run agent with custom config file
- `cd agent && swift run StratoAgent --control-plane-url ws://remote:8080/agent/ws` - Override control plane URL

### Agent Configuration
The agent uses TOML configuration files to set connection and operational parameters:
- **Default config path**: `/etc/strato/config.toml` (production)
- **Fallback config path**: `./config.toml` (development)
- **Example config**: `config.toml.example` (copy to create your configuration)
- **Configuration priority**: Command-line arguments override config file values
- **Required setting**: `control_plane_url` must be specified in config or command line
- **Optional settings**:
  - `qemu_socket_dir` - QEMU socket directory (default: `/var/run/qemu`)
  - `log_level` - Logging level (default: `info`)
  - `network_mode` - Networking mode: `ovn` (Linux), `user` (macOS) (platform-specific defaults)
  - `enable_hvf` - Enable Hypervisor.framework on macOS (default: `true` on macOS)
  - `enable_kvm` - Enable KVM on Linux (default: `true` on Linux)

### Shared Package
- `cd shared && swift build` - Build the shared package
- `cd shared && swift test` - Run shared package tests

### JavaScript/Linting Commands (Control Plane)
- `cd control-plane && npm run lint` - Check JavaScript files for syntax errors and style issues
- `cd control-plane && npm run lint:fix` - Automatically fix JavaScript style issues where possible
- `cd control-plane && npm test` - Run JavaScript linting (alias for lint command)

### Skaffold + Helm Development (Recommended)
- `minikube start --memory=4096 --cpus=2` - Start local Kubernetes cluster
- `cd helm/strato-control-plane && helm dependency build` - Build Helm chart dependencies including PostgreSQL, Valkey, and SpiceDB operator (run once after adding dependencies)
- `skaffold dev` - Start full development environment with hot reload
- `skaffold dev --profile=minimal` - Start minimal environment (Control Plane, PostgreSQL, Valkey, SpiceDB only)
- `skaffold dev --profile=debug` - Start with debug logging and Swift debug builds
- `skaffold build` - Build container images locally
- `skaffold delete` - Stop and clean up development environment
- `kubectl logs -f deployment/strato-control-plane` - View Control Plane logs
- `kubectl logs -f deployment/strato-agent` - View Agent logs
- `kubectl get pods` - Check status of all services
- `kubectl port-forward service/strato-control-plane 8080:8080` - Access Control Plane at localhost:8080
- `minikube service strato-control-plane --url` - Get external URL for Control Plane
- `minikube stop` - Stop Kubernetes cluster

### Sake Development (Local Swift Processes)
Sake is a Swift-based task runner for local development without Kubernetes:
- `sake dev` - Start complete development environment (PostgreSQL, Valkey, SpiceDB, Control Plane, Agent, test VM)
- `sake startPostgres` - Start PostgreSQL database container
- `sake startValkey` - Start Valkey (Redis) cache container
- `sake startSpiceDB` - Start SpiceDB authorization service
- `sake loadSpiceDBSchema` - Load SpiceDB authorization schema
- `sake startControlPlane` - Build and start control-plane service
- `sake startAgent` - Build and start agent service
- `sake createTestVM` - Create a test VM via API
- `sake status` - Show status of all services
- `sake logs` - Show recent logs from all services
- `sake stop` - Stop all running services
- `sake clean` - Stop services and remove all containers and data

**Environment:**
- Services run as local Swift processes (control-plane, agent) and Docker containers (PostgreSQL, Valkey, SpiceDB)
- PostgreSQL: localhost:5432
- Valkey: localhost:6379
- SpiceDB: localhost:8081 (HTTP), localhost:50051 (gRPC)
- Control Plane: localhost:8080
- Logs: /tmp/strato-control-plane.log, /tmp/strato-agent.log

### Docker Development (Legacy - being phased out)
- `./scripts/prepare-build.sh` - Prepare build context (run before first Docker build)
- `docker compose build` - Build Docker images for both control plane and agent
- `docker compose up control-plane` - Start the control plane with database and Permify
- `docker compose up agent` - Start the agent (requires control plane and networking services to be running)
- `docker compose up db` - Start only the PostgreSQL database
- `docker compose up permify` - Start only the Permify authorization service
- `docker compose up ovn-northd ovn-nb-db ovn-sb-db openvswitch` - Start OVN/OVS networking services
- `docker compose run migrate` - Run database migrations
- `docker compose down` - Stop all services (add `-v` to wipe database and networking state)

### Frontend/Styling (Control Plane)
- TailwindCSS is integrated via SwiftyTailwind and runs automatically during app startup
- CSS input: `control-plane/Resources/styles/app.css`
- CSS output: `control-plane/Public/styles/app.generated.css` (auto-generated)
- Frontend templates are split between Leaf templates (`control-plane/Resources/Views/`) and HTML templates (`control-plane/web/templates/`)

## Architecture

Strato is a distributed private cloud platform with a **Control Plane** and **Agent** architecture. The Control Plane manages the web UI, API, database, and user management, while Agents run on hypervisor nodes and manage VMs via QEMU with hardware-accelerated virtualization. Communication between Control Plane and Agents happens via WebSocket.

### Core Components
- **Control Plane**: Vapor 4 web framework with Fluent ORM, web UI, API, user management
- **Agent**: Swift command-line application that manages VMs on hypervisor nodes (supports both Linux and macOS)
- **Shared Package**: Common models, DTOs, and WebSocket protocols used by both Control Plane and Agent
- **Database**: PostgreSQL with Fluent migrations (Control Plane only)
- **Cache**: Valkey (Redis-compatible) for caching and session management (Control Plane only)
- **Authorization**: Permify for fine-grained access control and permissions (Control Plane only)
- **Scheduler**: Intelligent VM placement service with multiple strategies (least-loaded, best-fit, round-robin, random) (Control Plane only)
- **Frontend**: Leaf templates + HTMX for dynamic interactions (Control Plane only)
- **Styling**: TailwindCSS integrated via SwiftyTailwind (Control Plane only)
- **VM Management**: QEMU integration via SwiftQEMU library (Agent only)
- **Network Management**: Platform-specific networking (Agent only)
  - **Linux**: SwiftOVN integration for OVN/OVS software-defined networking
  - **macOS**: User-mode (SLIRP) networking via QEMU
- **Communication**: WebSocket-based messaging between Control Plane and Agents

### Key Architecture Patterns
- **Distributed Architecture**: Control Plane handles web UI/API, Agents handle VM operations on hypervisor nodes
- **WebSocket Communication**: Real-time bidirectional communication between Control Plane and Agents
- **MVC Structure**: Controllers handle HTTP requests, Models define data structures, Views use Leaf templating (Control Plane)
- **Database Integration**: Uses Fluent ORM with PostgreSQL driver and automatic migrations (Control Plane)
- **Authorization**: Permify middleware intercepts all requests, checks permissions via REST API, enforces role-based access control (Control Plane)
- **Agent Management**: Dynamic agent registration, heartbeat monitoring, and VM-to-agent mapping
- **VM Scheduling**: Intelligent hypervisor selection using configurable strategies (least-loaded, best-fit, round-robin, random) with automatic mapping persistence and recovery (Control Plane)
- **Frontend**: Dual templating approach - Leaf templates in `control-plane/Resources/Views/` for server-rendered content, HTML templates in `control-plane/web/templates/` for HTMX components
- **CSS Processing**: TailwindCSS processes styles from `control-plane/Resources/styles/app.css` and scans both Leaf templates and web templates for classes

### Database (Control Plane)
- VM model includes: name, description, image, CPU, memory, disk specifications
- Migrations are in `control-plane/Sources/App/Migrations/`
- Database connection configured via environment variables (see docker-compose.yml)

### External Integrations
- **Control Plane**: Valkey (Redis) for caching, Permify authorization service, HTMX for frontend interactions, xterm.js for terminal interfaces
- **Agent**:
  - **VM Management**: QEMU via SwiftQEMU library for VM lifecycle management
  - **Networking (Linux)**: OVN/OVS via SwiftOVN for software-defined networking
  - **Networking (macOS)**: User-mode (SLIRP) networking built into QEMU
  - **Acceleration (Linux)**: KVM for hardware-assisted virtualization
  - **Acceleration (macOS)**: Hypervisor.framework (HVF) for hardware-assisted virtualization
- **Communication**: WebSocket protocol for Control Plane ↔ Agent messaging

### Authorization System
- **Schema**: Defined in `permify/schema.perm` with entities (user, organization, vm) and permissions (create, read, update, delete, start, stop, restart)
- **Middleware**: `PermifyAuthMiddleware` intercepts requests and validates permissions
- **Service**: `PermifyService` provides Swift wrapper around Permify REST API
- **Authentication**: Session-based authentication with WebAuthn/Passkeys
- **Relationships**: Automatically creates ownership relationships when VMs are created

### Authentication System (WebAuthn/Passkeys)
- **WebAuthn Library**: Uses swift-server/webauthn-swift for server-side Passkey implementation
- **User Management**: Full user CRUD with username, email, display name
- **Passkey Storage**: UserCredential model stores public keys, sign counts, and device metadata
- **Challenge Management**: Temporary challenge storage for registration/authentication flows
- **Session Management**: Vapor session-based authentication with Fluent session storage
- **Frontend Integration**: JavaScript WebAuthn client (`/js/webauthn.js`) handles browser API calls
- **UI Components**: Registration (`/register`) and login (`/login`) pages with Passkey flows
- **Middleware Integration**: `PermifyAuthMiddleware` now uses session-authenticated users
- **Environment Configuration**: WebAuthn relying party settings via environment variables:
  - `WEBAUTHN_RELYING_PARTY_ID` (default: localhost)
  - `WEBAUTHN_RELYING_PARTY_NAME` (default: Strato)
  - `WEBAUTHN_RELYING_PARTY_ORIGIN` (default: http://localhost:8080)

### VM Scheduler System
- **Scheduler Service**: Intelligent VM placement on hypervisor nodes based on resource availability and configurable strategies
- **Scheduling Strategies**:
  - `least_loaded` (default): Distributes VMs across agents with lowest utilization (load balancing)
  - `best_fit`: Packs VMs onto agents with least remaining capacity (bin-packing, resource consolidation)
  - `round_robin`: Evenly distributes VMs in circular fashion
  - `random`: Random selection from available agents (testing/development)
- **Resource Tracking**: Real-time monitoring of CPU, memory, and disk availability on each agent
- **Persistent Mapping**: VM-to-agent assignments stored in database (`vm.hypervisorId`) and restored on startup
- **Agent Filtering**: Only online agents with sufficient resources are considered for placement
- **Environment Configuration**: Default strategy via environment variable:
  - `SCHEDULING_STRATEGY` (default: least_loaded, options: least_loaded, best_fit, round_robin, random)
- **Documentation**: See `docs/SCHEDULER.md` for detailed information on algorithms and configuration

### Project Structure
```
strato/
├── control-plane/          # Web UI, API, database, user management
│   ├── Sources/App/         # Vapor application code
│   ├── Resources/           # Templates and styles
│   ├── Public/              # Static files
│   ├── web/                 # HTMX templates
│   ├── Package.swift        # Control plane dependencies
│   └── Dockerfile           # Control plane container
├── agent/                   # Hypervisor node agent
│   ├── Sources/StratoAgent/ # Agent application code
│   ├── Package.swift        # Agent dependencies
│   └── Dockerfile           # Agent container
├── shared/                  # Common models and protocols
│   ├── Sources/StratoShared/ # Shared Swift code
│   └── Package.swift        # Shared package definition
├── docker-compose.yml       # Multi-service setup
└── CLAUDE.md               # This file
```

### QEMU Integration (Agent)
The agent supports both Linux and macOS platforms with hardware-accelerated virtualization:

#### Linux (KVM)
- **Acceleration**: KVM (Kernel-based Virtual Machine) for near-native performance
- **Architecture Support**: x86_64 and ARM64 guests (same-arch only with KVM)
- **SwiftQEMU Library**: Swift wrapper for QEMU Monitor Protocol (QMP) and guest agent
- **VM Management**: Full lifecycle operations - create, start, stop, pause, resume, delete via QMP
- **System Requirements**:
  - Linux with KVM kernel module (`/dev/kvm` access)
  - QEMU system packages (`qemu-system-x86_64`, `qemu-system-aarch64`, `qemu-utils`)
  - glib-2.0 libraries for SwiftQEMU integration

#### macOS (Hypervisor.framework)
- **Acceleration**: Hypervisor.framework (HVF) for near-native performance
- **Architecture Support**: x86_64 on Intel Macs, ARM64 on Apple Silicon (same-arch only with HVF)
- **SwiftQEMU Library**: Same Swift wrapper for QEMU, with `-accel hvf` instead of `-accel kvm`
- **VM Management**: Full lifecycle operations identical to Linux
- **Limitations**:
  - Same-architecture VMs only (no cross-arch acceleration)
  - User-mode networking only (no TAP/OVN support)
  - Cross-platform VMs run under TCG emulation (slow)
- **System Requirements**:
  - macOS 14.0 or later
  - QEMU installed via Homebrew: `brew install qemu`
  - Xcode Command Line Tools

### Networking Integration (Agent)

#### Linux - SwiftOVN (OVN/OVS)
- **Production-Ready**: Full OVN/OVS integration with software-defined networking
- **SwiftOVN Library**: Native Swift wrapper for OVN/OVS JSON-RPC APIs over Unix sockets
- **Network Features**:
  - Logical switch and port management
  - VM network attachment/detachment with TAP interfaces
  - Security groups and ACLs
  - DHCP and routing services
  - Multi-tenant network isolation
- **System Requirements**:
  - OVN packages (`ovn-central`, `ovn-host`, `ovn-common`)
  - OVS packages (`openvswitch-switch`, `openvswitch-common`)
  - Network capabilities (`NET_ADMIN`, `SYS_ADMIN`)
  - Access to OVN/OVS Unix domain sockets

#### macOS - User-Mode Networking (SLIRP)
- **User-Mode Only**: QEMU's built-in SLIRP networking (no external dependencies)
- **Automatic Configuration**: VMs get automatic DHCP in the 10.0.2.0/24 range
- **Outbound Connectivity**: VMs can access the internet and host via NAT
- **Limitations**:
  - No VM-to-VM communication
  - No inbound connections from host/network to VM
  - No advanced features (VLANs, ACLs, multi-tenancy)
  - No TAP interface support (macOS kernel restrictions)
- **Use Case**: Development and testing, single-VM workloads
- **Future Enhancement**: VMnet.framework integration possible (requires entitlements)

### Platform Support Matrix

| Feature | Linux | macOS |
|---------|-------|-------|
| **VM Management** | ✅ Full | ✅ Full |
| **Hardware Acceleration** | ✅ KVM | ✅ HVF |
| **Same-arch VMs** | ✅ Near-native speed | ✅ Near-native speed |
| **Cross-arch VMs** | ⚠️ TCG only (slow) | ⚠️ TCG only (slow) |
| **Networking** | ✅ OVN/OVS (TAP) | ⚠️ User-mode only |
| **VM-to-VM Communication** | ✅ Yes | ❌ No |
| **Network Isolation** | ✅ Yes | ❌ No |
| **Inbound Connections** | ✅ Yes | ❌ No |
| **Production Ready** | ✅ Yes | ⚠️ Dev/Test only |

### Project Structure Notes
- Swift strict concurrency enabled (Swift 6.0)
- Control Plane: Traditional Vapor web application with database
- Agent: Cross-platform Swift application for hypervisor nodes
  - Linux: Production-ready with KVM and OVN/OVS
  - macOS: Development/testing with HVF and user-mode networking
- Shared: Common models and WebSocket protocols
- Frontend assets in control-plane only: static files (`control-plane/Public/`) and web templates (`control-plane/web/`)
