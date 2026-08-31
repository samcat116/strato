import Fluent
import SQLKit
import StratoShared
import Vapor

/// Allocates each network's resolver index — the one number both of its
/// link-local resolver addresses derive from (STR-40).
///
/// Separate from `IPAMService` because it allocates from a different kind of
/// space for a different reason. IPAM hands out addresses *inside a tenant
/// subnet*, so its pool is per network and its used-set is the NIC rows on that
/// network. This hands out one index from a single **fleet-wide** link-local
/// space, so its pool is the whole deployment and its used-set is the other
/// networks. Sharing a service would have meant sharing neither the lock key nor
/// the query.
///
/// ## Why fleet-wide rather than per host
///
/// The addresses live in the *host* namespace, so on a hypervisor running NICs
/// on two networks both resolvers bind in the same namespace and must differ.
/// Scoping the space per host would make an index depend on where a VM is
/// placed, which is not knowable when the network is created and would change
/// under migration; scoping it fleet-wide costs nothing but the 65k ceiling.
enum ResolverAddressAllocator {

    /// Every network shares one space, so one lock serializes every allocation.
    ///
    /// Coarser than IPAM's per-network key by necessity rather than oversight:
    /// the thing being kept unique is global. Held only across the scan and the
    /// write, and resolver allocation happens on network create or on flipping
    /// the flag — not on any hot path.
    /// Allocates the lowest free index, or returns the one this network already
    /// holds.
    ///
    /// Idempotent so a retried transaction, or an update that turns the resolver
    /// on for a network that had it before, does not consume a second index or
    /// move a live one — moving it would change what guests were told over DHCP
    /// and strand every lease until it renewed.
    static func ensureIndex(for network: LogicalNetwork, on db: any Database) async throws -> Int {
        if let existing = network.resolverIndex {
            return existing
        }
        try await lock(on: db)

        // The used-set is small (one small integer per resolver-enabled network)
        // and read under the lock, so it is fetched whole rather than probed
        // index by index.
        //
        // One column, not the model: with the flag defaulting on this runs for
        // every network create, and hydrating every `LogicalNetwork` in the
        // fleet to read one `Int` off each is the kind of cost that is invisible
        // until the fleet is large. Fluent has no projection, so this drops to
        // SQLKit where one is available.
        let used: Set<Int>
        if let sql = db as? any SQLDatabase {
            let rows = try await sql.select()
                .column("resolver_index")
                .from("logical_networks")
                .where("resolver_index", .isNot, SQLLiteral.null)
                .all()
            used = Set(rows.compactMap { try? $0.decode(column: "resolver_index", as: Int.self) })
        } else {
            used = Set(
                try await LogicalNetwork.query(on: db)
                    .filter(\.$resolverIndex != nil)
                    .all()
                    .compactMap(\.resolverIndex))
        }

        guard let index = firstFree(after: used) else {
            throw Abort(
                .conflict,
                reason: "No link-local resolver address is free: all "
                    + "\(NetworkResolverEndpoint.lastIndex - NetworkResolverEndpoint.firstIndex + 1) "
                    + "addresses in \(NetworkResolverEndpoint.v4Space) are in use. Disable the "
                    + "resolver on networks that no longer need one to free them.")
        }
        network.resolverIndex = index
        return index
    }

    /// The lowest free index at or after the first usable one.
    ///
    /// **Sequential, not hashed from the network id.** ~65k usable addresses
    /// means a hash collides at a few hundred networks — inside what one
    /// deployment reaches — and a collision here is two networks whose guests
    /// are told to resolve at the same address on a host that terminates both.
    /// A linear scan over a set this small is not worth optimizing away.
    static func firstFree(after used: Set<Int>) -> Int? {
        var candidate = NetworkResolverEndpoint.firstIndex
        while candidate <= NetworkResolverEndpoint.lastIndex {
            // `isValidIndex` also skips the addresses the metadata service and
            // the pre-STR-40 resolver constant already own, both of which fall
            // inside this range.
            if NetworkResolverEndpoint.isValidIndex(candidate), !used.contains(candidate) {
                return candidate
            }
            candidate += 1
        }
        return nil
    }

    /// PostgreSQL-only and transaction-scoped, matching `IPAMService`.
    /// Unsupported database dialects fail rather than silently skipping the
    /// cross-replica uniqueness invariant.
    static func lock(on db: any Database) async throws {
        try await AdvisoryLock.acquireTransactionLock(
            .singleton(.resolverIndex), on: db)
    }
}
