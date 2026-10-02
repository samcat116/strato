import Fluent
import StratoShared
import Vapor

/// A config update may be a no-op. Compare after refreshing under the row lock,
/// so retries and concurrent edits cannot overwrite a newer generation (STR-92).
struct VMGuestConfigMutation {
    let dispatch: any AgentDispatch
    let logger: Logger

    static func normalized(_ config: GuestConfig?) -> GuestConfig? {
        guard let config else { return nil }
        guard !config.packages.isEmpty || !config.files.isEmpty || !config.services.isEmpty || !config.sysctls.isEmpty
        else {
            return nil
        }
        return GuestConfig(
            packages: config.packages.sorted { $0.name < $1.name },
            files: config.files.sorted { $0.path < $1.path },
            services: config.services.sorted { $0.name < $1.name },
            sysctls: config.sysctls.sorted { $0.key < $1.key })
    }

    static func equivalent(_ lhs: GuestConfig?, _ rhs: GuestConfig?) throws -> Bool {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        // Swift String equality treats canonical Unicode spellings as equal.
        // Guest file bytes and hashes do not, so compare deterministic wire
        // bytes after sorting identities rather than synthesized Equatable.
        return try encoder.encode(normalized(lhs)) == encoder.encode(normalized(rhs))
    }

    func replace(
        _ config: GuestConfig?, retry: Bool = false, on vm: VM, actor: MutationActor,
        context: IdempotencyRequestContext?, db: any Database, app: Application
    ) async throws -> ResourceMutation.Accepted? {
        try config?.validate()
        let requested = Self.normalized(config)
        let id = try vm.requireID()
        let accepted: ResourceMutation.Accepted? = try await db.transaction { db in
            try await IdempotencyService.reserve(context, actor: actor, on: db)
            guard try await vm.lockAndRefresh(on: db) else {
                throw Abort(.notFound, reason: "VM no longer exists")
            }
            guard vm.desiredStatus != .absent else {
                throw Abort(.conflict, reason: "Cannot configure a VM being deleted")
            }
            if requested != nil {
                guard vm.guestAgentEnabled, vm.hypervisorType == .qemu else {
                    throw Abort(
                        .conflict, reason: "Guest configuration requires a QEMU VM with the guest agent enabled")
                }
            }
            if retry && vm.failedGeneration != vm.generation {
                throw Abort(.conflict, reason: "Only a failed generation can be explicitly retried")
            }
            let unchanged = try Self.equivalent(vm.guestConfig, requested)
            guard retry || !unchanged else {
                try await IdempotencyService.completeSynchronousResponse(
                    context, actor: actor, resourceKind: .virtualMachine, resourceID: id,
                    responseStatus: .ok, on: db)
                return nil
            }
            let previousGeneration = vm.generation
            var scope = try await ResourceEvent.scope(of: .virtualMachine, id: id, on: db)
            vm.guestConfig = requested
            vm.guestConfigRealizedGeneration = nil
            guard
                case .applied = try await vm.advanceDesiredStateGeneration(
                    expectedGeneration: previousGeneration, on: db)
            else {
                throw Abort(.conflict, reason: "VM changed while applying guest configuration")
            }
            // A stopped/paused VM deliberately performs no guest work. Keep
            // any existing host transition budget, but do not invent a guest
            // deadline while realization is deferred until a later boot.
            if requested == nil || vm.desiredStatus == .running {
                vm.extendConvergenceDeadline(
                    by: OperationResourceKind.virtualMachine.completionBudgetSeconds(for: .guestConfig),
                    from: try await ClusterClock.read(on: db))
            }
            try await vm.save(on: db)
            scope.generation = vm.generation
            let event = try await ResourceEvent.record(
                .guestConfig, resourceKind: .virtualMachine, resourceID: id,
                actor: actor, scope: scope, on: db)
            let accepted = ResourceMutation.Accepted(
                mutationID: try event.requireID(), targetGeneration: vm.generation)
            try await IdempotencyService.complete(
                context, actor: actor, resourceKind: .virtualMachine, resourceID: id,
                accepted: accepted, on: db)
            return accepted
        }
        if let accepted {
            ResourceMutation(agentDispatch: dispatch, logger: logger).dispatch(
                .guestConfig, resourceType: VM.self, resourceID: id,
                targetGeneration: accepted.targetGeneration,
                agentIDs: vm.hypervisorId.map { [$0] } ?? [], strategy: .stateSync, app: app)
        }
        return accepted
    }
}
