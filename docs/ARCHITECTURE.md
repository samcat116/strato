# Strato Architecture

This document provides a comprehensive overview of Strato's architecture, design decisions, and technical implementation details.

> [!NOTE]
> This document will be changing drastically as the project is built out.

## Overview

Strato is a private cloud platform built with Vapor that manages virtual machines, storage, and networking components. The project uses HTMX for its frontend framework. Strato runs as both a control plane service, as well as a service on different hypervisors.

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
  - `PermifyService`: Interfaces with the Permify authorization service
- **Middleware**: Cross-cutting concerns and request processing
  - `PermifyAuthMiddleware`: Enforces authorization policies on all requests

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

### Authorization System (Permify)

Strato uses Permify for fine-grained, relationship-based access control:

**Schema Definition** (`permify/schema.perm`):
```
entity user {}
entity organization {}
entity vm {}

relation owner of organization
relation member of organization
relation owner of vm
relation organization of vm

action create on vm
action read on vm
action update on vm
action delete on vm
action start on vm
action stop on vm
action restart on vm

permission create on vm = owner(organization.owner) or member(organization.owner)
permission read on vm = owner or organization.member
permission update on vm = owner
permission delete on vm = owner
permission start on vm = owner or organization.member
permission stop on vm = owner or organization.member
permission restart on vm = owner or organization.member
```

**Integration Points:**
- `PermifyAuthMiddleware`: Intercepts all HTTP requests
- Authorization checks before VM operations
- Automatic relationship creation on VM creation
- Session-based user context

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

**Hybrid Templating Approach:**

1. **Leaf Templates** (`Resources/Views/`):
   - Server-rendered HTML pages
   - Traditional form-based interactions
   - SEO-friendly content delivery

2. **HTMX Components** (`web/templates/`):
   - Dynamic partial updates
   - AJAX-like interactions without JavaScript
   - Real-time UI updates

**Styling System:**
- **TailwindCSS**: Utility-first CSS framework
- **SwiftyTailwind**: Swift integration for automatic CSS processing
- **Build Process**: Scans both Leaf and HTMX templates for classes
- **Output**: Generates optimized CSS bundle

### Virtual Machine Management

**Cloud Hypervisor Integration:**
- **OpenAPI Specification**: `cloud-hypervisor-openapi.yaml`
- **REST API**: HTTP calls to Cloud Hypervisor daemon
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
- **Views**: Presentation layer using Leaf and HTMX
- **Controllers**: Business logic and HTTP request handling

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
- **Fine-grained Permissions**: Permify relationship-based access
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
  permify:      # Authorization service
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
- `PERMIFY_ENDPOINT`: Authorization service URL
- `WEBAUTHN_RELYING_PARTY_*`: WebAuthn configuration
- `VAPOR_ENV`: Application environment (development/production)

### Configuration Files
- `docker-compose.yml`: Development environment
- `permify/config.yaml`: Permify service configuration
- `tailwind.config.js`: CSS framework configuration

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
- **HTMX**: Minimal JavaScript overhead
- **TailwindCSS**: Optimized CSS bundle
- **Static Assets**: Efficient caching and delivery
- **Progressive Enhancement**: Graceful degradation

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
