# Strato Secure Agent Authentication Framework

This document describes the secure authentication framework implemented for Strato agent-to-control-plane communication using mutual TLS and certificate-based authentication.

## Overview

The authentication framework provides:
- **Mutual TLS (mTLS)** for all agent ↔ control plane communication
- **One-time join tokens (JWT)** for initial agent enrollment
- **Short-lived client certificates** (12-24h) with SPIFFE-style URI SANs
- **Automatic certificate renewal** with configurable thresholds
- **Certificate revocation** via CRL and short TTL
- **Comprehensive audit logging** for all certificate operations
- **SPIRE migration path** for future workload identity standardization

## Architecture

### Components

1. **Certificate Authority Service** - Issues and manages agent certificates
2. **Agent Enrollment Controller** - Handles initial enrollment and renewal
3. **Certificate Auth Middleware** - Validates client certificates for agent routes
4. **Certificate Manager (Agent)** - Manages certificate lifecycle on agent side
5. **Audit Service** - Logs all certificate operations for security monitoring
6. **Revocation Service** - Manages certificate revocation and CRL generation
7. **Security Service** - Validates cryptographic standards and provides recommendations

### Flow

1. **Initial Enrollment**
   - Agent obtains join token (JWT) from control plane
   - Agent generates key pair and creates CSR
   - Agent submits enrollment request with join token and CSR
   - Control plane validates token and issues short-lived certificate
   - Agent stores certificate, private key, and CA bundle

2. **Regular Operation**
   - Agent connects to control plane using mTLS
   - Middleware validates client certificate and extracts SPIFFE identity
   - Agent operations proceed with authenticated context

3. **Certificate Renewal**
   - Agent monitors certificate expiration (default: 60% of lifetime)
   - Agent generates new key pair and CSR
   - Agent submits renewal request over existing mTLS connection
   - Control plane issues new certificate and revokes old one

## API Endpoints

### Agent Enrollment
- `POST /agent/enroll` - Initial certificate enrollment with join token
- `POST /agent/renew` - Certificate renewal (requires mTLS authentication)
- `GET /agent/ca` - Get CA certificate bundle
- `GET /agent/crl` - Get Certificate Revocation List

### Security Management
- `GET /api/security/audit/events` - Get certificate audit events
- `GET /api/security/audit/suspicious` - Get suspicious activities
- `GET /api/security/recommendations` - Get security recommendations
- `POST /api/security/validate/certificate` - Validate certificate security
- `GET /api/security/spire/config` - Generate SPIRE configuration
- `GET /api/security/spire/compatibility` - Check SPIRE compatibility

## Configuration

### Control Plane Environment Variables

```bash
# Join token signing key (change in production)
JOIN_TOKEN_SECRET="your-secret-key-here"

# Certificate authority settings (auto-generated if not set)
CA_PRIVATE_KEY_PATH="/etc/strato/ca/private.key"
CA_CERTIFICATE_PATH="/etc/strato/ca/certificate.crt"
```

### Agent Configuration (config.toml)

```toml
# WebSocket connection (will upgrade to mTLS if certificates available)
control_plane_url = "wss://control-plane.example.com:8080/agent/ws"

# Certificate paths
certificate_path = "/etc/strato/certs/agent.crt"
private_key_path = "/etc/strato/certs/agent.key"
ca_bundle_path = "/etc/strato/certs/ca-bundle.crt"

# Enrollment settings
enrollment_url = "https://control-plane.example.com:8080/agent/enroll"
join_token = "eyJ0eXAiOiJKV1QiLCJhbGciOiJIUzI1NiJ9..."

# Auto-renewal
auto_renewal = true
renewal_threshold = 0.6  # Renew at 60% of certificate lifetime
```

## Security Features

### Certificate Standards
- **Short-lived certificates**: 12-24 hour validity by default
- **SPIFFE URIs**: `spiffe://strato.local/agent/{agent-id}`
- **Modern cryptography**: ECDSA P-256 preferred, RSA deprecated
- **Certificate extensions**: Extended Key Usage includes clientAuth

### Audit Logging
All certificate operations are logged with:
- Event type (enrollment, renewal, revocation, validation)
- Agent ID and certificate ID
- SPIFFE URI and client IP
- Timestamp and operation details
- Structured logging for SIEM integration

### Revocation
- **Short TTL**: Primary revocation mechanism via certificate expiration
- **Certificate Revocation List (CRL)**: Available at `/agent/crl`
- **Immediate revocation**: Database status updates for real-time validation
- **Automatic cleanup**: Expired certificates marked as such

## Installation

### Control Plane Setup
1. Deploy control plane with database migrations
2. Configure environment variables for signing keys
3. Middleware automatically protects `/agent/*` routes

### Agent Installation
Use the provided install script:

```bash
# Basic installation
sudo ./scripts/install-agent.sh \
  --join-token "eyJ0eXAi..." \
  --control-plane "control-plane.example.com:8080"

# With custom configuration
export JOIN_TOKEN="eyJ0eXAi..."
export CONTROL_PLANE_HOST="control-plane.example.com:8080"
export AGENT_NAME="hypervisor-01"
sudo ./scripts/install-agent.sh
```

The script will:
- Create system user and directories
- Install agent binary and systemd service
- Generate configuration file
- Perform initial certificate enrollment
- Start and enable the agent service

## Monitoring and Operations

### Health Checks
- Certificate expiration monitoring via maintenance service
- Audit log analysis for suspicious activities
- Certificate validation against security standards

### Troubleshooting
```bash
# Check agent status
sudo systemctl status strato-agent

# View agent logs
sudo journalctl -u strato-agent -f

# Check certificate status
openssl x509 -in /etc/strato/certs/agent.crt -text -noout

# Test enrollment
curl -X POST https://control-plane:8080/agent/enroll \
  -H "Content-Type: application/json" \
  -d '{"joinToken": "...", "csr": {...}}'
```

### Security Operations
```bash
# Get audit events for specific agent
curl "https://control-plane:8080/api/security/audit/events?agentId=agent-01"

# Check for suspicious activities in last 24 hours
curl "https://control-plane:8080/api/security/audit/suspicious?hours=24"

# Get security recommendations
curl "https://control-plane:8080/api/security/recommendations"

# Generate SPIRE configuration for migration
curl "https://control-plane:8080/api/security/spire/config?trustDomain=strato.local"
```

## Migration to SPIRE

The framework includes preparation for migration to SPIFFE/SPIRE:

1. **SPIFFE URIs**: Already implemented in certificate SANs
2. **Trust domain**: Configurable trust domain (default: strato.local)
3. **SPIRE configuration**: Automatic generation of SPIRE server/agent configs
4. **Compatibility check**: Analysis of current certificates for SPIRE compatibility

To migrate:
1. Deploy SPIRE infrastructure alongside existing CA
2. Configure agents to use SPIRE Workload API
3. Gradually migrate agents from custom CA to SPIRE
4. Decommission custom CA after full migration

## Future Enhancements

- **TPM attestation**: Hardware-backed key generation and storage
- **Certificate transparency**: Integration with CT logs
- **HSM integration**: Hardware security modules for CA key protection
- **Zero-trust networking**: Integration with service mesh for workload identity
- **Policy enforcement**: Fine-grained authorization policies based on SPIFFE identity

## Security Considerations

1. **Join token security**: Tokens are single-use and short-lived (1 hour default)
2. **Certificate lifetime**: Short validity periods reduce exposure window
3. **Automatic renewal**: Prevents service disruption from expired certificates
4. **Audit trail**: Complete logging of all certificate operations
5. **Defense in depth**: Multiple validation layers (JWT, certificate, middleware)
6. **Crypto agility**: Support for multiple algorithms with deprecation path

This framework provides a solid foundation for secure agent authentication while maintaining operational simplicity and providing a clear migration path to industry standards like SPIRE.