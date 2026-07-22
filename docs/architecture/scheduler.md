# VM Scheduler Service

The Scheduler Service is responsible for intelligently placing VMs on hypervisor nodes (agents) based on resource availability, load distribution, and configurable scheduling strategies.

## Overview

When a new VM is created, the Scheduler Service analyzes all available agents and selects the optimal hypervisor to host the VM. The scheduler considers:

- **Resource Availability**: CPU, memory, and disk capacity
- **Agent Health**: Only online agents are considered
- **Hypervisor Support**: Only agents that reported the VM's hypervisor (QEMU or Firecracker) as available are considered. Agents probe each backend at registration (binary executable, and KVM/HVF accessibility for acceleration) and report the results; an agent that reports no usable backend stays registered but is never eligible for placement.
- **Load Distribution**: Current VM count and resource utilization
- **Scheduling Strategy**: Configurable algorithm for placement decisions

## Architecture

### Components

1. **SchedulerService** (`control-plane/Sources/App/Services/SchedulerService.swift`)
   - Core scheduling logic and strategy implementations
   - Registered as an Application service
   - Accessible via `req.scheduler` in request handlers

2. **AgentService Integration** (`control-plane/Sources/App/Services/AgentService.swift`)
   - Converts in-memory agent data to `SchedulableAgent` format
   - Calls scheduler during VM creation
   - Persists hypervisor assignment to database
   - Restores VM-to-agent mappings on startup

3. **VMController Integration** (`control-plane/Sources/App/Controllers/VMController.swift`)
   - Invokes `agentService.createVM()` with database context
   - Properly persists `hypervisorId` field in VM model

### Data Flow

```
VM Creation Request
    ↓
VMController.create()
    ↓
AgentService.createVM()
    ↓
AgentService.getSchedulableAgents()
    ↓
SchedulerService.selectAgent()
    ↓
[Scheduling Strategy Algorithm]
    ↓
Selected Agent ID
    ↓
VM.hypervisorId = agentId
    ↓
Save to Database
    ↓
Send VMCreateMessage to Agent
```

## Scheduling Strategies

The scheduler supports multiple strategies, each optimized for different use cases:

### 1. **Least Loaded** (Default)
- **Strategy**: `least_loaded`
- **Algorithm**: Selects the agent with the lowest overall resource utilization
- **Calculation**: Weighted average of CPU (40%), memory (40%), and disk (20%) utilization
- **Use Case**: Load balancing, performance isolation, evenly distributed workloads
- **Benefits**: Prevents hotspots, maintains headroom on all agents

### 2. **Best Fit** (Bin Packing)
- **Strategy**: `best_fit`
- **Algorithm**: Packs VMs onto agents with the least remaining capacity
- **Calculation**: Selects agent with minimum remaining capacity score
- **Use Case**: Resource consolidation, cost optimization, maximizing density
- **Benefits**: Minimizes fragmentation, leaves some agents completely free for large VMs

### 3. **Round Robin**
- **Strategy**: `round_robin`
- **Algorithm**: Distributes VMs evenly across all agents in circular fashion
- **Use Case**: Simple fair distribution, testing environments
- **Benefits**: Predictable, equal distribution regardless of actual load

### 4. **Random**
- **Strategy**: `random`
- **Algorithm**: Randomly selects from available agents
- **Use Case**: Development, testing, chaos engineering
- **Benefits**: Simple, unpredictable for testing failure scenarios

## Configuration

### Default Strategy

Set the default scheduling strategy via environment variable in your deployment configuration:

```bash
# In docker-compose.yml or Kubernetes ConfigMap
SCHEDULING_STRATEGY=least_loaded  # Options: least_loaded, best_fit, round_robin, random
```

If not specified, defaults to `least_loaded`.

### Runtime Strategy Override

You can override the strategy programmatically when creating VMs:

```swift
try await agentService.createVM(
    vm: vm,
    vmConfig: vmConfig,
    db: db,
    strategy: .bestFit  // Override default strategy
)
```

## Placement Requirements

The scheduler filters agents based on VM placement requirements — hard
constraints plus resource needs:

```swift
struct VMPlacementRequirements {
    let cpu: Int                          // Number of CPU cores
    let memory: Int64                     // Memory in bytes
    let disk: Int64                       // Disk space in bytes
    let hypervisorType: HypervisorType    // Required hypervisor backend
    let architecture: CPUArchitecture?    // Guest CPU architecture, when known
    let requiresInterVMNetworking: Bool   // Needs VM-to-VM networking (OVN)
    let requiresSandboxRuntime: Bool      // Sandbox workload (issue #415)
    let requiresSecureBoot: Bool          // UEFI Secure Boot (issue #565)
    let requiresVTPM: Bool                // Emulated TPM 2.0 (issue #565)
}
```

Only agents with sufficient **available** resources that also satisfy every
hard constraint are considered eligible.

### Hard Constraints

Hard constraints are never relaxed — a VM that cannot be placed fails with a
specific error rather than landing on an agent that would silently run it
differently than requested:

- **Hypervisor support**: The agent must support the VM's hypervisor backend
  (from the capabilities it advertised at registration). A Firecracker VM is
  never placed on a QEMU-only agent (e.g. a macOS host).
- **Architecture match**: KVM/HVF acceleration is same-architecture only. When
  a guest architecture is specified, only agents with a matching host
  architecture are eligible; agents with unknown architecture are excluded.
  (Currently unconstrained for VM-driven placement until images carry
  architecture metadata.)
- **Network capability**: VMs requiring VM-to-VM networking are only placed on
  OVN-backed agents, never on user-mode (SLIRP) agents.
- **Sandbox runtime**: Sandboxes (OCI-image Firecracker microVMs, issue #415)
  only place on agents that explicitly advertised the sandbox runtime at
  registration (`AgentRegisterMessage.sandboxCapable` — a build carrying the
  runtime driver, Firecracker + KVM usable, and the sandbox guest base image
  on disk) **and** registered with a wire protocol that carries sandbox
  desired state (v5+). Firecracker support alone never qualifies an agent,
  and neither does the protocol version alone.
- **Machine profile**: A VM asking for Secure Boot or a TPM only places on an
  agent that registered with a wire protocol carrying `VMSpec.machine` (v17+),
  and a TPM additionally requires that the agent advertised
  `AgentRegisterMessage.tpmCapable` — swtpm present and usable on that host.
  The two-signal shape mirrors the sandbox runtime for the same reason: a
  version number proves the agent *understands* the field, not that the host
  can *realize* it. This constraint exists because both features fail
  silently on an agent that cannot serve them — the guest simply boots without
  Secure Boot or without a TPM, and Windows setup refuses to install with
  nothing in the API to explain why. Refusing placement surfaces the missing
  prerequisite at create time instead.

## Agent Selection Process

1. **Fetch Available Agents**: Get all online agents from AgentService
2. **Filter Eligible Agents** (staged, each stage throws its own error when it
   eliminates all candidates):
   - Agent status must be `online`
   - Agent must support the VM's hypervisor type
   - Agent must advertise the sandbox runtime (sandbox placements only)
   - Agent must speak v17+ (Secure Boot or TPM placements) and advertise
     `tpmCapable` (TPM placements)
   - Agent host architecture must match the guest architecture (when specified)
   - Agent must satisfy the VM's network capability requirements
   - Available CPU ≥ VM CPU requirement
   - Available memory ≥ VM memory requirement
   - Available disk ≥ VM disk requirement
3. **Apply Strategy**: Run selected algorithm on eligible agents
4. **Return Selection**: Return agent ID or throw `SchedulerError` if no suitable agent found

### Placement Reservations

VM creation uses `selectAndReserveAgent`, which wraps the selection above in a
reservation step backed by the Valkey coordination layer
(`CoordinationService`, issue #258). This closes the read-decide-write race
where two concurrent creates both observe the same free capacity on an agent
and both place against it (oversubscription):

1. Before selection, each agent's reported availability is reduced by the sum
   of its **active reservations** (`resv:agent:{agentId}:*` keys) — capacity
   claimed by placements in flight that the agent's own resource reports do
   not reflect yet.
2. After selection, the VM's resources are reserved **atomically** (a Lua
   script in Valkey sums existing reservations, checks the new one fits the
   agent's reported availability, and writes it in one step). Two concurrent
   creates therefore serialize: exactly one wins the capacity.
3. If the reservation loses the race, selection re-runs with fresh reservation
   data; the now-full agent drops out in the resource filter and the create
   either lands elsewhere or fails with a clean `insufficientResources` error.

Reservations are released when the create fails to dispatch or when the owning
agent first reports the VM — via a status update or the heartbeat running-VM
list, at which point the agent's resource reports account for it; a ~120s TTL
is the backstop for crashes in between. If Valkey is unavailable,
reservation calls fail open — placement proceeds unreserved (the
pre-reservation behavior) rather than coupling VM creation to Valkey uptime.

## Error Handling

The scheduler throws specific errors for different failure scenarios:

### SchedulerError Types

- **`noAvailableAgents`**: No online agents in the cluster
- **`unsupportedHypervisor`**: No online agent supports the VM's hypervisor backend
- **`architectureMismatch`**: No eligible agent has the required host architecture
- **`networkCapabilityUnsatisfied`**: No eligible agent supports the required VM-to-VM networking
- **`machineProfileUnsatisfied`**: No eligible agent is new enough (wire v17+) to realize Secure Boot or a TPM
- **`vtpmUnsatisfied`**: No eligible agent has swtpm installed to back the requested TPM 2.0
- **`insufficientResources`**: Agents exist but none have enough resources
- **`invalidStrategy`**: Specified strategy name is not recognized
- **`agentServiceUnavailable`**: AgentService not properly initialized

### Error Messages

```swift
// Example error handling in VMController
do {
    try await req.agentService.createVM(vm: vm, vmConfig: vmConfig, db: req.db)
} catch let error as SchedulerError {
    req.logger.error("Scheduler error: \(error)")
    throw Abort(.serviceUnavailable, reason: error.description)
}
```

## Persistence and Recovery

### VM-to-Agent Mapping

- **Database**: `vm.hypervisorId` stores the agent ID/name
- **In-Memory Cache**: `AgentService.vmToAgentMapping` for fast lookups
- **Recovery**: On startup, mappings are restored from database

### Startup Recovery Process

```swift
// In AgentService.init()
Task {
    await restoreVMToAgentMappings()
}

// Restores mappings from database
private func restoreVMToAgentMappings() async {
    let vms = try await VM.query(on: db)
        .filter(\.$hypervisorId != nil)
        .all()

    for vm in vms {
        vmToAgentMapping[vm.id.uuidString] = vm.hypervisorId
    }
}
```

## Monitoring and Logging

The scheduler logs detailed information about placement decisions:

```
[INFO] Scheduling VM 'web-server-1' using least_loaded strategy
[INFO] Selected agent 'hypervisor-01' for VM 'web-server-1' - CPU: 12/16, Memory: 24GB/32GB, Disk: 100GB/500GB
```

### Diagnostic Endpoints

You can use `SchedulerService.getSchedulingInfo()` to get human-readable agent information:

```swift
let info = req.scheduler.getSchedulingInfo(for: agentId, in: schedulableAgents)
// Returns:
// Agent: hypervisor-01
// Status: online
// CPU: 12/16 (75.0% used)
// Memory: 24.0 GB/32.0 GB (75.0% used)
// Disk: 100.0 GB/500.0 GB (20.0% used)
// Running VMs: 8
```

## Future Enhancements

Potential improvements for future versions:

1. **Affinity Rules**: Place VMs together or apart based on labels/tags
2. **Zone/Rack Awareness**: Distribute across failure domains
3. **Resource Reservations**: Reserve capacity for specific projects/users
4. **Custom Constraints**: User-defined placement rules
5. **Metrics-Based Scheduling**: Use actual CPU/memory usage instead of allocations
6. **Migration Recommendations**: Suggest VM migrations to rebalance load
7. **Preemption**: Move lower-priority VMs to make room for high-priority ones
8. **GPU/Hardware Affinity**: Schedule based on specific hardware requirements

## Testing Recommendations

### Unit Tests

Test each scheduling strategy with various agent configurations:

```swift
func testLeastLoadedStrategy() async throws {
    let scheduler = SchedulerService(logger: app.logger, defaultStrategy: .leastLoaded)
    let agents = [/* mock agents */]
    let vm = VM(/* test VM */)

    let selectedAgentId = try scheduler.selectAgent(for: vm, from: agents)

    // Assert correct agent was selected
}
```

### Integration Tests

Test complete VM creation flow with multiple agents:

```swift
func testVMCreationWithScheduler() async throws {
    // Register multiple mock agents
    // Create VM
    // Verify VM is assigned to appropriate agent
    // Verify hypervisorId is persisted
}
```

## References

- **Implementation**: `control-plane/Sources/App/Services/SchedulerService.swift`
- **Agent Integration**: `control-plane/Sources/App/Services/AgentService.swift`
- **VM Controller**: `control-plane/Sources/App/Controllers/VMController.swift`
- **Configuration**: `control-plane/Sources/App/configure.swift`
- **VM Model**: `control-plane/Sources/App/Models/vm.swift`
