import Fluent
import StratoShared
import Vapor

extension WorkloadResourceClassPolicy: Content {}
extension WorkloadResourceClassSnapshot: Content {}
extension WorkloadResourceClassReference: Content {}

/// Catalog edits never touch admitted workload rows or generations.
enum WorkloadResourceClassService {
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
