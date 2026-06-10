# Strato

[![Build Status](https://github.com/samcat116/strato/actions/workflows/build.yaml/badge.svg)](https://github.com/samcat116/strato/actions/workflows/build.yaml)
[![License: FSL-1.1-MIT](https://img.shields.io/badge/License-FSL--1.1--MIT-blue.svg)](LICENSE.md)
[![Swift 6.2](https://img.shields.io/badge/Swift-6.2%2B-orange.svg)](https://swift.org)
[![Platform](https://img.shields.io/badge/Platform-macOS%2013%2B-lightgrey.svg)](https://www.apple.com/macos/)

Strato is a fast, secure, and easy to deploy private cloud platform based on battle tested technologies and built for modern infrastructure. It enables operators to run efficient, secure, and powerful infrastructure easily.

## Features

- 🚀 **High Performance**: Built with Swift and Vapor for exceptional performance
- 🔒 **WebAuthn/Passkey Authentication**: Modern passwordless authentication
- 🏗️ **VM Management**: Full lifecycle management through Cloud Hypervisor integration
- 🌐 **Modern Web Interface**: Dynamic HTMX-powered frontend with TailwindCSS
- 🔐 **Fine-grained Authorization**: Powered by Permify for role-based access control
- 🐳 **Container Ready**: Docker and Docker Compose support for easy deployment
- 📊 **PostgreSQL Backend**: Reliable data persistence with Fluent ORM

## Quick Start

### Prerequisites

- Swift 6.2 or later
- Docker and Docker Compose
- PostgreSQL (if running locally)

### Using Docker Compose (Recommended)

1. Clone the repository:
   ```bash
   git clone https://github.com/samcat116/strato.git
   cd strato
   ```

2. Start all services:
   ```bash
   docker compose up app
   ```

3. Run database migrations:
   ```bash
   docker compose run migrate
   ```

4. Access the application at `http://localhost:8080`

### Local Development

1. Install dependencies:
   ```bash
   swift package resolve
   ```

2. Start supporting services:
   ```bash
   docker compose up db permify
   ```

3. Run migrations:
   ```bash
   swift run App migrate
   ```

4. Start the development server:
   ```bash
   swift run
   ```

## Core Technologies

- **[Swift](https://swift.org)** - Modern, safe, and performant programming language
- **[Vapor](https://vapor.codes)** - Server-side Swift web framework
- **[Cloud Hypervisor](https://www.cloudhypervisor.org/)** - Modern VMM for VM management
- **[PostgreSQL](https://www.postgresql.org)** - Advanced open source database
- **[Permify](https://permify.co)** - Authorization service for fine-grained access control
- **[HTMX](https://htmx.org)** - Dynamic web interfaces without complex JavaScript
- **[TailwindCSS](https://tailwindcss.com)** - Utility-first CSS framework

## Authentication

Strato uses WebAuthn/Passkeys for secure, passwordless authentication. Users can register and authenticate using:

- Security keys (YubiKey, etc.)
- Platform authenticators (Touch ID, Face ID, Windows Hello)
- Cross-platform authenticators

## Project Structure

```
strato/
├── Sources/App/           # Swift application source
│   ├── Controllers/       # HTTP request handlers
│   ├── Models/           # Database models
│   ├── Services/         # Business logic services
│   └── configure.swift   # Application configuration
├── Resources/Views/      # Leaf templates
├── Public/              # Static assets
├── web/                 # HTMX templates and components
├── permify/             # Authorization schema and config
└── docker-compose.yml   # Development environment
```

## Architecture

For detailed technical architecture information, see [ARCHITECTURE.md](ARCHITECTURE.md).

## Development

### Available Commands

- `swift build` - Build the application
- `swift test` - Run tests
- `swift run` - Start the application
- `docker compose build` - Build Docker images
- `docker compose up app` - Start with all dependencies
- `docker compose run migrate` - Run database migrations

### Environment Variables

Key configuration options:

- `DATABASE_URL` - PostgreSQL connection string
- `PERMIFY_ENDPOINT` - Permify service endpoint
- `WEBAUTHN_RELYING_PARTY_ID` - WebAuthn relying party identifier
- `WEBAUTHN_RELYING_PARTY_ORIGIN` - WebAuthn origin URL

## Contributing

1. Fork the repository
2. Create a feature branch: `git checkout -b feature/amazing-feature`
3. Make your changes and add tests
4. Ensure all tests pass: `swift test`
5. Submit a pull request

## License

This project is licensed under the Functional Source License 1.1 with MIT Future License - see the [LICENSE.md](LICENSE.md) file for details.

## Support

- 📖 [Documentation](ARCHITECTURE.md)
- 🐛 [Report Issues](https://github.com/samcat116/strato/issues)
- 💬 [Discussions](https://github.com/samcat116/strato/discussions)
