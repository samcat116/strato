import Fluent
import Foundation
import SQLKit
import StratoShared
import Vapor

/// Gives every already-existing resolver-enabled network the address it was
/// promised (STR-201).
///
/// `AddResolverEnabledToLogicalNetwork` defaults `resolver_enabled` to true and
/// says existing networks "are carried in on that default".
/// `AddResolverIndexToLogicalNetwork` then, correctly for its own purposes, left
/// `resolver_index` null — an index is allocated the first time a network's
/// resolver is enabled. Between them nothing allocates an index for a network
/// that was *already* enabled when the column arrived, and the only writers are
/// network create and `NetworkController.updateNetwork`. So every network that
/// predates STR-40 reports `resolverEnabled: true`, has no address, and
/// `resolverAddressesIfEnabled` answers nil for it — its guests keep being told
/// `dnsServers` verbatim, forever, and an attached DNS zone is never reached.
///
/// That is the same defect STR-201 is filed for, with no operator action behind
/// it, so it is fixed here rather than reported: the promise the default made is
/// kept by handing out the indexes it implied.
///
/// Raw SQL rather than the Fluent model, matching `SeedDefaultNetworkDNS` — a
/// migration that hydrates a model is pinned to whatever columns that model has
/// *today*, not to the schema as of this migration. The index *choice* still
/// goes through `ResolverAddressAllocator.firstFree`, so the reserved addresses
/// and the usable range have exactly one definition.
///
/// No generation bump: `generation` tracks L3 realization, and the resolver's
/// port and DHCP row converge level-triggered on every network reconcile.
struct BackfillResolverIndexes: AsyncMigration {
    func prepare(on database: Database) async throws {
        guard let sql = database as? any SQLDatabase else {
            throw Abort(.internalServerError, reason: "BackfillResolverIndexes requires an SQL database")
        }

        // The whole used-set, including rows whose resolver is off: an index is
        // kept when the flag is turned off, because some agent may still have
        // the old address configured, and reusing it would put two networks on
        // one address.
        let usedRows = try await sql.select()
            .column("resolver_index")
            .from("logical_networks")
            .where("resolver_index", .isNot, SQLLiteral.null)
            .all(decoding: IndexRow.self)
        var taken = Set(usedRows.compactMap(\.resolverIndex))

        let pending = try await sql.select()
            .column("id")
            .from("logical_networks")
            .where("resolver_enabled", .equal, SQLBind(true))
            .where("resolver_index", .is, SQLLiteral.null)
            .orderBy("id")
            .all(decoding: IDRow.self)
        guard !pending.isEmpty else { return }

        var allocated = 0
        for row in pending {
            guard let index = ResolverAddressAllocator.firstFree(after: taken) else {
                // Stop rather than throw. Exhaustion here needs ~65k networks,
                // and a migration that refuses is a control plane that will not
                // start — an operator cannot free addresses from a process that
                // is down. The networks left without one report it through
                // `ResolverCapability.zoneResolutionWarning`, which is the same
                // state they were already in.
                database.logger.warning(
                    "Resolver address space exhausted during backfill; some networks keep none",
                    metadata: [
                        "allocated": .string(String(allocated)),
                        "remaining": .string(String(pending.count - allocated)),
                        "remedy": .string(
                            "disable the resolver on networks that no longer need one, "
                                + "then update the networks still without an address"),
                    ])
                break
            }
            taken.insert(index)
            try await sql.update("logical_networks")
                .set("resolver_index", to: SQLBind(index))
                .where("id", .equal, SQLBind(row.id))
                .run()
            allocated += 1
        }

        database.logger.info(
            "Backfilled link-local resolver addresses",
            metadata: ["networks": .string(String(allocated))])
    }

    /// The column belongs to `AddResolverIndexToLogicalNetwork`; this migration
    /// only wrote values into it. Clearing them on revert would strand every
    /// DHCP lease already carrying one, which is the one thing the allocator is
    /// built never to do.
    func revert(on database: Database) async throws {}

    private struct IndexRow: Decodable {
        let resolverIndex: Int?

        enum CodingKeys: String, CodingKey {
            case resolverIndex = "resolver_index"
        }
    }

    private struct IDRow: Decodable {
        let id: UUID
    }
}
