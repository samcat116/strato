# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Development Commands

### Swift/Vapor Commands
- `swift build` - Build the Swift application
- `swift test` - Run Swift tests
- `swift run` - Run the application locally
- `vapor serve` - Start the Vapor development server (if Vapor CLI is installed)

### Docker Development
- `docker compose build` - Build Docker images
- `docker compose up app` - Start the application with database and Permify
- `docker compose up db` - Start only the PostgreSQL database
- `docker compose up permify` - Start only the Permify authorization service
- `docker compose run migrate` - Run database migrations
- `docker compose down` - Stop all services (add `-v` to wipe database)

### Frontend/Styling
- TailwindCSS is integrated via SwiftyTailwind and runs automatically during app startup
- CSS input: `Resources/styles/app.css`
- CSS output: `Public/styles/app.generated.css` (auto-generated)
- Frontend templates are split between Leaf templates (`Resources/Views/`) and HTML templates (`web/templates/`)

## Architecture

Strato is a private cloud platform built with Vapor (Swift web framework) that manages virtual machines through the Cloud Hypervisor API. The project uses a hybrid frontend approach with both Leaf templating and HTMX.

### Core Components
- **Backend**: Vapor 4 web framework with Fluent ORM
- **Database**: PostgreSQL with Fluent migrations
- **Authorization**: Permify for fine-grained access control and permissions
- **Frontend**: Leaf templates + HTMX for dynamic interactions
- **Styling**: TailwindCSS integrated via SwiftyTailwind
- **VM Management**: Integration with Cloud Hypervisor API (OpenAPI spec included)

### Key Architecture Patterns
- **MVC Structure**: Controllers handle HTTP requests, Models define data structures, Views use Leaf templating
- **Database Integration**: Uses Fluent ORM with PostgreSQL driver and automatic migrations
- **Authorization**: Permify middleware intercepts all requests, checks permissions via REST API, enforces role-based access control
- **Frontend**: Dual templating approach - Leaf templates in `Resources/Views/` for server-rendered content, HTML templates in `web/templates/` for HTMX components
- **CSS Processing**: TailwindCSS processes styles from `Resources/styles/app.css` and scans both Leaf templates and web templates for classes

### Database
- VM model includes: name, description, image, CPU, memory, disk specifications
- Migrations are in `Sources/App/Migrations/`
- Database connection configured via environment variables (see docker-compose.yml)

### External Integrations
- Cloud Hypervisor API for VM lifecycle management
- xterm.js for terminal interfaces
- HTMX for dynamic frontend interactions
- Permify authorization service for access control

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

### Project Structure Notes
- Swift strict concurrency enabled
- Uses Swift 6.0 toolchain
- Frontend assets split between traditional Vapor static files (`Public/`) and web templates (`web/`)