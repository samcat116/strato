import Fluent

/// Initializes network quota counters from the canonical aggregate (STR-236).
///
/// The columns predate network admission and were never maintained, so every
/// existing row reads zero regardless of how many project-wide networks its
/// scope contains. Recomputing every counter, rather than adding only networks
/// to a potentially stale cache, matches `AddVolumeQuotaAccounting` and leaves
/// the row internally consistent after the upgrade.
struct BackfillNetworkQuotaAccounting: AsyncMigration {
    func backfillQuotaCounters(on database: Database) async throws {
        for quota in try await LegacyResourceQuotaStore.all(on: database) {
            let synchronized = try await QuotaEnforcementService.resyncReservations(quota, on: database)
            try await synchronized.save(on: database)
        }
    }

    func prepare(on database: Database) async throws {
        try await backfillQuotaCounters(on: database)
    }

    /// A cache refresh has no destructive schema change to reverse. A later
    /// admission or quota update will refresh the same counters again.
    func revert(on database: Database) async throws {}
}
