import Foundation
import Vapor
import StratoShared
import NIOWebSocket
import Fluent
import NIOCore
import NIOConcurrencyHelpers

/// Thread-safe WebSocket connection manager
/// This is NOT an actor to avoid event loop conflicts with NIO
/// WebSocket objects are event-loop-bound and must only be accessed from their event loop
final class WebSocketManager: @unchecked Sendable {
    private let lock = NIOLock()
    private var connections: [String: WebSocket] = [:]  // Agent name -> WebSocket

    /// Must be called from the WebSocket's event loop
    func setConnection(agentName: String, websocket: WebSocket) {
        lock.withLock {
            connections[agentName] = websocket
        }
    }

    /// Returns the WebSocket for an agent - must be used on WebSocket's event loop
    func getConnection(agentName: String) -> WebSocket? {
        lock.withLock {
            connections[agentName]
        }
    }

    /// Remove connection by agent name
    func removeConnection(agentName: String) {
        lock.withLock {
            _ = connections.removeValue(forKey: agentName)
        }
    }

    /// Remove the connection for an agent only if the stored socket is the given
    /// instance. Used by close handlers so a delayed close from a replaced
    /// connection cannot tear down its successor (e.g. after an agent reconnects
    /// under the same name). Returns true when the connection was removed.
    func removeConnection(agentName: String, ifCurrent websocket: WebSocket) -> Bool {
        lock.withLock {
            guard connections[agentName] === websocket else { return false }
            connections.removeValue(forKey: agentName)
            return true
        }
    }

    /// Get all agent names (for diagnostics)
    func getAllAgentNames() -> [String] {
        lock.withLock {
            Array(connections.keys)
        }
    }
}

actor AgentService {
    private let app: Application
    private var agents: [String: AgentInfo] = [:]
    private var vmToAgentMapping: [String: String] = [:]  // VM ID -> Agent ID
    private var pendingRequests: [String: PendingRequest] = [:]
    private var heartbeatTask: Task<Void, Never>?

    /// A request awaiting a response from a specific agent.
    /// Tracking the agent lets us fail all of an agent's in-flight requests when it disconnects.
    private struct PendingRequest {
        let agentId: String
        let continuation: CheckedContinuation<AgentServiceResponse, Error>
        /// The 30s timeout armed for this request, cancelled whenever the request
        /// is removed (normal response, disconnect, or the timeout firing itself)
        /// so a completed request never leaves a timer sleeping to no purpose.
        var timeoutTask: Task<Void, Never>?
    }

    /// Set at application shutdown. Guards against the init task arming the
    /// heartbeat monitor after `shutdown()` already ran.
    private var isShutDown = false

    init(app: Application) {
        self.app = app
        // Start heartbeat monitoring and restore VM mappings after initialization
        Task {
            await startHeartbeatMonitoring()
            await restoreVMToAgentMappings()
        }
    }

    /// Cancel the heartbeat monitoring loop. Called from the application's
    /// shutdown lifecycle (see `AgentServiceLifecycleHandler`): the loop holds
    /// the `Application` and sweeps the database every 30 seconds, so a tick
    /// that fires after shutdown would hit Vapor's "Core not configured"
    /// fatal error — long-lived test processes crash exactly this way.
    func shutdown() {
        isShutDown = true
        heartbeatTask?.cancel()
        heartbeatTask = nil
    }

    // MARK: - VM-to-Agent Mapping Recovery

    /// Restore VM-to-agent mappings from database on startup
    /// This ensures that if the control plane restarts, we don't lose track of which VMs are on which agents
    private func restoreVMToAgentMappings() async {
        do {
            let db = app.db
            let vms = try await VM.query(on: db)
                .filter(\.$hypervisorId != nil)
                .all()

            for vm in vms {
                if let vmId = vm.id?.uuidString, let hypervisorId = vm.hypervisorId {
                    vmToAgentMapping[vmId] = hypervisorId
                }
            }

            app.logger.info("Restored VM-to-agent mappings for \(vms.count) VMs from database")
        } catch {
            app.logger.error("Failed to restore VM-to-agent mappings from database: \(error)")
        }
    }

    // MARK: - Agent Registration

    /// Registers an agent and returns its database UUID
    func registerAgent(_ message: AgentRegisterMessage, agentName: String) async throws -> UUID {
        let db = app.db

        // Find existing agent or create new one
        let agent: Agent
        if let existingAgent = try await Agent.query(on: db)
            .filter(\.$name == agentName)
            .first()
        {
            // Update existing agent
            agent = existingAgent
            agent.hostname = message.hostname
            agent.version = message.version
            agent.capabilities = message.capabilities
            agent.architecture = message.architecture?.rawValue
            agent.hypervisors = message.effectiveHypervisors
            agent.networkCapability = message.networkCapability?.rawValue
            agent.updateResources(message.resources)
            agent.status = .online
        } else {
            // Create new agent
            agent = Agent.from(registration: message, name: agentName)
            agent.status = .online
        }

        try await agent.save(on: db)

        guard let agentUUID = agent.id else {
            throw AgentServiceError.invalidResponse("Failed to get agent ID after save")
        }

        // Update in-memory tracking using UUID as the key
        let agentInfo = AgentInfo(
            id: agentUUID.uuidString,
            name: agentName,
            hostname: message.hostname,
            version: message.version,
            capabilities: message.capabilities,
            architecture: message.architecture,
            hypervisors: message.effectiveHypervisors,
            networkCapability: message.networkCapability,
            resources: message.resources,
            lastHeartbeat: Date(),
            status: .online
        )

        agents[agentUUID.uuidString] = agentInfo

        Telemetry.agentConnected()
        Telemetry.recordAgentUp(agentName: agentName, up: true)
        app.logger.info(
            "Agent registered",
            metadata: [
                "agentId": .string(agentUUID.uuidString),
                "agentName": .string(agentName),
                "hostname": .string(message.hostname),
                "version": .string(message.version),
            ])

        return agentUUID
    }

    /// Find agent UUID by name in the in-memory agents dictionary
    private func findAgentIdByName(_ agentName: String) -> String? {
        return agents.first(where: { $0.value.name == agentName })?.key
    }

    func unregisterAgent(_ agentId: String) async throws {
        let db = app.db

        // Update database using UUID
        if let agentUUID = UUID(uuidString: agentId),
            let agent = try await Agent.find(agentUUID, on: db)
        {
            agent.status = .offline
            try await agent.save(on: db)
        }

        // Get agent name for WebSocket cleanup
        let agentName = agents[agentId]?.name

        // Fail any in-flight requests waiting on this agent before we drop it
        failPendingRequests(for: agentId)

        // Remove from in-memory tracking
        agents.removeValue(forKey: agentId)
        if let name = agentName {
            app.websocketManager.removeConnection(agentName: name)
        }

        // Remove VM mappings for this agent
        let vmIds = vmToAgentMapping.compactMap { (vmId, mappedAgentId) in
            mappedAgentId == agentId ? vmId : nil
        }

        for vmId in vmIds {
            vmToAgentMapping.removeValue(forKey: vmId)
        }

        Telemetry.agentDisconnected(reason: "unregister")
        if let name = agentName {
            Telemetry.recordAgentUp(agentName: name, up: false)
        }
        app.logger.info("Agent unregistered", metadata: ["agentId": .string(agentId)])
    }

    func forceUnregisterAgent(_ agentName: String) async {
        // Find agent UUID by name
        guard let agentId = findAgentIdByName(agentName) else {
            app.logger.warning(
                "Cannot force unregister: agent not found by name", metadata: ["agentName": .string(agentName)])
            return
        }

        // Fail any in-flight requests waiting on this agent before we drop it
        failPendingRequests(for: agentId)

        // Remove from in-memory tracking
        agents.removeValue(forKey: agentId)
        app.websocketManager.removeConnection(agentName: agentName)

        // Remove VM mappings for this agent
        let vmIds = vmToAgentMapping.compactMap { (vmId, mappedAgentId) in
            mappedAgentId == agentId ? vmId : nil
        }

        for vmId in vmIds {
            vmToAgentMapping.removeValue(forKey: vmId)
        }

        app.logger.info(
            "Agent force unregistered from memory",
            metadata: ["agentId": .string(agentId), "agentName": .string(agentName)])
    }

    func removeAgent(_ agentName: String) async {
        // Find agent UUID by name
        guard let agentId = findAgentIdByName(agentName) else {
            app.logger.debug("Cannot remove agent: not found by name", metadata: ["agentName": .string(agentName)])
            return
        }

        // Fail any in-flight requests waiting on this agent before we drop it
        failPendingRequests(for: agentId)

        // Mark agent as offline in memory
        agents.removeValue(forKey: agentId)

        Telemetry.agentDisconnected(reason: "connection_closed")
        Telemetry.recordAgentUp(agentName: agentName, up: false)

        // Update database status asynchronously
        Task {
            do {
                let db = self.app.db
                if let agentUUID = UUID(uuidString: agentId),
                    let agent = try await Agent.find(agentUUID, on: db)
                {
                    agent.status = .offline
                    try await agent.save(on: db)
                }
            } catch {
                self.app.logger.error("Failed to update agent offline status in database: \(error)")
            }
        }
    }

    /// `agentName` identifies the authenticated connection the heartbeat arrived on;
    /// the claimed `agentId` must belong to it, so one agent cannot drive another
    /// agent's resource tracking or VM reconciliation.
    func updateAgentHeartbeat(_ message: AgentHeartbeatMessage, fromAgentNamed agentName: String) async throws {
        guard var agentInfo = agents[message.agentId] else {
            app.logger.warning("Received heartbeat from unknown agent", metadata: ["agentId": .string(message.agentId)])
            return
        }

        guard agentInfo.name == agentName else {
            app.logger.warning(
                "Heartbeat claims an agentId not owned by the authenticated connection; ignoring",
                metadata: [
                    "claimedAgentId": .string(message.agentId),
                    "claimedAgentName": .string(agentInfo.name),
                    "connectionAgentName": .string(agentName),
                ])
            return
        }

        // Update in-memory tracking
        agentInfo.resources = message.resources
        agentInfo.lastHeartbeat = Date()
        agentInfo.status = .online
        agents[message.agentId] = agentInfo

        // Update database asynchronously using UUID
        Task {
            do {
                let db = self.app.db
                guard let agentUUID = UUID(uuidString: message.agentId) else {
                    self.app.logger.error("Invalid agent UUID in heartbeat: \(message.agentId)")
                    return
                }
                if let agent = try await Agent.find(agentUUID, on: db) {
                    agent.updateResources(message.resources)
                    agent.status = .online
                    try await agent.save(on: db)
                }
            } catch {
                self.app.logger.error("Failed to update agent heartbeat in database: \(error)")
            }
        }

        // Reconcile the VMs the agent reports against what the database expects.
        Task {
            await self.reconcileVMs(forAgentId: message.agentId, reportedVMs: message.runningVMs)
        }

        app.logger.debug("Agent heartbeat updated", metadata: ["agentId": .string(message.agentId)])
    }

    /// Reconciles an agent's reported set of managed VMs against the database.
    ///
    /// An agent's heartbeat lists every VM it is managing (running, paused, or
    /// shut-down-but-not-deleted). If the database believes a VM lives on this agent
    /// but the agent no longer reports it — e.g. the agent crashed and lost the VM,
    /// or the process died — the database's view is stale and we mark the VM `.error`
    /// so it surfaces for operator attention instead of appearing healthy.
    private func reconcileVMs(forAgentId agentId: String, reportedVMs: [String]) async {
        let db = app.db
        let managed = Set(reportedVMs)

        do {
            let dbVMs = try await VM.query(on: db)
                .filter(\.$hypervisorId == agentId)
                .all()

            var divergent = 0
            for vm in dbVMs {
                guard let vmId = vm.id?.uuidString else { continue }

                // Only established states are safe to reconcile on absence:
                //  - `.created` may still be mid-creation (image download / first boot)
                //  - transitional and `.error`/`.unknown` states are handled by the sweep
                // so an absent VM in those states is expected and left alone.
                // `.shutdown` counts as established: agents keep shut-down-but-not-deleted
                // VMs in their managed set, so one missing from the heartbeat was lost
                // (e.g. agent restart) and a later start would fail with vmNotFound.
                let reconcilable = (vm.status == .running || vm.status == .paused || vm.status == .shutdown)
                guard reconcilable, !managed.contains(vmId) else { continue }

                let previous = vm.status
                vm.setStatus(.error)
                try await vm.save(on: db)
                divergent += 1
                Telemetry.vmEnteredError(reason: "reconciliation")

                app.logger.warning(
                    "VM missing from agent heartbeat; marking as error",
                    metadata: [
                        "vmId": .string(vmId),
                        "agentId": .string(agentId),
                        "previousStatus": .string(previous.rawValue),
                    ])
            }

            // Orphans: VMs the agent reports that the database does not map to it.
            let knownIds = Set(dbVMs.compactMap { $0.id?.uuidString })
            let orphans = managed.subtracting(knownIds)
            if !orphans.isEmpty {
                app.logger.warning(
                    "Agent reports VMs unknown to control plane",
                    metadata: [
                        "agentId": .string(agentId),
                        "orphanVMs": .string(orphans.sorted().joined(separator: ",")),
                    ])
            }

            if divergent > 0 {
                app.logger.info(
                    "Reconciliation marked \(divergent) VM(s) as error", metadata: ["agentId": .string(agentId)])
            }
        } catch {
            app.logger.error("VM reconciliation failed for agent \(agentId): \(error)")
        }
    }

    // MARK: - Heartbeat Monitoring

    /// Whether the heartbeat loop is currently armed. Test seam for verifying that
    /// the shutdown hook tears it down.
    var isHeartbeatActive: Bool {
        heartbeatTask != nil
    }

    private func startHeartbeatMonitoring() {
        // Don't (re)arm the loop if shutdown already raced ahead of init.
        guard !isShutDown else { return }
        heartbeatTask = Task {
            while !Task.isCancelled {
                do {
                    // Sleep for 30 seconds
                    try await Task.sleep(for: .seconds(30))

                    // Check for stale agents
                    await checkStaleAgents()

                    // Move VMs stuck in a transitional state to error
                    await sweepStuckTransitionalVMs()
                } catch {
                    if !Task.isCancelled {
                        app.logger.error("Error in heartbeat monitoring task: \(error)")
                    }
                }
            }
        }
    }

    private func checkStaleAgents() async {
        let now = Date()
        let staleThreshold: TimeInterval = 60  // 60 seconds

        // Export per-agent heartbeat staleness as a gauge every cycle so alerting
        // can watch an agent go quiet before the sweep removes it.
        for agentInfo in agents.values {
            Telemetry.recordHeartbeatStaleness(
                agentName: agentInfo.name,
                seconds: now.timeIntervalSince(agentInfo.lastHeartbeat)
            )
        }

        let staleAgents = agents.values.compactMap { agentInfo -> String? in
            if now.timeIntervalSince(agentInfo.lastHeartbeat) > staleThreshold {
                return agentInfo.id  // This is the UUID
            }
            return nil
        }

        if !staleAgents.isEmpty {
            app.logger.info("Found \(staleAgents.count) stale agents, marking as offline")

            for agentId in staleAgents {
                // Fail any in-flight requests waiting on this agent before we drop it
                failPendingRequests(for: agentId)

                // Capture the name before removal so the up/down gauge keeps a
                // durable `0` for this specific agent after it leaves memory.
                let staleAgentName = agents[agentId]?.name

                // Remove from memory
                agents.removeValue(forKey: agentId)

                Telemetry.agentDisconnected(reason: "stale")
                if let name = staleAgentName {
                    Telemetry.recordAgentUp(agentName: name, up: false)
                }

                // Update database using UUID
                Task {
                    do {
                        let db = self.app.db
                        if let agentUUID = UUID(uuidString: agentId),
                            let agent = try await Agent.find(agentUUID, on: db)
                        {
                            agent.status = .offline
                            try await agent.save(on: db)
                        }
                    } catch {
                        self.app.logger.error("Failed to update stale agent status in database: \(error)")
                    }
                }
            }
        }
    }

    /// Moves VMs that have been stuck in a transitional state (.starting/.stopping)
    /// longer than the timeout to `.error`. This catches operations whose terminal
    /// confirmation never arrived — e.g. the agent crashed mid-boot, or the
    /// statusUpdate message was lost.
    private func sweepStuckTransitionalVMs() async {
        let db = app.db
        let timeout: TimeInterval = 120  // a VM may legitimately be transitional this long
        let now = Date()

        do {
            let transitional = try await VM.query(on: db)
                .filter(\.$status ~~ [.starting, .stopping])
                .all()

            for vm in transitional {
                // Fall back to updatedAt, then now, if the timestamp is somehow missing
                // (a missing timestamp yields age 0 and is left for the next sweep).
                let changedAt = vm.statusChangedAt ?? vm.updatedAt ?? now
                guard now.timeIntervalSince(changedAt) > timeout else { continue }

                let previous = vm.status
                vm.setStatus(.error)
                try await vm.save(on: db)
                Telemetry.vmEnteredError(reason: "stuck_transition")

                app.logger.warning(
                    "VM stuck in transitional state past timeout; marking as error",
                    metadata: [
                        "vmId": .string(vm.id?.uuidString ?? ""),
                        "stuckStatus": .string(previous.rawValue),
                        "timeoutSeconds": .string("\(Int(timeout))"),
                    ])
            }
        } catch {
            app.logger.error("Stuck-VM sweep failed: \(error)")
        }
    }

    // MARK: - VM Operations

    /// Creates a VM on an agent selected by the scheduler
    /// - Parameters:
    ///   - vm: The VM to create
    ///   - vmSpec: Hypervisor-neutral VM specification
    ///   - db: Database connection
    ///   - strategy: Optional scheduling strategy override
    ///   - image: Optional image for image-based VM creation (will generate signed download URL)
    func createVM(vm: VM, vmSpec: VMSpec, db: Database, strategy: SchedulingStrategy? = nil, image: Image? = nil)
        async throws
    {
        // Convert agents to schedulable format
        let schedulableAgents = getSchedulableAgents()

        // Use scheduler to select best agent
        let agentId: String
        do {
            agentId = try app.scheduler.selectAgent(
                for: vm,
                from: schedulableAgents,
                strategy: strategy
            )
        } catch let error as SchedulerError {
            app.logger.error("Scheduler failed to find suitable agent: \(error)")
            // Preserve the scheduler's reason (unsupported hypervisor, arch
            // mismatch, insufficient resources, ...) instead of collapsing
            // every placement failure into a generic "no agent available".
            throw AgentServiceError.schedulingFailed(error.description)
        }

        guard agents[agentId] != nil else {
            throw AgentServiceError.agentNotFound(agentId)
        }

        // Build ImageInfo with signed URL now that we know the agent
        var imageInfo: ImageInfo?
        if let image = image {
            do {
                let controlPlaneURL = Environment.get("CONTROL_PLANE_URL") ?? "http://localhost:8080"
                let signingKey = try URLSigningService.getSigningKey(from: app)
                imageInfo = try VMSpecBuilder.buildImageInfo(
                    from: image,
                    controlPlaneURL: controlPlaneURL,
                    agentName: agentId,
                    signingKey: signingKey
                )
            } catch {
                app.logger.error("Failed to build image info: \(error)")
                throw error
            }
        }

        let message = VMCreateMessage(
            vmData: vm.toVMData(),
            vmSpec: vmSpec,
            imageInfo: imageInfo
        )

        try await sendMessageToAgent(message, agentId: agentId)

        // Map VM to agent (in-memory)
        vmToAgentMapping[vm.id?.uuidString ?? ""] = agentId

        // Persist hypervisor assignment to database
        vm.hypervisorId = agentId
        try await vm.save(on: db)

        app.logger.info(
            "VM creation requested",
            metadata: [
                "vmId": .string(vm.id?.uuidString ?? ""),
                "agentId": .string(agentId),
                "hasImageInfo": .string(imageInfo != nil ? "yes" : "no"),
            ])
    }

    func performVMOperation(_ operation: MessageType, vmId: String) async throws {
        guard let agentId = vmToAgentMapping[vmId] else {
            throw AgentServiceError.vmNotMapped(vmId)
        }

        guard agents[agentId] != nil else {
            throw AgentServiceError.agentNotFound(agentId)
        }

        let message = VMOperationMessage(type: operation, vmId: vmId)
        try await sendMessageToAgent(message, agentId: agentId)

        app.logger.info(
            "VM operation requested",
            metadata: [
                "operation": .string(operation.rawValue),
                "vmId": .string(vmId),
                "agentId": .string(agentId),
            ])
    }

    func getVMInfo(vmId: String) async throws -> VmInfo {
        guard let agentId = vmToAgentMapping[vmId] else {
            throw AgentServiceError.vmNotMapped(vmId)
        }

        guard agents[agentId] != nil else {
            throw AgentServiceError.agentNotFound(agentId)
        }

        let message = VMInfoRequestMessage(vmId: vmId)
        let response = try await sendMessageToAgentWithResponse(message, agentId: agentId)

        guard case .success(let data) = response,
            let vmInfo = try? data?.decode(as: VmInfo.self)
        else {
            throw AgentServiceError.invalidResponse("Failed to decode VM info")
        }

        return vmInfo
    }

    func getVMStatus(vmId: String) async throws -> VMStatus {
        guard let agentId = vmToAgentMapping[vmId] else {
            throw AgentServiceError.vmNotMapped(vmId)
        }

        guard agents[agentId] != nil else {
            throw AgentServiceError.agentNotFound(agentId)
        }

        let message = VMOperationMessage(type: .vmStatus, vmId: vmId)
        let response = try await sendMessageToAgentWithResponse(message, agentId: agentId)

        guard case .success(let data) = response,
            let status = try? data?.decode(as: VMStatus.self)
        else {
            throw AgentServiceError.invalidResponse("Failed to decode VM status")
        }

        return status
    }

    // MARK: - Agent Selection

    /// Convert in-memory agents to schedulable format for the scheduler service
    private func getSchedulableAgents() -> [SchedulableAgent] {
        Self.schedulableAgents(from: Array(agents.values), vmToAgentMapping: vmToAgentMapping)
    }

    /// Pure transform from in-memory agent state to the scheduler's view. The
    /// running-VM count for each agent is derived from `vmToAgentMapping`. Kept
    /// `nonisolated static` so it can be unit-tested without the actor.
    nonisolated static func schedulableAgents(
        from agents: [AgentInfo],
        vmToAgentMapping: [String: String]
    ) -> [SchedulableAgent] {
        return agents.map { agentInfo in
            SchedulableAgent(
                id: agentInfo.id,  // Database UUID (as String)
                name: agentInfo.name,  // Human-readable name
                totalCPU: agentInfo.resources.totalCPU,
                availableCPU: agentInfo.resources.availableCPU,
                totalMemory: agentInfo.resources.totalMemory,
                availableMemory: agentInfo.resources.availableMemory,
                totalDisk: agentInfo.resources.totalDisk,
                availableDisk: agentInfo.resources.availableDisk,
                status: agentInfo.status,
                runningVMCount: vmToAgentMapping.values.filter { $0 == agentInfo.id }.count,
                supportedHypervisors: agentInfo.supportedHypervisors,
                architecture: agentInfo.architecture,
                supportsInterVMNetworking: agentInfo.supportsInterVMNetworking
            )
        }
    }

    /// Get VM-to-agent mapping (for diagnostics and recovery)
    func getVMToAgentMapping() -> [String: String] {
        return vmToAgentMapping
    }

    /// Manually set VM-to-agent mapping (for recovery scenarios)
    func setVMToAgentMapping(vmId: String, agentId: String) {
        vmToAgentMapping[vmId] = agentId
    }

    // MARK: - Message Sending

    private func sendMessageToAgent<T: WebSocketMessage>(_ message: T, agentId: String) async throws {
        // Look up agent info to get the name for WebSocket lookup
        guard let agentInfo = agents[agentId] else {
            throw AgentServiceError.agentNotFound(agentId)
        }

        guard let websocket = app.websocketManager.getConnection(agentName: agentInfo.name) else {
            throw AgentServiceError.agentNotFound(agentId)
        }

        let envelope = try MessageEnvelope(message: message)
        let data = try WireProtocol.makeEncoder().encode(envelope)

        websocket.send(data)
    }

    /// Send a message to an agent and await the correlated success/error response.
    /// Also used by other services (e.g. VolumeService) that must confirm an agent
    /// completed an operation before reconciling database state. The timeout should
    /// be sized to the operation: metadata ops finish in seconds, while image-backed
    /// volume creation or a clone can copy gigabytes.
    func sendMessageToAgentWithResponse<T: WebSocketMessage>(
        _ message: T,
        agentId: String,
        timeout: Duration = .seconds(30)
    ) async throws -> AgentServiceResponse {
        return try await withCheckedThrowingContinuation { continuation in
            Task {
                do {
                    // Store continuation for response handling
                    self.storePendingRequest(message.requestId, agentId: agentId, continuation: continuation)

                    // Send message
                    try await self.sendMessageToAgent(message, agentId: agentId)

                    // Arm a timeout, tracking its handle so a normal response can
                    // cancel it instead of leaving a task dangling per request.
                    let requestId = message.requestId
                    let timeoutTask = Task {
                        try? await Task.sleep(for: timeout)
                        guard !Task.isCancelled else { return }
                        self.timeoutRequest(requestId)
                    }
                    self.attachTimeout(timeoutTask, to: requestId)
                } catch {
                    _ = self.removePendingRequest(message.requestId)
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func storePendingRequest(
        _ requestId: String, agentId: String, continuation: CheckedContinuation<AgentServiceResponse, Error>
    ) {
        pendingRequests[requestId] = PendingRequest(agentId: agentId, continuation: continuation)
    }

    /// Associates a timeout task with a still-pending request. If the request has
    /// already resolved (a fast response beat the timeout being armed), the task is
    /// cancelled immediately so it doesn't linger.
    private func attachTimeout(_ task: Task<Void, Never>, to requestId: String) {
        guard pendingRequests[requestId] != nil else {
            task.cancel()
            return
        }
        pendingRequests[requestId]?.timeoutTask = task
    }

    private func removePendingRequest(_ requestId: String) -> CheckedContinuation<AgentServiceResponse, Error>? {
        guard let request = pendingRequests.removeValue(forKey: requestId) else { return nil }
        request.timeoutTask?.cancel()
        return request.continuation
    }

    private func timeoutRequest(_ requestId: String) {
        if let continuation = removePendingRequest(requestId) {
            continuation.resume(throwing: AgentServiceError.requestTimeout)
        }
    }

    /// Fail all in-flight requests targeting an agent that has gone away, so callers
    /// get a prompt error instead of waiting for the per-request timeout.
    private func failPendingRequests(for agentId: String, reason: AgentServiceError = .connectionLost) {
        let affected = pendingRequests.filter { $0.value.agentId == agentId }
        guard !affected.isEmpty else { return }

        for (requestId, request) in affected {
            pendingRequests.removeValue(forKey: requestId)
            request.timeoutTask?.cancel()
            request.continuation.resume(throwing: reason)
        }

        app.logger.info(
            "Failed \(affected.count) in-flight request(s) for disconnected agent",
            metadata: [
                "agentId": .string(agentId)
            ])
    }

    // MARK: - Response Handling

    func handleAgentResponse(_ envelope: MessageEnvelope) {
        Task {
            // Extract the original request's ID from the typed payload so we can
            // correlate the response with the continuation that is waiting for it.
            let requestId: String
            do {
                switch envelope.type {
                case .success:
                    requestId = try envelope.decode(as: SuccessMessage.self).requestId
                case .error:
                    requestId = try envelope.decode(as: ErrorMessage.self).requestId
                default:
                    // Other message types (e.g. unsolicited statusUpdate) are not
                    // request/response correlated and are handled elsewhere.
                    return
                }
            } catch {
                app.logger.error("Failed to decode agent response envelope: \(error)")
                return
            }

            guard let continuation = self.removePendingRequest(requestId) else {
                return
            }

            do {
                switch envelope.type {
                case .success:
                    let message = try envelope.decode(as: SuccessMessage.self)
                    continuation.resume(returning: .success(message.data))
                case .error:
                    let message = try envelope.decode(as: ErrorMessage.self)
                    continuation.resume(returning: .error(message.error, message.details))
                default:
                    continuation.resume(throwing: AgentServiceError.invalidResponse("Unexpected response type"))
                }
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    /// Applies an unsolicited VM status update reported by an agent to the database.
    /// This is how transitional states (.starting/.stopping) get confirmed into their
    /// terminal states (.running/.shutdown/.paused) once the agent completes the work.
    /// `agentName` identifies the authenticated connection the update arrived on, so
    /// an agent can only mutate VMs the database actually maps to it.
    func applyStatusUpdate(_ envelope: MessageEnvelope, fromAgentNamed agentName: String) {
        Task {
            let update: StatusUpdateMessage
            do {
                update = try envelope.decode(as: StatusUpdateMessage.self)
            } catch {
                app.logger.error("Failed to decode status update from agent: \(error)")
                return
            }

            guard let vmUUID = UUID(uuidString: update.vmId) else {
                app.logger.warning(
                    "Status update referenced an invalid VM id", metadata: ["vmId": .string(update.vmId)])
                return
            }

            guard let senderAgentId = self.findAgentIdByName(agentName) else {
                app.logger.warning(
                    "Status update from unregistered agent; ignoring",
                    metadata: [
                        "vmId": .string(update.vmId),
                        "agentName": .string(agentName),
                    ])
                return
            }

            do {
                guard let vm = try await VM.find(vmUUID, on: app.db) else {
                    app.logger.warning("Status update for unknown VM", metadata: ["vmId": .string(update.vmId)])
                    return
                }

                guard vm.hypervisorId == senderAgentId else {
                    app.logger.warning(
                        "Status update from agent that does not own the VM; ignoring",
                        metadata: [
                            "vmId": .string(update.vmId),
                            "agentName": .string(agentName),
                            "senderAgentId": .string(senderAgentId),
                            "owningAgentId": .string(vm.hypervisorId ?? "none"),
                        ])
                    return
                }

                guard vm.status != update.status else { return }

                // A transitional state means a control-plane-initiated operation is in
                // flight. Only the confirmation that completes that transition (or an
                // error) may land; anything else is a delayed update from an operation
                // that predates the transition — the controller guards (canStart/canStop/
                // canPause) make any other concurrent operation impossible — and applying
                // it would mask the in-flight one (e.g. a late `Paused` overwriting
                // `.stopping`, hiding a lost stop from the sweep).
                if vm.status.isTransitional {
                    let expected: Set<VMStatus> =
                        vm.status == .starting
                        ? [.running, .error]
                        : [.shutdown, .error]
                    guard expected.contains(update.status) else {
                        app.logger.warning(
                            "Ignoring stale agent status update during in-flight operation",
                            metadata: [
                                "vmId": .string(update.vmId),
                                "current": .string(vm.status.rawValue),
                                "reported": .string(update.status.rawValue),
                            ])
                        return
                    }
                }

                let previous = vm.status
                vm.setStatus(update.status)
                try await vm.save(on: app.db)
                if update.status == .error {
                    // The agent pushed an error state — e.g. a failed create/boot.
                    Telemetry.vmEnteredError(reason: "agent_reported")
                }

                app.logger.info(
                    "Applied agent status update",
                    metadata: [
                        "vmId": .string(update.vmId),
                        "from": .string(previous.rawValue),
                        "to": .string(update.status.rawValue),
                    ])
            } catch {
                app.logger.error("Failed to apply status update for VM \(update.vmId): \(error)")
            }
        }
    }

    // MARK: - Agent Status

    func getAgentList() -> [AgentInfo] {
        return Array(agents.values)
    }

    func getAgentInfo(_ agentId: String) -> AgentInfo? {
        return agents[agentId]
    }
}

// MARK: - Application Extension

extension Application {
    private struct WebSocketManagerKey: StorageKey, LockKey {
        typealias Value = WebSocketManager
    }

    var websocketManager: WebSocketManager {
        get {
            lazyService(WebSocketManagerKey.self) { WebSocketManager() }
        }
        set {
            storage[WebSocketManagerKey.self] = newValue
        }
    }

    private struct AgentServiceKey: StorageKey, LockKey {
        typealias Value = AgentService
    }

    var agentService: AgentService {
        get {
            lazyService(AgentServiceKey.self) { AgentService(app: self) }
        }
        set {
            storage[AgentServiceKey.self] = newValue
        }
    }

    /// The `AgentService` if one has already been created, without lazily
    /// creating it. Shutdown must not instantiate the service (that would arm
    /// the very heartbeat task shutdown exists to cancel).
    var agentServiceIfCreated: AgentService? {
        storage[AgentServiceKey.self]
    }
}

/// Cancels the agent heartbeat monitor at application shutdown so its
/// periodic database sweep never outlives the application.
struct AgentServiceLifecycleHandler: LifecycleHandler {
    func shutdownAsync(_ application: Application) async {
        await application.agentServiceIfCreated?.shutdown()
    }
}

extension Request {
    var agentService: AgentService {
        return application.agentService
    }
}
