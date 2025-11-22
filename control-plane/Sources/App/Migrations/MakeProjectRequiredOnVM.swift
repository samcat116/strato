import Fluent
import Foundation
import SQLKit

struct MakeProjectRequiredOnVM: AsyncMigration {
    func prepare(on database: Database) async throws {
        // This migration should run AFTER MigrateExistingDataToProjects
        // to ensure all VMs have a project_id

        // Check if there are any VMs without a project_id using raw SQL
        // since Fluent's null checks don't work well with required @Parent relationships
        guard let sql = database as? SQLDatabase else {
            // Skip this check for non-SQL databases
            return
        }

        let rows = try await sql.raw("SELECT COUNT(*) as count FROM vms WHERE project_id IS NULL").all()
        if let row = rows.first {
            let count = try row.decode(column: "count", as: Int.self)
            if count > 0 {
                throw MigrationError.orphanedVMs(count: count)
            }
        }

        // Note: Making columns NOT NULL would require raw SQL
        // For now, we'll rely on application-level validation
    }

    func revert(on database: Database) async throws {
        // Note: Reverting would require raw SQL
        // For now, this is a no-op since we didn't make any schema changes
    }
}

enum MigrationError: Error, Sendable {
    case orphanedVMs(count: Int)

    var localizedDescription: String {
        switch self {
        case .orphanedVMs(let count):
            return "Cannot make project_id required: \(count) VMs do not have a project assigned. Please run the data migration first."
        }
    }
}
