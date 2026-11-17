import AppTestSupport
import Fluent
import SQLKit
import StratoShared
import Testing
import Vapor

@testable import App

@Suite("Generated enum persistence", .postgresFixture)
struct AgentProtocolEnumPersistenceTests {
    @Test("Auxiliary artifact paths retain their published enum spelling")
    func artifactPathUsesStringKind() {
        let path = SandboxSnapshot.artifactTransferPath(
            sandboxId: UUID(), snapshotId: UUID(), kind: .memory)
        #expect(path.hasSuffix("/artifacts/memory"))
    }

    private final class Row: Model, @unchecked Sendable {
        static let schema = "protocol_enum_fixture"
        @ID(key: .id) var id: UUID?
        @ProtocolEnum(key: "status") var status: VMStatus
        init() {}
        init(status: VMStatus) { self.status = status }
    }

    @Test("Generated enum tags preserve PostgreSQL strings and query semantics")
    func stringsRemainStable() async throws {
        let app = try await Application.makeForBareDatabaseTesting()
        do {
            let sql = try #require(app.db as? any SQLDatabase)
            try await sql.raw("CREATE TYPE protocol_vm_status AS ENUM ('Created', 'Running', 'Future')").run()
            try await sql.raw(
                "CREATE TABLE protocol_enum_fixture (id uuid PRIMARY KEY, status protocol_vm_status NOT NULL)"
            ).run()
            let row = Row(status: .created)
            try await row.save(on: app.db)
            let stored = try #require(try await sql.raw("SELECT status::text FROM protocol_enum_fixture").first())
            #expect(try stored.decode(column: "status", as: String.self) == "Created")
            let fetched = try #require(try await Row.query(on: app.db).filter(\.$status == .created).first())
            #expect(fetched.status == .created)
            try await Row.query(on: app.db).filter(\.$id == row.requireID()).set(\.$status, to: .running).update()
            let updated = try #require(try await Row.find(row.requireID(), on: app.db))
            #expect(updated.status == .running)
            let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(updated)) as? [String: Any]
            #expect(json?["status"] as? String == "Running")
            try await sql.raw("UPDATE protocol_enum_fixture SET status = 'Future'").run()
            await #expect(throws: (any Error).self) { try await Row.query(on: app.db).all() }
        } catch {
            try await app.shutdownForTesting()
            throw error
        }
        try await app.shutdownForTesting()
    }
}
