import Fluent

/// One-time sweep of the materialized `path` values a folder move left behind
/// (STR-114 / issue #871).
///
/// `POST /api/organizations/{orgID}/ous/{ouID}/move` rewrote the moved folder
/// and its descendant *folders*, but never the projects hanging off them, so
/// every project under a folder that has ever moved still names an ancestor it
/// no longer has. The move now rewrites both; nothing existed to notice the
/// drift already stored, and paths are derived data, so this recomputes them
/// from the relational parent chain that is the source of truth.
///
/// Authorization never read these paths (it walks the relational links), so this
/// corrects breadcrumbs, search results and the `path` on project responses —
/// not who can reach what. Rows already consistent are left untouched, which
/// makes the sweep a no-op on an installation that never moved a folder.
struct RebuildDriftedHierarchyPaths: AsyncMigration {
    func prepare(on database: Database) async throws {
        let report = try await HierarchyMaintenanceService.performHierarchyRepair(
            repairRequest: HierarchyRepairRequest(
                repairAll: true,
                repairOptions: .init(rebuildPaths: true)
            ),
            on: database
        )

        guard !report.repairedIssues.isEmpty || !report.remainingIssues.isEmpty else { return }
        database.logger.info(
            "Rebuilt drifted hierarchy paths",
            metadata: [
                "repaired": .stringConvertible(report.repairedIssues.count),
                // Cycles and severed parent chains are reported, not repaired:
                // there is no derivable path to write. `GET /api/hierarchy/validate`
                // describes each one.
                "remaining": .stringConvertible(report.remainingIssues.count),
            ])
    }

    /// Nothing to restore: the previous values were wrong, and the correct ones
    /// are what every other read of the hierarchy already assumes.
    func revert(on database: Database) async throws {}
}
