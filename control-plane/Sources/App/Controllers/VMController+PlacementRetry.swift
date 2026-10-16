import Fluent
import Vapor

extension VMController {
    /// Retry only a failed create whose placement never committed. The existing
    /// NICs, IP allocations, boot volume and identity remain authoritative.
    func retryPlacement(req: Request) async throws -> Response {
        let user = try req.requireActingUser("Retrying VM placement")
        let vmID = try req.requireUUIDParameter("vmID", reason: "Invalid VM ID")
        let vm = try await req.authorizedVM(vmID, action: "vm:start")
        let failedGenerationAtRead = vm.failedGeneration
        let app = req.application
        let accepted = try await req.resourceMutation.accept(
            .create, on: vm, actor: .user(try user.requireID()),
            dispatch: .placement { db in
                let placementDeadline = vm.convergenceDeadline
                do {
                    let image = try await vm.$sourceImage.get(on: db)
                    try await app.workloadPlacement.createVM(
                        vm: vm, db: db, image: image, attemptDeadline: placementDeadline)
                } catch {
                    guard let placementDeadline else { throw error }
                    throw ResourceMutation.PlacementFailure(
                        deadline: placementDeadline, reason: error.localizedDescription)
                }
            }, on: req.db, app: app
        ) { db in
            // accept holds and refreshes the VM row. This also rejects a
            // concurrent retry before it records another event or dispatches.
            // Metadata edits can advance generation before this lock without
            // replacing the failed attempt. Fence on that failure's generation
            // so a fast, newly failed retry still invalidates stale requests.
            // recordFailure clears the deadline; accept stamps a new one before
            // releasing this row lock. Use that to distinguish a failed VM from
            // an outstanding retry without erasing its historical failure.
            guard vm.status == .error, let failedGeneration = vm.failedGeneration,
                failedGeneration == failedGenerationAtRead,
                failedGeneration <= vm.generation, vm.convergenceDeadline == nil,
                vm.hypervisorId == nil, !vm.isTerminating,
                vm.desiredStatus == .shutdown || vm.desiredStatus == .running
            else {
                throw Abort(.conflict, reason: "Only a failed, unplaced VM can retry placement")
            }
            let boots = try await Volume.query(on: db)
                .filter(\.$vm.$id == vmID).filter(\.$volumeType == .boot).all()
            guard boots.count == 1, let boot = boots.first,
                try await boot.lockAndRefresh(on: db),
                boot.$vm.id == vmID, boot.volumeType == .boot,
                boot.desiredStatus == .present, boot.attachedAgentId == nil,
                boot.reconcilerAgentId == nil,
                try await VolumeReplica.query(on: db).filter(\.$volume.$id == boot.requireID()).count() == 0
            else {
                throw Abort(.conflict, reason: "Placement retry requires one existing, unplaced boot volume")
            }
            // The boot disk has its own generation and provisioning budget.
            // Reusing the row must not reuse an expired deadline or the exact
            // generation a previous terminal failure names. This transaction's
            // VM create-attempt event covers the boot retry, as at initial create.
            guard
                case .applied = try await boot.advanceDesiredStateGeneration(
                    expectedGeneration: boot.generation, on: db)
            else { throw Abort(.conflict, reason: "Boot volume changed while retrying placement") }
            boot.extendConvergenceDeadline(
                by: OperationResourceKind.volume.completionBudgetSeconds(for: .create),
                from: try await ClusterClock.read(on: db))
            try await boot.save(on: db)
        }
        return try await Self.acceptedResponse(for: vm, accepted, on: req)
    }
}
