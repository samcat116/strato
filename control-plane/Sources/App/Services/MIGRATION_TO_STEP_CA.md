# Migration to step-ca

This document outlines the migration from custom certificate services to Smallstep step-ca.

## Deprecated Services

The following services have been replaced by step-ca integration:

### CertificateAuthorityService → StepCAClient
- **Replaced by**: `StepCAClient`
- **Reason**: step-ca provides production-ready PKI with SPIFFE support
- **Status**: ⚠️ Deprecated - Use StepCAClient instead

### CertificateRevocationService → step-ca CRL
- **Replaced by**: step-ca's built-in CRL endpoints
- **Reason**: step-ca handles revocation natively with OCSP support
- **Status**: ⚠️ Deprecated - Use StepCAClient.getCRL() instead

### CertificateSecurityService → step-ca policies
- **Replaced by**: step-ca's built-in policy engine
- **Reason**: step-ca provides comprehensive security validation
- **Status**: ⚠️ Deprecated - Use step-ca templates and policies instead

## Services Still in Use

### CertificateAuditService ✅
- **Status**: Active
- **Reason**: Still useful for audit logging and compliance
- **Integration**: Works with StepCAClient for comprehensive audit trails

### StepCAClient ✅
- **Status**: New primary service
- **Purpose**: Interface with step-ca for all certificate operations
- **Features**: SPIFFE support, automatic revocation, health checks

### StepCAHealthService ✅
- **Status**: New monitoring service
- **Purpose**: Monitor step-ca health and perform maintenance
- **Features**: Health checks, certificate cleanup, renewal alerts

## Migration Guide

### For Certificate Issuance
```swift
// Old way
let caService = CertificateAuthorityService(database: db, logger: logger)
let certificate = try await caService.issueCertificate(...)

// New way
let stepCAClient = try StepCAClient(client: client, logger: logger, database: db)
let certificate = try await stepCAClient.issueCertificate(...)
```

### For Certificate Revocation
```swift
// Old way
let revocationService = CertificateRevocationService(database: db, logger: logger)
try await revocationService.revokeCertificate(...)

// New way
let stepCAClient = try StepCAClient(client: client, logger: logger, database: db)
try await stepCAClient.revokeCertificate(...)
```

### For CRL Generation
```swift
// Old way
let revocationService = CertificateRevocationService(database: db, logger: logger)
let crl = try await revocationService.generateCRL()

// New way
let stepCAClient = try StepCAClient(client: client, logger: logger, database: db)
let crlData = try await stepCAClient.getCRL()
```

## Benefits of step-ca Integration

1. **Production Ready**: Battle-tested PKI used by Fortune 100 companies
2. **SPIFFE Compliant**: Native support for workload identity
3. **Standard Protocols**: ACME, OCSP, CRL out of the box
4. **Better Security**: HSM support, policy enforcement, automatic rotation
5. **High Availability**: PostgreSQL backend, multiple replicas
6. **Operational Excellence**: Built-in monitoring, API access, audit logs

## Cleanup Schedule

The deprecated services will be removed in a future release after confirming all integrations use StepCAClient.