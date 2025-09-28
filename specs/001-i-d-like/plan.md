# Implementation Plan: Skaffold and Helm Integration for Development

**Branch**: `001-i-d-like` | **Date**: 2025-09-25 | **Spec**: [spec.md](./spec.md)
**Input**: Feature specification from `/Users/sam/Projects/Active/strato/specs/001-i-d-like/spec.md`

## Execution Flow (/plan command scope)
```
1. Load feature spec from Input path
   → ✅ Feature spec loaded successfully
2. Fill Technical Context (scan for NEEDS CLARIFICATION)
   → ✅ Project Type: distributed infrastructure (Control Plane + Agent)
   → ✅ Structure Decision: Option 1 (existing distributed architecture)
3. Fill the Constitution Check section based on the content of the constitution document.
4. Evaluate Constitution Check section below
   → If violations exist: Document in Complexity Tracking
   → If no justification possible: ERROR "Simplify approach first"
   → Update Progress Tracking: Initial Constitution Check
5. Execute Phase 0 → research.md
   → If NEEDS CLARIFICATION remain: ERROR "Resolve unknowns"
6. Execute Phase 1 → contracts, data-model.md, quickstart.md, agent-specific template file (e.g., `CLAUDE.md` for Claude Code, `.github/copilot-instructions.md` for GitHub Copilot, `GEMINI.md` for Gemini CLI, `QWEN.md` for Qwen Code or `AGENTS.md` for opencode).
7. Re-evaluate Constitution Check section
   → If new violations: Refactor design, return to Phase 1
   → Update Progress Tracking: Post-Design Constitution Check
8. Plan Phase 2 → Describe task generation approach (DO NOT create tasks.md)
9. STOP - Ready for /tasks command
```

**IMPORTANT**: The /plan command STOPS at step 7. Phases 2-4 are executed by other commands:
- Phase 2: /tasks command creates tasks.md
- Phase 3-4: Implementation execution (manual or via tools)

## Summary
Replace docker-compose development workflow with Skaffold + Helm integration to achieve production parity. This enables developers to use the same Helm chart configuration for local development as production deployments, improving confidence in changes and catching environment-specific issues early.

## Technical Context
**Language/Version**: Swift 5.9+ (Control Plane: Vapor 4, Agent: Swift CLI)  
**Primary Dependencies**: Skaffold, Helm 3, Kubernetes/minikube, Docker  
**Storage**: PostgreSQL (via Helm chart), Permify (SpiceDB-based authorization)  
**Testing**: Swift Test framework for unit tests, integration tests for WebSocket communication  
**Target Platform**: Kubernetes cluster (local development via minikube/kind)  
**Project Type**: Distributed infrastructure (Control Plane + Agent components)  
**Performance Goals**: <200ms API response times, <100MB agent memory usage  
**Constraints**: Must maintain development workflow efficiency, production parity required  
**Scale/Scope**: Replace existing docker-compose.yml with ~6 services (control-plane, agent, postgres, permify, ovn-northd, openvswitch)

**Current Architecture (from user context)**: 
- Control Plane: Vapor web app with PostgreSQL and SpiceDB dependencies
- Agent: Swift CLI application for VM management
- Frontend: REST API and web UI
- Current Development: docker-compose file orchestrates all services
- Production: Helm charts for Kubernetes deployment

## Constitution Check
*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

### Distributed Architecture Compliance
- [x] Control Plane and Agent components clearly separated
- [x] WebSocket communication protocols defined in Shared package
- [x] No direct inter-component state access

### Security Requirements
- [x] WebAuthn/Passkeys authentication specified if user-facing
- [x] Permify authorization integration for access control
- [x] No credentials or secrets in configuration

### Test-Driven Development
- [x] Contract tests planned for API endpoints
- [x] Integration tests for WebSocket communication
- [x] Swift Test framework specified for unit tests

### Platform Independence
- [x] Development/production platform differences addressed
- [x] QEMU/OVN integration mocking strategy defined
- [x] Runtime platform detection approach specified

### Production Reliability
- [x] Docker containerization approach planned
- [x] Error handling and logging strategy defined
- [x] Performance targets specified (<200ms API, <100MB agent memory)

## Project Structure

### Documentation (this feature)
```
specs/001-i-d-like/
├── plan.md              # This file (/plan command output)
├── research.md          # Phase 0 output (/plan command)
├── data-model.md        # Phase 1 output (/plan command)
├── quickstart.md        # Phase 1 output (/plan command)
├── contracts/           # Phase 1 output (/plan command)
└── tasks.md             # Phase 2 output (/tasks command - NOT created by /plan)
```

### Source Code (repository root)
```
# Existing distributed architecture (Control Plane + Agent + Shared)
control-plane/
├── Sources/App/
├── Resources/
├── Public/
├── web/
├── Package.swift
└── Dockerfile

agent/
├── Sources/StratoAgent/
├── Package.swift
└── Dockerfile

shared/
├── Sources/StratoShared/
└── Package.swift

# New Skaffold/Helm configuration files
helm/
├── strato/
│   ├── Chart.yaml
│   ├── values.yaml
│   ├── values-dev.yaml
│   └── templates/
│       ├── control-plane/
│       ├── agent/
│       ├── postgres/
│       └── permify/

skaffold.yaml
docker-compose.yml (to be deprecated)
```

**Structure Decision**: Existing distributed architecture maintained, adding Helm chart and Skaffold configuration

## Phase 0: Outline & Research

### Research Tasks Identified
1. **Skaffold best practices for multi-service Swift applications**
   - Hot reload capabilities for Swift/Vapor applications
   - Build optimization strategies for container rebuilds
   - Integration with existing Docker build processes

2. **Helm chart patterns for development vs production**
   - Values file organization (values-dev.yaml vs values.yaml)
   - ConfigMap and Secret management strategies
   - Service dependencies and initialization order

3. **Kubernetes local development cluster setup**
   - minikube vs kind vs Docker Desktop Kubernetes comparison
   - Resource requirements and performance implications
   - Networking configuration for WebSocket communication

4. **Migration strategy from docker-compose to Skaffold**
   - Service mapping and dependency analysis
   - Volume mounting strategies for development
   - Environment variable and configuration migration

**Output**: research.md with all decisions, rationales, and alternatives considered

## Phase 1: Design & Contracts

### Data Model Requirements
- **Skaffold Configuration**: Defines build artifacts, deployment manifests, and development workflow
- **Helm Chart Structure**: Templates for all services with configurable values
- **Development Values**: Override configurations optimized for local development
- **Service Dependencies**: Proper startup ordering and health checks

### API Contracts
Since this is infrastructure configuration (not user-facing APIs), contracts focus on:
- **Skaffold Manifest Schema**: Build and deploy configuration validation
- **Helm Values Schema**: Development vs production configuration differences
- **Service Communication Contracts**: Port mappings and internal DNS names

### Contract Tests
- Skaffold configuration validation (build succeeds, deploys correctly)
- Helm chart templating tests (values render correctly)
- Service connectivity tests (WebSocket communication, database connections)

### Integration Tests
- Full environment startup test (all services healthy)
- Code change detection and rebuild test
- Service dependency resolution test

**Output**: data-model.md, /contracts/*, failing tests, quickstart.md, CLAUDE.md update

## Phase 2: Task Planning Approach
*This section describes what the /tasks command will do - DO NOT execute during /plan*

**Task Generation Strategy**:
- Load `.specify/templates/tasks-template.md` as base
- Generate tasks from Phase 1 design docs (contracts, data model, quickstart)
- Each service configuration → Helm template task [P]
- Each build configuration → Skaffold build task [P]
- Integration tests for service connectivity
- Migration tasks to deprecate docker-compose

**Ordering Strategy**:
- TDD order: Tests before implementation
- Dependency order: Base Helm chart → Service templates → Skaffold config → Integration
- Mark [P] for parallel execution (independent template files)

**Estimated Output**: 15-20 numbered, ordered tasks in tasks.md

**IMPORTANT**: This phase is executed by the /tasks command, NOT by /plan

## Phase 3+: Future Implementation
*These phases are beyond the scope of the /plan command*

**Phase 3**: Task execution (/tasks command creates tasks.md)  
**Phase 4**: Implementation (execute tasks.md following constitutional principles)  
**Phase 5**: Validation (run tests, execute quickstart.md, performance validation)

## Complexity Tracking
*No constitutional violations identified - all checks passed*

## Progress Tracking
*This checklist is updated during execution flow*

**Phase Status**:
- [ ] Phase 0: Research complete (/plan command)
- [ ] Phase 1: Design complete (/plan command)
- [ ] Phase 2: Task planning complete (/plan command - describe approach only)
- [ ] Phase 3: Tasks generated (/tasks command)
- [ ] Phase 4: Implementation complete
- [ ] Phase 5: Validation passed

**Gate Status**:
- [x] Initial Constitution Check: PASS
- [ ] Post-Design Constitution Check: PASS
- [ ] All NEEDS CLARIFICATION resolved
- [ ] Complexity deviations documented

---
*Based on Constitution v1.0.0 - See `.specify/memory/constitution.md`*