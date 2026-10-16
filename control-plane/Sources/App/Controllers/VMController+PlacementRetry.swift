import Fluent
import Vapor

extension VMController {
    /// Retry only a failed create whose placement never committed. The existing
    /// NICs, IP allocations, boot volume and identity remain authoritative.
    func retryPlacement(req: Request) async throws -> Response {
        let user = try req.requireActingUser("Retrying VM placement")
        let vmID = try req.requireUUIDParameter("vmID", reason: "Invalid VM ID")
        let vm = try await req.authorizedVM(vmID, action: "vm:start")
        let generationAtRead = vm.generation
        let app = req.application
        let accepted = try await req.resourceMutation.accept(
            .create, on: vm, actor: .user(try user.requireID()),
            dispatch: .placement { db in
                let image = try await vm.$sourceImage.get(on: db)
                try await app.workloadPlacement.createVM(
                    vm: vm, db: db, image: image, expectedGeneration: generationAtRead + 1)
            }, on: req.db, app: app
        ) { db in
            // accept holds and refreshes the VM row. This also rejects a
            // concurrent retry before it records another event or dispatches.
            // Metadata edits can advance generation after a terminal failure.
            // recordFailure clears the deadline; accept stamps a new one before
            // releasing this row lock. Use that to distinguish a failed VM from
            // an outstanding retry without erasing its historical failure.
            guard vm.generation == generationAtRead,
                vm.status == .error, let failedGeneration = vm.failedGeneration,
                failedGeneration <= generationAtRead, vm.convergenceDeadline == nil,
                vm.hypervisorId == nil, !vm.isTerminating,
                vm.desiredStatus == .shutdown || vm.desiredStatus == .running
            else {
                throw Abort(.conflict, reason: "Only a failed, unplaced VM can retry placement")
            }
            let boots = try await Volume.query(on: db)
                .filter(\.$vm.$id == vmID).filter(\.$volumeType == .boot).all()
            guard boots.count == 1, let boot = boots.first,
                boot.desiredStatus == .present, boot.attachedAgentId == nil,
                boot.reconcilerAgentId == nil,
                try await VolumeReplica.query(on: db).filter(\.$volume.$id == boot.requireID()).count() == 0
            else {
                throw Abort(.conflict, reason: "Placement retry requires one existing, unplaced boot volume")
            }
        }
        return try await Self.acceptedResponse(for: vm, accepted, on: req)
    }
}
