# Step-CA Configuration for Strato

This directory contains configuration files for the Smallstep step-ca Certificate Authority used by Strato.

## Files

- `password.txt` - CA password for development (change in production)
- `provisioner-password.txt` - Provisioner password for development (change in production)
- `ca-template.json` - step-ca configuration template
- `spiffe-template.json` - Certificate template for SPIFFE-compliant certificates

## Features

### Provisioners

1. **JWK Provisioner (`strato-agents`)**
   - Used for initial agent enrollment with join tokens
   - Issues certificates with SPIFFE URIs

2. **X5C Provisioner (`mtls-renewal`)**
   - Used for certificate renewal using existing certificates
   - Enables mTLS-based authentication

3. **ACME Provisioner (`acme`)**
   - Standard ACME protocol support
   - For future automated certificate management

### SPIFFE Support

The certificate template ensures all issued certificates include:
- SPIFFE URI in Subject Alternative Name (SAN)
- Format: `spiffe://strato.local/agent/{agentId}`
- Proper key usage and basic constraints for workload identity

## Security Notes

**⚠️ Development Configuration**: The passwords in this directory are for development only.
In production:
- Use strong, randomly generated passwords
- Store passwords in secure secret management
- Consider using HSM for key protection
- Enable proper monitoring and audit logging

## Docker Compose Integration

The step-ca service is configured to:
- Auto-initialize on first run
- Mount this configuration directory
- Expose CA API on port 9000
- Persist CA data in Docker volume

## Kubernetes/Helm Integration

See the Helm chart configuration in `/helm/strato-control-plane/` for production deployment options.