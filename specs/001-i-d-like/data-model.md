# Data Model: Skaffold and Helm Integration

**Phase**: 1 - Design  
**Date**: 2025-09-25  
**Status**: Complete

## Configuration Entities

### Skaffold Configuration
**Purpose**: Defines build, deploy, and development workflow automation

**Key Attributes**:
- `apiVersion`: Skaffold API version (v4beta11)
- `kind`: Configuration type (Config)
- `metadata.name`: Project identifier
- `build.artifacts[]`: Build specifications for each service
- `manifests.helm.releases[]`: Helm deployment configurations
- `deploy.helm`: Helm deployment settings
- `profiles[]`: Environment-specific overrides

**Relationships**:
- References Helm chart in deploy configuration
- Maps to Docker build contexts for each service
- Contains development profile for local overrides

**State Transitions**:
- Draft → Validated → Active → Deprecated
- Validation occurs on `skaffold build` or `skaffold dev`

### Helm Chart Structure
**Purpose**: Kubernetes deployment templates with configurable values

**Key Attributes**:
- `Chart.yaml`: Metadata, version, dependencies
- `values.yaml`: Default configuration values
- `values-dev.yaml`: Development environment overrides
- `templates/`: Kubernetes resource templates
- `charts/`: Subchart dependencies

**Relationships**:
- Parent chart contains all service templates
- Subchart dependencies for PostgreSQL, etc.
- Values hierarchy: default < environment < user overrides

**Validation Rules**:
- Chart version must follow semantic versioning
- All template variables must have default values
- Resource names must be unique within namespace
- Service ports must not conflict

### Service Configuration
**Purpose**: Individual service deployment specifications within Helm templates

**Key Attributes**:
- `name`: Service identifier
- `image`: Container image reference
- `ports[]`: Exposed ports and protocols
- `env[]`: Environment variables
- `volumes[]`: Volume mounts and storage
- `resources`: CPU/memory limits and requests

**Relationships**:
- Belongs to parent Helm chart
- References ConfigMaps and Secrets
- Connects to other services via Kubernetes DNS

**State Transitions**:
- Pending → Running → Ready → Terminating
- Health checks determine readiness state

## Service Mappings

### Control Plane Service
- **Current**: docker-compose service with Vapor app
- **Target**: Kubernetes Deployment + Service + ConfigMap
- **Image**: Custom Swift/Vapor container
- **Dependencies**: PostgreSQL, Permify
- **Configuration**: Database URLs, WebAuthn settings, Permify endpoints

### Agent Service  
- **Current**: docker-compose service with Swift CLI
- **Target**: Kubernetes DaemonSet (or Deployment with NodeAffinity)
- **Image**: Custom Swift container with QEMU/OVN integration
- **Dependencies**: Control plane WebSocket endpoint, OVN services
- **Configuration**: Control plane URL, QEMU socket paths, log levels

### Database Services
- **PostgreSQL**: Bitnami Helm subchart with persistent storage
- **Permify**: Custom Deployment with SpiceDB configuration
- **Configuration**: Database credentials, connection strings, schemas

### Networking Services (OVN/OVS)
- **OVN Northbound/Southbound DBs**: StatefulSets with persistent volumes
- **OVN Northd**: Deployment with database connections
- **Open vSwitch**: DaemonSet with host networking
- **Configuration**: Database connections, networking policies

## Development vs Production Differences

### Resource Allocation
- **Development**: Lower CPU/memory limits for faster startup
- **Production**: Higher limits based on performance requirements
- **Storage**: Development uses smaller persistent volumes

### Networking Configuration
- **Development**: NodePort services for external access
- **Production**: LoadBalancer or Ingress for external access
- **Internal**: Both use ClusterIP for service-to-service communication

### Security Configuration
- **Development**: Relaxed security policies for debugging
- **Production**: Strict RBAC, NetworkPolicies, PodSecurityStandards
- **Secrets**: Development may use default/example values

### Monitoring and Logging
- **Development**: Simple kubectl logs access
- **Production**: Centralized logging and monitoring integration
- **Debug**: Development enables debug logging levels

## Configuration Schema Validation

### Required Fields
- All services must have resource limits defined
- Database services must specify persistent volume requirements
- Network services must declare required host permissions

### Optional Fields
- Debug/development specific configurations
- Monitoring and observability integrations
- Advanced networking configurations

### Constraints
- Memory limits must be >= resource requests
- Port numbers must be unique within service
- Service names must follow DNS naming conventions
- Volume names must be unique within pod specification

## Migration Impact

### Data Persistence
- PostgreSQL data persists through Kubernetes PersistentVolumes
- Configuration changes require pod restarts (not data loss)
- Development data can be reset via volume deletion

### Service Dependencies
- Startup ordering handled by Kubernetes init containers
- Health checks ensure services are ready before dependents start
- Graceful shutdown for clean service termination

### Configuration Management
- Environment variables migrated to Kubernetes ConfigMaps
- Secrets properly managed through Kubernetes Secret resources
- File-based configuration mounted as ConfigMap volumes