# Strato Architecture

This document provides a comprehensive overview of Strato's architecture, design decisions, and technical implementation details.

> [!NOTE]
> This document will be changing drastically as the project is built out.

## Overview

Strato is a private cloud platform built with Vapor that manages virtual machines, storage, and networking components. The control plane exposes a JSON/REST API consumed by a Next.js frontend. Strato runs as both a control plane service, as well as a service on different hypervisors.

## Core Components

### Backend (Swift/Vapor)
The backend is built using Vapor 4, leveraging Swift's performance and safety features:

- **Controllers**: Handle HTTP requests and coordinate business logic
  - `UserController`: Manages user authentication and registration
  - `VMController`: Handles virtual machine lifecycle operations
- **Models**: Define data structures and database schema
  - `User`: User accounts with WebAuthn credentials
  - `VM`: Virtual machine specifications and state
- **Services**: Encapsulate business logic and external integrations
  - `WebAuthnService`: Manages WebAuthn/Passkey authentication flows
  - `SpiceDBService`: Interfaces with the SpiceDB authorization service via its HTTP API
- **Middleware**: Cross-cutting concerns and request processing
  - `SpiceDBAuthMiddleware`: Enforces authorization policies on all requests

### Database Layer

**PostgreSQL with Fluent ORM**
- **Connection**: Managed via FluentPostgresDriver
- **Migrations**: Versioned database schema changes in `Sources/App/Migrations/`
- **Models**: Swift structs that map to database tables
- **Query Builder**: Type-safe database queries through Fluent

**Key Tables:**
- `users`: User accounts and profile information
- `user_credentials`: WebAuthn public keys and device metadata
- `vms`: Virtual machine specifications and metadata
- `sessions`: User session data for authentication state

### Authorization System (SpiceDB)

Strato uses [SpiceDB](https://authzed.com/spicedb) for fine-grained, relationship-based access control, following the Google Zanzibar model.

**Schema Definition** (`spicedb/schema.zed`):

The schema defines a hierarchy — `organization` → `organizational_unit` → `project` → resources — plus `user`, `group`, `environment`, `virtual_machine`, `image`, `volume`, `volume_snapshot`, `resource_quota`, and `api_key` object types. Permissions inherit down the hierarchy: a `project` attaches to its `parent` (an organization or OU), and resource permissions resolve through the project. Abridged excerpt:

```zed
definition user {}

definition organization {
    relation admin: user
    relation member: user

    permission manage_organization = admin
    permission view_organization = admin + member
    permission manage_members = admin
}

definition project {
    relation parent: organization | organizational_unit
    relation admin: user
    relation member: user
    relation viewer: user

    permission manage_project = admin + inherited_admin
    permission create_resources = admin + member + inherited_admin
    permission view_project = admin + member + viewer + inherited_admin + inherited_member
}

definition virtual_machine {
    relation owner: user
    relation project: project
    relation viewer: user
    relation editor: user

    permission create = project->create_resources
    permission read = owner + viewer + editor + project->view_project
    permission update = owner + editor + project->manage_project
    permission delete = owner + project->manage_project
    permission start = owner + editor + project->create_resources
    permission view_console = owner + editor + project->manage_project
}
```

**Integration Points:**
- `SpiceDBAuthMiddleware` (registered globally in `configure.swift`): Intercepts all HTTP requests
  - Skips public routes (health checks, `/login`, `/register`, `/auth/*`, static assets, the agent WebSocket)
  - Requires a session-authenticated user for everything else; system admins bypass permission checks
  - For `/api/vms` routes, maps the HTTP method and path to a permission (`read`, `create`, `update`, `delete`, `start`, `stop`, `restart`, `pause`, `resume`) and checks it against the `virtual_machine` resource; collection-level list/create operations check `view_organization` on the user's current organization
- `SpiceDBService`: Swift wrapper around the SpiceDB HTTP API (`/v1/permissions/check` with full consistency, `/v1/relationships/write`, `/v1/schemas/write`), authenticated with a preshared key; includes helpers for group membership and group-to-project roles
- Controllers perform additional per-resource `checkPermission` calls and write relationships on resource creation — e.g. creating a VM writes `owner` (user) and `project` relationships for the new `virtual_machine`, which inherits organization-admin access transitively through `project->parent`
- Schema loading: a Helm post-install/post-upgrade Job runs `zed schema write`; for local development, `spicedb/init-schema.sh` posts the schema via the HTTP API

### Authentication System (WebAuthn/Passkeys)

Modern passwordless authentication using the WebAuthn standard:

**Server-side** (swift-server/webauthn-swift):
- Registration ceremony handling
- Authentication ceremony validation
- Public key storage and management
- Challenge generation and verification

**Client-side** (WebAuthn JavaScript API):
- Browser credential creation
- Authentication assertion generation
- Platform authenticator integration
- Security key support

**Supported Authenticators:**
- Platform authenticators (Touch ID, Face ID, Windows Hello)
- Cross-platform authenticators (USB security keys)
- Bluetooth and NFC FIDO2 devices

### Frontend Architecture

**Next.js single-page app** (`control-plane/web/`):

- **App Router**: Route groups under `src/app/` (`(auth)`, `(dashboard)`)
- **Components**: Feature components under `src/components/` (vms, agents, images, terminal) built on shadcn/ui + Radix primitives
- **Data layer**: TanStack Query for server state and a typed API client in `src/lib/api`; Zustand for client state
- **Terminal**: xterm.js for interactive VM consoles

**Styling System:**
- **TailwindCSS v4**: Utility-first CSS framework
- **PostCSS**: Processes Tailwind via `@tailwindcss/postcss` as part of the Next.js build

### Virtual Machine Management

**QEMU Integration (via the Agent):**
- **SwiftQEMU**: Swift wrapper over the QEMU Monitor Protocol (QMP) and guest agent
- **Acceleration**: KVM on Linux, Hypervisor.framework (HVF) on macOS
- **VM Lifecycle**: Create, start, stop, restart, delete operations
- **Resource Management**: CPU, memory, and disk allocation

**VM Model Properties:**
```swift
final class VM: Model, Content {
    @ID(key: .id) var id: UUID?
    @Field(key: "name") var name: String
    @Field(key: "description") var description: String?
    @Field(key: "image") var image: String
    @Field(key: "cpu_count") var cpuCount: Int
    @Field(key: "memory_mb") var memoryMB: Int
    @Field(key: "disk_gb") var diskGB: Int
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?
    @Timestamp(key: "updated_at", on: .update) var updatedAt: Date?
}
```

## Development Patterns

### MVC Architecture

- **Models**: Data layer with database integration
- **API Controllers**: Business logic and HTTP request handling, serving JSON to the Next.js frontend
- **Frontend**: Next.js presentation layer (see Frontend Architecture above)

### Dependency Injection

Vapor's built-in container system provides:
- Service registration in `configure.swift`
- Automatic dependency resolution
- Testable service isolation

### Error Handling

- **Vapor's Error Protocol**: Structured error responses
- **HTTP Status Codes**: Appropriate response codes
- **User-Friendly Messages**: Localized error presentation

### Testing Strategy

- **Unit Tests**: Service and model testing
- **Integration Tests**: Full request/response cycles
- **Database Tests**: In-memory test database
- **Vapor Testing**: Built-in testing utilities

## Security Considerations

### Authentication
- **WebAuthn**: Phishing-resistant authentication
- **Session Management**: Secure session storage
- **CSRF Protection**: Built into Vapor forms

### Authorization
- **Fine-grained Permissions**: SpiceDB relationship-based access (Zanzibar model)
- **Middleware Enforcement**: All requests authorized
- **Principle of Least Privilege**: Minimal required permissions

### Data Protection
- **Database Encryption**: PostgreSQL encryption at rest
- **Transport Security**: HTTPS/TLS encryption
- **Input Validation**: Comprehensive request validation

## Deployment Architecture

### Development Environment
```yaml
services:
  app:          # Strato application
  db:           # PostgreSQL database
  spicedb:      # SpiceDB authorization service
  migrate:      # Database migration runner
```

### Production Considerations
- **Container Orchestration**: Kubernetes or Docker Swarm
- **Load Balancing**: Multiple app instances
- **Database Clustering**: PostgreSQL replication
- **Monitoring**: Application and infrastructure metrics
- **Backup Strategy**: Database and configuration backups

## Configuration Management

### Environment Variables
- `DATABASE_URL`: PostgreSQL connection string
- `SPICEDB_ENDPOINT`: SpiceDB HTTP API URL (required)
- `SPICEDB_PRESHARED_KEY`: SpiceDB preshared authentication key
- `STRATO_SECRET_ENCRYPTION_KEY`: 32-byte key (hex or base64) encrypting stored secrets (OIDC client secrets, SSF stream auth tokens) at rest; unset stores them in plaintext with a startup warning
- `WEBAUTHN_RELYING_PARTY_*`: WebAuthn configuration
- `VAPOR_ENV`: Application environment (development/production)

### Configuration Files
- `docker-compose.yml`: Development environment
- `spicedb/schema.zed`: SpiceDB authorization schema
- `control-plane/web/postcss.config.mjs`: TailwindCSS/PostCSS configuration for the frontend

## Performance Characteristics

### Swift/Vapor Benefits
- **Memory Safety**: No buffer overflows or memory leaks
- **Performance**: Compiled language performance
- **Concurrency**: Swift's actor model and async/await
- **Type Safety**: Compile-time error detection

### Database Optimization
- **Connection Pooling**: Efficient database connections
- **Query Optimization**: Fluent query builder efficiency
- **Indexing Strategy**: Optimized database indexes
- **Migration Strategy**: Zero-downtime schema changes

### Frontend Performance
- **Next.js**: Code-splitting and optimized production builds
- **TanStack Query**: Client-side caching and request deduplication
- **TailwindCSS**: Optimized CSS bundle
- **Static Assets**: Efficient caching and delivery

## Future Architecture Considerations

### Scalability
- **Microservices**: Service decomposition options
- **Event-Driven Architecture**: Asynchronous processing
- **Caching Layer**: Redis or similar caching solution
- **CDN Integration**: Global content delivery

### Observability
- **Structured Logging**: JSON-formatted logs
- **Metrics Collection**: Prometheus integration
- **Distributed Tracing**: Request tracing across services
- **Health Checks**: Service availability monitoring

### Integration Points
- **Webhook Support**: External system notifications
- **API Gateway**: Centralized API management
- **Message Queues**: Asynchronous task processing
- **External Storage**: Object storage integration
