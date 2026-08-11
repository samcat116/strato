import Fluent
import SQLKit
import Vapor

struct AddLoadBalancerCountToResourceQuota: AsyncMigration {
    func prepare(on database: Database) async throws {
        guard let sql = database as? any SQLDatabase else {
            throw Abort(.internalServerError, reason: "Load-balancer quota migration requires SQL")
        }
        try await sql.raw("ALTER TABLE resource_quotas ADD COLUMN max_load_balancers integer").run()
        try await sql.raw("UPDATE resource_quotas SET max_load_balancers = max_vms").run()
        try await sql.raw("ALTER TABLE resource_quotas ALTER COLUMN max_load_balancers SET NOT NULL").run()
        try await sql.raw(
            "ALTER TABLE resource_quotas ADD COLUMN load_balancer_count integer NOT NULL DEFAULT 0"
        ).run()

        for quota in try await ResourceQuota.query(on: database).all() {
            try await QuotaEnforcementService.resyncReservations(quota, on: database)
            try await quota.save(on: database)
        }
    }

    func revert(on database: Database) async throws {
        try await database.schema(ResourceQuota.schema)
            .deleteField("load_balancer_count")
            .deleteField("max_load_balancers")
            .update()
    }
}
