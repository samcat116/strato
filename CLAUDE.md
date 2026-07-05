# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Working in worktrees (IMPORTANT)

- Sessions almost always run in a git worktree under `.claude/worktrees/<name>/`. Other Claude sessions may be active in sibling worktrees and in the main checkout at the same time.
- NEVER `cd` into or edit `/Users/sam/Projects/Active/strato/` (the main checkout) directly. Derive all paths from your own session's tree (`git rev-parse --show-toplevel`).
- The shell cwd resets between Bash calls: always use absolute paths rooted in your worktree, never bare relative commands like `cd control-plane && ...` chained across calls.
- If you see uncommitted changes you didn't make, they belong to another session's tree — do not fix, complete, or revert them; check `pwd` and re-root yourself first.

## Pull request conventions

- Before creating a PR (and again before declaring work done), run `git fetch origin main && git merge origin/main` and resolve conflicts locally. Parallel sessions land PRs frequently, so branches go stale within hours — don't wait for the merge-conflict notification.
- Review comments from `chatgpt-codex-connector[bot]` that only report Codex usage limits are noise: do not reply, push, or take any action on them.
- Use `/pr-comments` to fetch and address unresolved review threads on the current branch's PR.

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

### Build & test notes
- Swift builds in a fresh worktree start from a cold `.build` and can take 10+ minutes. Run builds/tests with a generous timeout or in the background — never the default 2-minute timeout.
- Prefer `swift test --filter <SuiteName>` while iterating; run the full suite once before creating or updating a PR.
- Control-plane tests run against in-memory SQLite locally — no Postgres/SpiceDB services needed. CI additionally runs a Postgres job, so migrations must work on BOTH (SQLite `ALTER TABLE` cannot combine multiple actions in one migration step; use separate `.update()` calls).
- Known CI flake: the "Test Control Plane (Postgres)" job can crash with Vapor's `ServeCommand did not shutdown before deinit` teardown race. If a failure doesn't reproduce locally and matches this signature, rerun with `gh run rerun <run-id> --failed` instead of debugging.
- CI runs on a self-hosted runner on the strato-dev VM (`/home/sam/actions-runner`). If Swift CI fails with missing-symbol errors your diff can't explain, suspect a stale runner build cache — reproduce locally before debugging source.

### JavaScript/Linting Commands (Control Plane)
- `cd control-plane && npm run lint` - Check JavaScript files for syntax errors and style issues
- `cd control-plane && npm run lint:fix` - Automatically fix JavaScript style issues where possible
- `cd control-plane && npm test` - Run JavaScript linting (alias for lint command)

### Skaffold + Helm Development (Recommended)
- `minikube start --memory=4096 --cpus=2` - Start local Kubernetes cluster
- `cd helm/strato-control-plane && helm dependency build` - Build Helm chart dependencies (run once)
- `skaffold dev` - Start full development environment with hot reload
- `skaffold dev --profile=minimal` - Start minimal environment (Control Plane, PostgreSQL, SpiceDB only)
- `skaffold dev --profile=debug` - Start with debug logging and Swift debug builds
- `skaffold build` - Build container images locally
- `skaffold delete` - Stop and clean up development environment
- `kubectl logs -f deployment/strato-control-plane` - View Control Plane logs
- `kubectl logs -f deployment/strato-agent` - View Agent logs
- `kubectl get pods` - Check status of all services
- `kubectl port-forward service/strato-control-plane 8080:8080` - Access Control Plane at localhost:8080
- `minikube service strato-control-plane --url` - Get external URL for Control Plane
- `minikube stop` - Stop Kubernetes cluster

### Docker Compose
Two compose files with different purposes:
- **Root `docker-compose.yml`**: local development only (fixed dev credentials, in-memory SpiceDB, `DEV_AUTH_BYPASS`). `docker compose up control-plane` starts the control plane with its dependencies. Database migrations run automatically at control-plane startup — there is no separate migrate step.
- **`deploy/compose/`**: the supported single-host deployment. `./setup.sh` generates a `.env` with strong random secrets, then `docker compose up -d`. Uses published images, persistent SpiceDB (PostgreSQL datastore), automatic SpiceDB migration/schema loading, and no auth bypass.

### strato-dev VM (remote sessions at /home/sam/strato)
When running on the strato-dev Linux VM (Ubuntu, headless):
- The user browses from their Mac — never say "open localhost". The UI is served at `https://strato-dev.tail21c16.ts.net` (tailscale serve → nginx :80). k3s occupies :443, so don't try to bind it.
- There are no published container images for this environment; the compose stack builds from source (long Swift build — always run in the background).
- Deployment overrides go in `deploy/compose/docker-compose.override.yml`, never in the tracked compose file.
- Control-plane tests need Postgres: user `strato` / password `strato_password` / db `strato_test`, on port 5433 to avoid colliding with the compose stack.
- First-user registration is a WebAuthn passkey flow that only the user can complete in their browser — hand it off rather than attempting it.
- `sudo` requires a password on this host. If a command needs root, give the user the exact command to run instead of retrying.
- This is a disposable dev VM: when asked to "clean up" deployments, removing all strato-* containers and volumes is in scope.

### Frontend/Styling (Control Plane)
- The frontend is a **Next.js** app (App Router) in `control-plane/web/`, deployed as a separate `strato-frontend` service that consumes the control-plane API.
- Stack: React 19, TanStack Query (server state), Zustand (client state), shadcn/ui components on Radix primitives, and xterm.js for the VM terminal.
- Styling: TailwindCSS v4 via `@tailwindcss/postcss` (see `control-plane/web/postcss.config.mjs`); components configured through `control-plane/web/components.json`.
- Dev server: `cd control-plane/web && npm run dev` (http://localhost:3000).

## Architecture

Strato is a distributed private cloud platform with a **Control Plane** and **Agent** architecture. The Control Plane manages the web UI, API, database, and user management, while Agents run on hypervisor nodes and manage VMs via QEMU with hardware-accelerated virtualization. Communication between Control Plane and Agents happens via WebSocket.

### Core Components
- **Control Plane**: Vapor 4 web framework with Fluent ORM, web UI, API, user management
- **Agent**: Swift command-line application that manages VMs on hypervisor nodes (supports both Linux and macOS)
- **Shared Package**: Common models, DTOs, and WebSocket protocols used by both Control Plane and Agent
- **Database**: PostgreSQL with Fluent migrations (Control Plane only)
- **Authorization**: SpiceDB for fine-grained access control and permissions (Control Plane only)
- **Scheduler**: Intelligent VM placement service with multiple strategies (least-loaded, best-fit, round-robin, random) (Control Plane only)
- **Frontend**: Next.js (App Router) single-page app in `control-plane/web/`, served as the separate `strato-frontend` service (Control Plane only)
- **Styling**: TailwindCSS v4 via PostCSS, with shadcn/ui components (Control Plane only)
- **VM Management**: QEMU integration via SwiftQEMU library (Agent only)
- **Network Management**: Platform-specific networking (Agent only)
  - **Linux**: SwiftOVN integration for OVN/OVS software-defined networking
  - **macOS**: User-mode (SLIRP) networking via QEMU
- **Communication**: WebSocket-based messaging between Control Plane and Agents

### Key Architecture Patterns
- **Distributed Architecture**: Control Plane handles web UI/API, Agents handle VM operations on hypervisor nodes
- **WebSocket Communication**: Real-time bidirectional communication between Control Plane and Agents
- **API + SPA Structure**: Vapor controllers expose a JSON/REST API consumed by the Next.js frontend; Models define data structures (Control Plane)
- **Database Integration**: Uses Fluent ORM with PostgreSQL driver and automatic migrations (Control Plane)
- **Authorization**: SpiceDB middleware intercepts all requests, checks permissions via REST API, enforces relationship-based access control (Control Plane)
- **Agent Management**: Dynamic agent registration, heartbeat monitoring, and VM-to-agent mapping
- **VM Scheduling**: Intelligent hypervisor selection using configurable strategies (least-loaded, best-fit, round-robin, random) with automatic mapping persistence and recovery (Control Plane)
- **Frontend**: Next.js App Router app in `control-plane/web/src/` (`app/` routes, `components/`, `lib/api` client) talking to the control-plane API
- **CSS Processing**: TailwindCSS v4 processed by PostCSS (`control-plane/web/postcss.config.mjs`) as part of the Next.js build

### Database (Control Plane)
- VM model includes: name, description, image, CPU, memory, disk specifications
- Migrations are in `control-plane/Sources/App/Migrations/`
- Database connection configured via environment variables (see docker-compose.yml)

### External Integrations
- **Control Plane**: SpiceDB authorization service, Next.js frontend (TanStack Query + Zustand), xterm.js for terminal interfaces
- **Agent**:
  - **VM Management**: QEMU via SwiftQEMU library for VM lifecycle management
  - **Networking (Linux)**: OVN/OVS via SwiftOVN for software-defined networking
  - **Networking (macOS)**: User-mode (SLIRP) networking built into QEMU
  - **Acceleration (Linux)**: KVM for hardware-assisted virtualization
  - **Acceleration (macOS)**: Hypervisor.framework (HVF) for hardware-assisted virtualization
- **Communication**: WebSocket protocol for Control Plane ↔ Agent messaging

### Authorization System
- **Schema**: Defined in `spicedb/schema.zed` with entities (user, organization, project, vm, ...) and their permissions
- **Middleware**: `SpiceDBAuthMiddleware` intercepts requests and validates permissions
- **Service**: `SpiceDBService` provides Swift wrapper around the SpiceDB HTTP API
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
- **Middleware Integration**: `SpiceDBAuthMiddleware` uses session-authenticated users
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
- **Documentation**: See `docs/architecture/scheduler.md` for detailed information on algorithms and configuration

### Project Structure
```
strato/
├── control-plane/          # API, database, user management, frontend
│   ├── Sources/App/         # Vapor application code (JSON/REST API)
│   ├── Public/              # Static assets (built frontend output)
│   ├── web/                 # Next.js frontend (App Router) source
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
- Swift strict concurrency enabled (Swift 6 language mode, swift-tools-version 6.2, upcoming features `InferIsolatedConformances` and `NonisolatedNonsendingByDefault` enabled)
- Control Plane: Traditional Vapor web application with database
- Agent: Cross-platform Swift application for hypervisor nodes
  - Linux: Production-ready with KVM and OVN/OVS
  - macOS: Development/testing with HVF and user-mode networking
- Shared: Common models and WebSocket protocols
- Frontend in control-plane only: Next.js app source (`control-plane/web/`) and built static assets (`control-plane/Public/`)
