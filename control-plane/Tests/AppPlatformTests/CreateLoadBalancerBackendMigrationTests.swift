import AppTestSupport
import FluentPostgresDriver
import Foundation
import SQLKit
import Testing
import Vapor

@testable import App

@Suite("Create load balancer backend migration", .serialized)
struct CreateLoadBalancerBackendMigrationTests {
    @Test("Creates both composite unique constraints with distinct short names")
    func createsCompositeUniqueConstraints() async throws {
        var environment = Environment.testing
        environment.arguments = ["vapor"]
        let app = try await Application.make(
            environment,
            .shared(PostgresTestDatabases.appEventLoopGroup)
        )
        let databaseName = Environment.get("DATABASE_NAME") ?? "strato_test"
        app.databases.use(
            .postgres(configuration: PostgresTestDatabases.configuration(database: databaseName)),
            as: .psql
        )

        let schemaName = "lb_backend_migration_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        do {
            let sql = try #require(app.db as? any SQLDatabase)
            try await sql.raw("CREATE SCHEMA \(ident: schemaName)").run()

            let constraints = try await app.db.withConnection { database in
                let connection = try #require(database as? any SQLDatabase)
                try await connection.raw("SET search_path TO \(ident: schemaName)").run()
                try await connection.raw("CREATE TABLE load_balancers (id uuid PRIMARY KEY)").run()
                try await connection.raw("CREATE TABLE vm_network_interfaces (id uuid PRIMARY KEY)").run()

                try await CreateLoadBalancerBackend().prepare(on: database)

                return try await connection.raw(
                    """
                    SELECT constraint_record.conname AS name,
                           pg_get_constraintdef(constraint_record.oid, true) AS definition
                    FROM pg_constraint AS constraint_record
                    JOIN pg_class AS relation ON relation.oid = constraint_record.conrelid
                    JOIN pg_namespace AS namespace ON namespace.oid = relation.relnamespace
                    WHERE namespace.nspname = \(bind: schemaName)
                      AND relation.relname = 'load_balancer_backends'
                      AND constraint_record.contype = 'u'
                    ORDER BY constraint_record.conname
                    """
                ).all(decoding: UniqueConstraint.self)
            }

            #expect(
                constraints == [
                    UniqueConstraint(
                        name: "uq_lb_backend_address",
                        definition: "UNIQUE (load_balancer_id, address)"
                    ),
                    UniqueConstraint(
                        name: "uq_lb_backend_interface",
                        definition: "UNIQUE (load_balancer_id, interface_id)"
                    ),
                ]
            )

            try await sql.raw("DROP SCHEMA \(ident: schemaName) CASCADE").run()
        } catch {
            if let sql = app.db as? any SQLDatabase {
                try? await sql.raw("DROP SCHEMA IF EXISTS \(ident: schemaName) CASCADE").run()
            }
            try? await app.asyncShutdown()
            throw error
        }
        try await app.asyncShutdown()
    }
}

private struct UniqueConstraint: Decodable, Equatable {
    let name: String
    let definition: String
}
