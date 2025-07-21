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
- `cd agent && swift run StratoAgent` - Run the agent locally

### Shared Package
- `cd shared && swift build` - Build the shared package
- `cd shared && swift test` - Run shared package tests

### JavaScript/Linting Commands (Control Plane)
- `cd control-plane && npm run lint` - Check JavaScript files for syntax errors and style issues
- `cd control-plane && npm run lint:fix` - Automatically fix JavaScript style issues where possible
- `cd control-plane && npm test` - Run JavaScript linting (alias for lint command)

### Docker Development
- `./scripts/prepare-build.sh` - Prepare build context (run before first Docker build)
- `docker compose build` - Build Docker images for both control plane and agent
- `docker compose up control-plane` - Start the control plane with database and Permify
- `docker compose up agent` - Start the agent (requires control plane to be running)
- `docker compose up db` - Start only the PostgreSQL database
- `docker compose up permify` - Start only the Permify authorization service
- `docker compose run migrate` - Run database migrations
- `docker compose down` - Stop all services (add `-v` to wipe database)

### Frontend/Styling (Control Plane)
- TailwindCSS is integrated via SwiftyTailwind and runs automatically during app startup
- CSS input: `control-plane/Resources/styles/app.css`
- CSS output: `control-plane/Public/styles/app.generated.css` (auto-generated)
- Frontend templates are split between Leaf templates (`control-plane/Resources/Views/`) and HTML templates (`control-plane/web/templates/`)

## Architecture

Strato is a distributed private cloud platform with a **Control Plane** and **Agent** architecture. The Control Plane manages the web UI, API, database, and user management, while Agents run on hypervisor nodes and manage VMs via Cloud Hypervisor. Communication between Control Plane and Agents happens via WebSocket.

### Core Components
- **Control Plane**: Vapor 4 web framework with Fluent ORM, web UI, API, user management
- **Agent**: Swift command-line application that manages VMs on hypervisor nodes
- **Shared Package**: Common models, DTOs, and WebSocket protocols used by both Control Plane and Agent
- **Database**: PostgreSQL with Fluent migrations (Control Plane only)
- **Authorization**: Permify for fine-grained access control and permissions (Control Plane only)
- **Frontend**: Leaf templates + HTMX for dynamic interactions (Control Plane only)
- **Styling**: TailwindCSS integrated via SwiftyTailwind (Control Plane only)
- **VM Management**: Cloud Hypervisor API integration (Agent only)
- **Communication**: WebSocket-based messaging between Control Plane and Agents

### Key Architecture Patterns
- **Distributed Architecture**: Control Plane handles web UI/API, Agents handle VM operations on hypervisor nodes
- **WebSocket Communication**: Real-time bidirectional communication between Control Plane and Agents
- **MVC Structure**: Controllers handle HTTP requests, Models define data structures, Views use Leaf templating (Control Plane)
- **Database Integration**: Uses Fluent ORM with PostgreSQL driver and automatic migrations (Control Plane)
- **Authorization**: Permify middleware intercepts all requests, checks permissions via REST API, enforces role-based access control (Control Plane)
- **Agent Management**: Dynamic agent registration, heartbeat monitoring, and VM-to-agent mapping
- **Frontend**: Dual templating approach - Leaf templates in `control-plane/Resources/Views/` for server-rendered content, HTML templates in `control-plane/web/templates/` for HTMX components
- **CSS Processing**: TailwindCSS processes styles from `control-plane/Resources/styles/app.css` and scans both Leaf templates and web templates for classes

### Database (Control Plane)
- VM model includes: name, description, image, CPU, memory, disk specifications
- Migrations are in `control-plane/Sources/App/Migrations/`
- Database connection configured via environment variables (see docker-compose.yml)

### External Integrations
- **Control Plane**: Permify authorization service, HTMX for frontend interactions, xterm.js for terminal interfaces
- **Agent**: Cloud Hypervisor API for VM lifecycle management
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

### Project Structure Notes
- Swift strict concurrency enabled (Swift 6.0)
- Control Plane: Traditional Vapor web application with database
- Agent: Command-line Swift application for hypervisor nodes
- Shared: Common models and WebSocket protocols
- Frontend assets in control-plane only: static files (`control-plane/Public/`) and web templates (`control-plane/web/`)