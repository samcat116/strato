# Tasks: Skaffold and Helm Integration for Development

**Input**: Design documents from `/Users/sam/Projects/Active/strato/specs/001-i-d-like/`
**Prerequisites**: plan.md (required), research.md, data-model.md, contracts/

## Execution Flow (main)
```
1. Load plan.md from feature directory
   → ✅ Loaded: Swift 5.9+, Skaffold, Helm 3, Kubernetes/minikube
   → ✅ Structure: Distributed infrastructure (Control Plane + Agent)
2. Load optional design documents:
   → ✅ data-model.md: Skaffold Config, Helm Chart, Service Config entities
   → ✅ contracts/: skaffold-schema.yaml, helm-values-schema.yaml
   → ✅ research.md: minikube setup, phased migration strategy
3. Generate tasks by category:
   → Setup: Helm chart structure, Skaffold config
   → Tests: Schema validation, integration tests
   → Core: Service templates, configuration files
   → Integration: Service connectivity, migration
   → Polish: Documentation, cleanup
4. Apply task rules:
   → Different files = mark [P] for parallel
   → Same file = sequential (no [P])
   → Tests before implementation (TDD)
5. Number tasks sequentially (T001, T002...)
6. Generate dependency graph
7. Create parallel execution examples
8. Validate task completeness: ✅ All schemas have tests, all services have templates
9. Return: SUCCESS (tasks ready for execution)
```

## Format: `[ID] [P?] Description`
- **[P]**: Can run in parallel (different files, no dependencies)
- Include exact file paths in descriptions

## Path Conventions
Paths assume existing distributed architecture at repository root:
- **Helm charts**: `helm/strato/` directory structure
- **Skaffold config**: `skaffold.yaml` at repository root
- **Tests**: `tests/` directory for validation scripts

## Phase 3.1: Setup
- [x] T001 Create Helm chart directory structure at `helm/strato/`
- [x] T002 Initialize Helm Chart.yaml with metadata and dependencies at `helm/strato/Chart.yaml`
- [x] T003 [P] Create base Skaffold configuration at `skaffold.yaml`

## Phase 3.2: Tests First (TDD) ⚠️ MUST COMPLETE BEFORE 3.3
**CRITICAL: These tests MUST be written and MUST FAIL before ANY implementation**
- [x] T004 [P] Skaffold schema validation test in `tests/skaffold-validation.sh`
- [x] T005 [P] Helm chart linting test in `tests/helm-lint.sh`
- [x] T006 [P] Helm values rendering test in `tests/helm-template-test.sh`
- [x] T007 [P] Service connectivity integration test in `tests/integration/service-connectivity.sh`
- [x] T008 [P] Full environment startup test in `tests/integration/full-environment.sh`

## Phase 3.3: Core Implementation (ONLY after tests are failing)
- [x] T009 [P] PostgreSQL subchart configuration in `helm/strato/Chart.yaml` dependencies
- [x] T010 [P] Base Helm values file with production defaults at `helm/strato/values.yaml`
- [x] T011 [P] Development values override file at `helm/strato/values-dev.yaml`
- [x] T012 [P] Control Plane Deployment template at `helm/strato/templates/control-plane/deployment.yaml`
- [x] T013 [P] Control Plane Service template at `helm/strato/templates/control-plane/service.yaml`
- [x] T014 [P] Control Plane ConfigMap template at `helm/strato/templates/control-plane/configmap.yaml`
- [x] T015 [P] Agent Deployment template at `helm/strato/templates/agent/deployment.yaml`
- [x] T016 [P] Agent ConfigMap template at `helm/strato/templates/agent/configmap.yaml`
- [x] T017 [P] Permify Deployment template at `helm/strato/templates/permify/deployment.yaml`
- [x] T018 [P] Permify Service template at `helm/strato/templates/permify/service.yaml`
- [x] T019 [P] OVN Northd Deployment template at `helm/strato/templates/ovn/northd-deployment.yaml`
- [x] T020 [P] OVN Database StatefulSets at `helm/strato/templates/ovn/nb-db-statefulset.yaml`
- [x] T021 [P] OVN Database StatefulSets at `helm/strato/templates/ovn/sb-db-statefulset.yaml`
- [x] T022 [P] Open vSwitch DaemonSet template at `helm/strato/templates/ovs/daemonset.yaml`
- [x] T023 Configure Skaffold build artifacts for control-plane in `skaffold.yaml`
- [x] T024 Configure Skaffold build artifacts for agent in `skaffold.yaml`
- [x] T025 Configure Skaffold Helm deployment in `skaffold.yaml`
- [x] T026 Add Skaffold development profiles (debug, minimal) in `skaffold.yaml`

## Phase 3.4: Integration
- [x] T027 Add Helm template helpers and common labels at `helm/strato/templates/_helpers.tpl`
- [x] T028 Configure service dependencies and init containers in deployment templates
- [x] T029 Set up persistent volume claims for databases in StatefulSet templates
- [x] T030 Configure networking and service discovery between components
- [x] T031 Add health checks and readiness probes to all deployment templates
- [x] T032 Configure environment-specific resource limits and requests

## Phase 3.5: Polish
- [x] T033 [P] Create development setup documentation at `docs/development-skaffold.md`
- [x] T034 [P] Create migration guide from docker-compose at `docs/migration-guide.md`
- [x] T035 [P] Add troubleshooting guide at `docs/troubleshooting-k8s.md`
- [x] T036 [P] Update CLAUDE.md with new development commands
- [x] T037 [P] Create example values files for different environments
- [x] T038 Validate against quickstart.md scenarios
- [x] T039 Performance test: environment startup time under 2 minutes
- [x] T040 Clean up and deprecate docker-compose.yml with migration notice

## Dependencies
- Setup (T001-T003) before all other phases
- Tests (T004-T008) before implementation (T009-T026)
- T009 (Chart dependencies) blocks templates that use subcharts
- T010-T011 (values files) before T012-T022 (templates that reference values)
- T023-T026 (Skaffold config) after T001-T002 (Helm chart structure exists)
- T027 (helpers) before templates that use common labels
- Integration (T027-T032) requires core templates complete
- Polish (T033-T040) after integration complete

## Parallel Execution Examples

### Phase 3.2: All test files can run in parallel
```bash
# Launch T004-T008 together since they create different test files:
Task: "Skaffold schema validation test in tests/skaffold-validation.sh"
Task: "Helm chart linting test in tests/helm-lint.sh" 
Task: "Helm values rendering test in tests/helm-template-test.sh"
Task: "Service connectivity integration test in tests/integration/service-connectivity.sh"
Task: "Full environment startup test in tests/integration/full-environment.sh"
```

### Phase 3.3: Core template creation (after values files exist)
```bash
# Launch T012-T022 together since they create different template files:
Task: "Control Plane Deployment template at helm/strato/templates/control-plane/deployment.yaml"
Task: "Control Plane Service template at helm/strato/templates/control-plane/service.yaml"
Task: "Control Plane ConfigMap template at helm/strato/templates/control-plane/configmap.yaml"
Task: "Agent Deployment template at helm/strato/templates/agent/deployment.yaml"
Task: "Agent ConfigMap template at helm/strato/templates/agent/configmap.yaml"
Task: "Permify Deployment template at helm/strato/templates/permify/deployment.yaml"
Task: "Permify Service template at helm/strato/templates/permify/service.yaml"
Task: "OVN Northd Deployment template at helm/strato/templates/ovn/northd-deployment.yaml"
Task: "OVN Database StatefulSets at helm/strato/templates/ovn/nb-db-statefulset.yaml"
Task: "OVN Database StatefulSets at helm/strato/templates/ovn/sb-db-statefulset.yaml"
Task: "Open vSwitch DaemonSet template at helm/strato/templates/ovs/daemonset.yaml"
```

### Phase 3.5: Documentation tasks
```bash
# Launch T033-T037 together since they create different documentation files:
Task: "Create development setup documentation at docs/development-skaffold.md"
Task: "Create migration guide from docker-compose at docs/migration-guide.md"
Task: "Add troubleshooting guide at docs/troubleshooting-k8s.md"
Task: "Update CLAUDE.md with new development commands"
Task: "Create example values files for different environments"
```

## Service Architecture Implementation

### Current docker-compose → Helm mapping:
- **control-plane** → Control Plane Deployment + Service + ConfigMap (T012-T014)
- **agent** → Agent Deployment + ConfigMap (T015-T016)
- **db** → PostgreSQL subchart dependency (T009)
- **permify** → Permify Deployment + Service (T017-T018)
- **ovn-northd, ovn-nb-db, ovn-sb-db** → OVN templates (T019-T021)
- **openvswitch** → OVS DaemonSet (T022)

### Configuration Management:
- **Production defaults**: `values.yaml` (T010)
- **Development overrides**: `values-dev.yaml` (T011)
- **Environment variables**: ConfigMap templates (T014, T016)
- **Service discovery**: Kubernetes DNS in templates (T030)

## Validation Checklist
*GATE: Checked before task completion*

- [x] All contract schemas have corresponding validation tests (T004-T006)
- [x] All docker-compose services have Helm template tasks
- [x] All tests come before implementation (T004-T008 before T009-T026)
- [x] Parallel tasks truly independent (different files)
- [x] Each task specifies exact file path
- [x] No task modifies same file as another [P] task
- [x] Integration tests cover service connectivity (T007-T008)
- [x] Migration strategy preserves existing functionality

## Notes
- [P] tasks = different files, no dependencies
- Verify tests fail before implementing templates
- Test Helm chart rendering after each template addition
- Validate Skaffold configuration with `skaffold config list`
- Use `helm lint` and `helm template` for validation
- Commit after each task group completion