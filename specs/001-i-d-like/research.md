# Research Findings: Skaffold and Helm Integration

**Phase**: 0 - Research  
**Date**: 2025-09-25  
**Status**: Complete

## Research Tasks Completed

### 1. Skaffold Best Practices for Multi-Service Swift Applications

**Decision**: Use Skaffold with Docker buildpacks and custom build configuration for Swift applications

**Rationale**:
- Skaffold supports multi-service projects through modules and profiles
- Docker buildpack integration can handle Swift compilation efficiently
- File watching and hot-reload work well with Vapor applications
- Build optimization through layer caching reduces rebuild times

**Alternatives Considered**:
- Manual kubectl + helm approach: Rejected due to poor developer experience
- Tilt: Rejected due to less mature Helm integration
- Docker Compose with Helm post-processing: Rejected due to complexity

**Implementation Approach**:
- Use `skaffold.yaml` with modules for control-plane and agent
- Configure file sync for Swift source files to enable hot reload
- Leverage Docker multi-stage builds for optimized images
- Use profiles for different development scenarios (full vs minimal)

### 2. Helm Chart Patterns for Development vs Production

**Decision**: Single Helm chart with environment-specific values files

**Rationale**:
- Maintains production parity while allowing development customizations
- Values file inheritance provides clean separation of concerns
- Standard Kubernetes patterns for configuration management
- Easier to maintain than separate charts

**Alternatives Considered**:
- Separate dev/prod Helm charts: Rejected due to maintenance overhead
- Environment variables only: Rejected due to configuration complexity
- Kustomize overlays: Rejected due to added tooling complexity

**Implementation Approach**:
- Base chart in `helm/strato/` with production defaults
- `values-dev.yaml` with development overrides
- Use Helm subcharts for dependencies (PostgreSQL, etc.)
- ConfigMap/Secret templating for environment-specific configuration

### 3. Kubernetes Local Development Cluster Setup

**Decision**: Recommend minikube with specific addons and resource allocation

**Rationale**:
- Best balance of features, stability, and resource usage
- Excellent addon ecosystem (ingress, dns, storage)
- Good integration with Skaffold and development workflows
- Cross-platform support for team consistency

**Alternatives Considered**:
- kind: Good for CI, but limited addon support for development
- Docker Desktop K8s: Platform-specific, resource-heavy
- k3s/k3d: Good but less familiar tooling for most developers

**Implementation Approach**:
- minikube with minimum 4GB RAM, 2 CPUs
- Enable addons: ingress, dns, storage-provisioner
- Use NodePort services for external access during development
- Document cluster setup in quickstart guide

### 4. Migration Strategy from docker-compose to Skaffold

**Decision**: Phased migration with parallel operation during transition

**Rationale**:
- Minimizes risk and allows gradual team adoption
- Provides rollback capability during transition period
- Enables validation of service parity between approaches
- Maintains development velocity during migration

**Alternatives Considered**:
- Big-bang migration: Rejected due to risk and disruption
- Keep both permanently: Rejected due to maintenance overhead
- Migrate to K8s YAML first: Rejected due to poor developer experience

**Implementation Approach**:
- Phase 1: Create Helm charts and Skaffold config alongside existing docker-compose
- Phase 2: Team validation and feedback collection
- Phase 3: Switch default development instructions to Skaffold
- Phase 4: Deprecate and remove docker-compose.yml

## Service Architecture Analysis

### Current docker-compose Services Identified
Based on CLAUDE.md and user context:

1. **control-plane**: Vapor web application (port 8080)
2. **agent**: Swift CLI application  
3. **db**: PostgreSQL database
4. **permify**: SpiceDB-based authorization service
5. **ovn-northd**: OVN networking northbound daemon
6. **ovn-nb-db**: OVN northbound database
7. **ovn-sb-db**: OVN southbound database  
8. **openvswitch**: Open vSwitch daemon

### Helm Chart Mapping Strategy
- **Core Application Services**: control-plane, agent → Custom templates
- **Database Services**: PostgreSQL → Bitnami subchart
- **Authorization**: Permify → Custom template (no standard chart available)
- **Networking Services**: OVN/OVS → Custom templates with init containers

## Configuration Management Decisions

### Environment Variables and Secrets
- **Development**: Use ConfigMaps for non-sensitive config
- **Secrets**: Kubernetes secrets with base64 encoding
- **Database URLs**: Template-generated based on service names
- **WebAuthn Settings**: Environment-specific in values files

### Volume Management
- **Development**: Use persistent volumes for database data
- **Source Code**: Skaffold file sync for hot reload
- **Configuration**: ConfigMap and Secret volume mounts
- **Logs**: Standard Kubernetes logging (kubectl logs)

### Networking Configuration
- **Internal Communication**: Kubernetes service DNS
- **External Access**: NodePort services for development
- **WebSocket Support**: Ensure proper proxy configuration
- **OVN Networking**: Host networking mode for OVN services

## Performance and Resource Considerations

### Resource Allocation
- **control-plane**: 512Mi memory, 0.5 CPU (development)
- **agent**: 256Mi memory, 0.2 CPU (development)  
- **PostgreSQL**: 256Mi memory, 0.3 CPU (development)
- **Total cluster**: ~4GB RAM minimum for comfortable development

### Build Optimization
- **Multi-stage Docker builds**: Separate build and runtime stages
- **Layer caching**: Optimize dependency installation layers
- **Parallel builds**: Skaffold can build services concurrently
- **File watching**: Monitor Swift source files for changes

## Risk Mitigation

### Identified Risks
1. **Learning Curve**: Team needs Kubernetes/Helm knowledge
2. **Resource Usage**: Higher memory/CPU than docker-compose
3. **Networking Complexity**: Kubernetes networking vs Docker bridge
4. **Debugging**: More complex log aggregation and debugging

### Mitigation Strategies
1. **Documentation**: Comprehensive quickstart and troubleshooting guides
2. **Resource Management**: Optimized values for development workloads
3. **Networking**: Use NodePort services and clear service naming
4. **Debugging**: Document kubectl commands and log access patterns

## Next Phase Requirements

All NEEDS CLARIFICATION items from the technical context have been resolved:
- ✅ Service architecture mapped from docker-compose
- ✅ Development vs production configuration strategy defined
- ✅ Local cluster setup approach chosen
- ✅ Migration strategy planned

**Ready for Phase 1**: Design and contract generation