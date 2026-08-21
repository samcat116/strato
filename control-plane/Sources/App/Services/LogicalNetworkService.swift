import ControlPlanePostgres
import Foundation
import StratoShared
import Vapor

/// Domain logic shared by the paths that attach a workload to a logical
/// network. VM and sandbox create resolve through here so neither can reach a
/// network outside the workload's own project (issue #765).
enum LogicalNetworkService {

    /// Resolves the network a new VM or sandbox should attach to, scoped to the
    /// workload's project.
    ///
    /// Call inside the create transaction: resolving there is what makes the
    /// answer durable, since the returned row is read under the same snapshot
    /// that allocates from it and the NIC's foreign key then pins it against a
    /// concurrent delete.
    ///
    /// There is no implicit fallback. Nothing provisions a network with a
    /// project, and no network is privileged, so "attach to whatever is lying
    /// around" has no honest answer — the caller must name one.
    ///
    /// A network belonging to another project is reported as *not found*, never
    /// as forbidden: names are per-project and ids are opaque, so confirming
    /// that an id or a name exists elsewhere would disclose another tenant's
    /// networks.
    static func resolveForWorkloadCreate(
        requestedID: UUID?, requestedName: String?, projectID: UUID, on db: PostgresStoreContext
    ) async throws -> LogicalNetwork {
        if requestedID != nil && requestedName != nil {
            throw Abort(.badRequest, reason: "Specify either 'networkId' or 'networkName', not both")
        }

        if let requestedID {
            guard let network = try await LegacyLogicalNetworkStore.networks(
                ids: [requestedID], projectID: projectID, on: db
            ).first else {
                throw Abort(.notFound, reason: "Network \(requestedID) not found in this project")
            }
            return network
        }
        if let requestedName {
            guard let network = try await LegacyLogicalNetworkStore.networks(
                projectID: projectID, name: requestedName, on: db
            ).first else {
                throw Abort(.notFound, reason: "No network named '\(requestedName)' in this project")
            }
            return network
        }

        throw Abort(
            .badRequest,
            reason: "A network is required: pass 'networkId' or 'networkName'. "
                + "Create a network for this project first if it has none.")
    }

}
