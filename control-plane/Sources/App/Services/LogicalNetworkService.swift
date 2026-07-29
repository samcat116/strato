import Fluent
import Foundation
import SQLKit
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
        requestedID: UUID?, requestedName: String?, projectID: UUID, on db: Database
    ) async throws -> LogicalNetwork {
        if requestedID != nil && requestedName != nil {
            throw Abort(.badRequest, reason: "Specify either 'networkId' or 'networkName', not both")
        }

        let query = LogicalNetwork.query(on: db).filter(\.$project.$id == projectID)
        if let requestedID {
            guard let network = try await query.filter(\.$id == requestedID).first() else {
                throw Abort(.notFound, reason: "Network \(requestedID) not found in this project")
            }
            return network
        }
        if let requestedName {
            guard let network = try await query.filter(\.$name == requestedName).first() else {
                throw Abort(.notFound, reason: "No network named '\(requestedName)' in this project")
            }
            return network
        }

        throw Abort(
            .badRequest,
            reason: "A network is required: pass 'networkId' or 'networkName'. "
                + "Create a network for this project first if it has none.")
    }

    // MARK: - Same-name safety on a mixed-version fleet (issue #765)

    /// The networks an agent at `siteID` could be asked to realize: those
    /// pinned to its own site, plus every unpinned one.
    ///
    /// A site pin confines a network's VMs to that site's agents, so an agent
    /// elsewhere never sees it. Unpinned networks have no such confinement and
    /// can land on any host — including, for a site's topology authority, ones
    /// no VM of its own uses.
    static func realizableNetworks(siteID: UUID?, on db: Database) -> QueryBuilder<LogicalNetwork> {
        let query = LogicalNetwork.query(on: db)
        guard let siteID else { return query.filter(\.$site.$id == nil) }
        return query.group(.or) { group in
            group.filter(\.$site.$id == nil)
            group.filter(\.$site.$id == siteID)
        }
    }

    /// Network names owned by more than one project among those an agent at
    /// `siteID` could realize — the configuration a pre-v21 agent cannot keep
    /// apart, because it keys its OVN `DHCP_Options` rows on the name.
    static func namesSharedAcrossProjects(siteID: UUID?, on db: Database) async throws -> Set<String> {
        let networks = try await realizableNetworks(siteID: siteID, on: db).all()
        var projectsByName: [String: Set<UUID>] = [:]
        for network in networks {
            projectsByName[network.name, default: []].insert(network.$project.id)
        }
        return Set(projectsByName.filter { $0.value.count > 1 }.keys)
    }

    /// Serializes concurrent creates/renames competing for the same network
    /// name, so two cross-project creates cannot both observe "no collision"
    /// and commit one. Held to the end of the enclosing transaction, like
    /// `IPAMService`'s allocation lock; a no-op off Postgres.
    static func lockName(_ name: String, on db: Database) async throws {
        guard let sql = db as? SQLDatabase, sql.dialect.name == "postgresql" else { return }
        try await sql.raw("SELECT pg_advisory_xact_lock(hashtext(\(bind: "netname:\(name)")))").run()
    }
}
