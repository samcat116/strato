import Fluent
import SQLKit
import StratoShared
import Vapor

extension WorkloadResourceClassPolicy: Content {}
extension WorkloadResourceClassSnapshot: Content {}
extension WorkloadResourceClassReference: Content {}

/// Catalog edits never touch admitted workload rows or generations.
enum WorkloadResourceClassService {
    struct Admission: Sendable {
        let snapshot: WorkloadResourceClassSnapshot
        let reservation: WorkloadAdmittedReservation

        func additionalReservation(over previous: WorkloadAdmittedReservation) -> ReservationAmounts {
            ReservationAmounts(
                memory: max(0, reservation.effectiveMemoryBytes - previous.effectiveMemoryBytes), disk: 0,
                cpuMicroUnits: max(0, reservation.cpuMicroUnits - previous.cpuMicroUnits))
        }
    }

    /// Caller holds the workload row lock inside the placement/mutation transaction.
    /// The shared site lock orders this admission before or after a catalog edit.
    static func currentPolicy(_ snapshot: WorkloadResourceClassSnapshot, on db: any Database) async throws
        -> WorkloadResourceClassSnapshot
    {
        guard let sql = db as? any SQLDatabase else { throw Abort(.internalServerError) }
        try await sql.raw("SELECT id FROM sites WHERE id = \(bind: snapshot.siteID) FOR SHARE").run()
        guard let site = try await Site.find(snapshot.siteID, on: db),
            let current = try site.resourceClasses().first(where: { $0.classID == snapshot.classID }),
            current.policy.kind == snapshot.policy.kind
        else { throw Abort(.conflict, reason: "The admitted resource class no longer exists in its site") }
        return current
    }

    /// Transaction planning only: this does not grant runtime admission or bypass its gates.
    static func placement(
        _ snapshot: WorkloadResourceClassSnapshot?, cpus: Int, memory: WorkloadMemoryReservation, on db: any Database
    ) async throws -> Admission? {
        guard let snapshot else { return nil }
        let current = try await currentPolicy(snapshot, on: db)
        return Admission(snapshot: current, reservation: .init(cpus: cpus, memory: memory, policy: current.policy))
    }

    /// Preserve historical pricing and resolve the catalog only for positive growth.
    static func growth(
        _ snapshot: WorkloadResourceClassSnapshot?, admitted: WorkloadAdmittedReservation?, currentCPUs: Int,
        currentMemory: WorkloadMemoryReservation, cpus: Int, memory: WorkloadMemoryReservation, on db: any Database
    ) async throws -> Admission? {
        guard let snapshot else { return nil }
        if snapshot.policy.kind == .guaranteed {
            guard admitted != nil else { return nil }
            return Admission(snapshot: snapshot, reservation: .init(cpus: cpus, memory: memory, policy: .guaranteed))
        }
        guard cpus > currentCPUs || memory.guestBytes > currentMemory.guestBytes else { return nil }
        guard let admitted else {
            throw Abort(
                .conflict,
                reason:
                    "Burstable growth requires its persisted admitted commitment; historical pricing cannot be inferred"
            )
        }
        let current = try await currentPolicy(snapshot, on: db)
        return Admission(
            snapshot: current, reservation: admitted.growing(cpus: cpus, memory: memory, policy: current.policy))
    }

    static func prepareVMResize(_ vm: VM, cpu: Int, memory: Int64, on db: any Database) async throws {
        guard vm.resourceClass != nil, let agentID = vm.hypervisorId.flatMap(UUID.init(uuidString:)),
            let agent = try await Agent.find(agentID, on: db),
            let committed = try await VM.find(vm.id, on: db)
        else { return }
        try requireGrowthAvailable(vm: committed, cpu: cpu, memory: memory)
        if committed.resourceClass?.policy.kind == .burstable, cpu <= committed.cpu, memory <= committed.memory {
            return
        }
        guard vm.resourceClass?.policy.kind != .burstable || vm.hypervisorType != .qemu || agent.cpuArchitecture != nil
        else {
            throw Abort(
                .conflict, reason: "The placed agent has not reported the architecture required for class accounting")
        }
        func footprint(_ bytes: Int64, maximum: Int64) -> WorkloadMemoryReservation {
            .vm(
                memoryBytes: bytes, maxMemoryBytes: maximum, hypervisorType: vm.hypervisorType,
                architecture: agent.cpuArchitecture ?? .current,
                qemuOverheadBytes: agent.memoryAccounting?.qemuOverheadBytes
                    ?? WorkloadMemoryReservation.defaultQEMUOverheadBytes)
        }
        if let snapshot = committed.resourceClass, snapshot.policy.kind == .burstable {
            let current = try await currentPolicy(snapshot, on: db)
            try await requireHostReadiness(
                current, backend: vm.hypervisorType == .qemu ? .qemuVM : nil, agentID: try agent.requireID().uuidString,
                on: db)
        }
        if let admission = try await growth(
            committed.resourceClass, admitted: committed.admittedReservation,
            currentCPUs: committed.cpu, currentMemory: footprint(committed.memory, maximum: committed.maxMemory),
            cpus: cpu, memory: footprint(memory, maximum: max(committed.maxMemory, memory)), on: db)
        {
            vm.resourceClass = admission.snapshot
            vm.admittedReservation = admission.reservation
        }
    }

    /// Host readiness is necessary evidence, not proof of a workload's applied limits.
    /// The runtime must separately guard pre-execution enforcement/readback by generation.
    static func hostRefusal(
        _ snapshot: WorkloadResourceClassSnapshot, backend: WorkloadResourceClassBackend, agent: Agent, now: Date
    ) -> String? {
        guard snapshot.policy.kind == .burstable else { return nil }
        guard agent.$site.id == snapshot.siteID else {
            return "Resource class does not belong to the selected agent's site"
        }
        let evidence = (agent.resourceClassEnforcement ?? []).filter { $0.backend == backend }
        guard evidence.count == 1, evidence[0].supportsBurstable else {
            return "Selected backend lacks complete STR272 enforcement evidence"
        }
        guard let receivedAt = agent.resourceTelemetryReceivedAt else {
            return "Burstable admission requires control-plane-received pressure telemetry"
        }
        return snapshot.policy.admissionRefusal(telemetry: agent.resourceTelemetry, now: now, receivedAt: receivedAt)
    }

    static func requireHostReadiness(
        _ snapshot: WorkloadResourceClassSnapshot?, backend: WorkloadResourceClassBackend?, agentID: String,
        on db: any Database
    ) async throws {
        guard let snapshot, snapshot.policy.kind == .burstable else { return }
        guard let backend else {
            throw Abort(.unprocessableEntity, reason: "Ordinary Firecracker VMs cannot enforce the burstable class")
        }
        guard let id = UUID(uuidString: agentID), let agent = try await Agent.find(id, on: db), agent.status == .online
        else {
            throw Abort(.conflict, reason: "The selected class host is no longer online")
        }
        let now = try await ClusterClock.read(on: db)
        if let refusal = hostRefusal(snapshot, backend: backend, agent: agent, now: now.date) {
            throw Abort(
                .unprocessableEntity,
                reason: "Resource class \(snapshot.classID) revision \(snapshot.revision): \(refusal)")
        }
    }

    static func requireGrowthAvailable(vm: VM, cpu: Int, memory: Int64) throws {
        guard vm.resourceClass?.policy.kind == .burstable,
            cpu > vm.cpu || memory > vm.memory
        else { return }
        throw Abort(
            .unprocessableEntity,
            reason: "Burstable growth is unavailable until verified STR272 runtime enforcement is installed")
    }

    static func resolve(
        _ reference: WorkloadResourceClassReference?, project: Project, req: Request
    ) async throws -> WorkloadResourceClassSnapshot? {
        guard let reference else { return nil }
        guard let site = try await Site.find(reference.siteID, on: req.db),
            try await req.can("site:read", on: IAMNode(type: .site, id: reference.siteID))
        else { throw Abort(.notFound, reason: "Resource class site not found") }
        let projectScope = try OrganizationScope.from(
            organizationID: project.$organization.id, organizationalUnitID: project.$organizationalUnit.id)
        guard let projectRoot = try await projectScope?.rootOrganizationID(on: req.db),
            try await site.rootOrganizationID(on: req.db) == projectRoot
        else { throw Abort(.notFound, reason: "Resource class site not found") }
        guard let snapshot = try site.resourceClasses().first(where: { $0.classID == reference.classID }) else {
            throw Abort(.notFound, reason: "Resource class not found")
        }
        // STR272 must replace this gate only after pre-execution enforcement,
        // ownership and effective readback are complete for every selected backend.
        guard snapshot.policy.kind == .guaranteed else {
            throw Abort(
                .unprocessableEntity,
                reason:
                    "Burstable admission is unavailable until verified STR272 runtime enforcement is installed")
        }
        return snapshot
    }
}
