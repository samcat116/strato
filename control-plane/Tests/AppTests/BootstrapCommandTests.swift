import Fluent
import Testing
import Vapor

@testable import App

/// Captures console output so the printed API key can be recovered and checked.
private final class CaptureConsole: Console, @unchecked Sendable {
    var lines: [String] = []
    var userInfo: [AnySendableHashable: any Sendable] = [:]
    var size: (width: Int, height: Int) { (80, 25) }
    func input(isSecure: Bool) -> String { "" }
    func output(_ text: ConsoleText, newLine: Bool) { lines.append(text.description) }
    func clear(_ type: ConsoleClear) {}
    func report(error: String, newLine: Bool) { lines.append(error) }
}

@Suite("Bootstrap Command Tests")
struct BootstrapCommandTests {
    @discardableResult
    private func runBootstrap(_ app: Application, arguments: [String] = []) async throws -> CaptureConsole {
        var input = CommandInput(arguments: ["bootstrap"] + arguments)
        let signature = try BootstrapCommand.Signature(from: &input)
        let console = CaptureConsole()
        var context = CommandContext(console: console, input: input)
        context.application = app
        try await BootstrapCommand().run(using: context, signature: signature)
        return console
    }

    @Test("Seeds admin user, org, project, IAM bindings, and a working API key")
    func seedsEverything() async throws {
        try await withTestApp { app in
            let console = try await runBootstrap(
                app,
                arguments: [
                    "--quiet", "--username", "ci", "--email", "ci@example.com",
                    "--org-name", "CI Org", "--project-name", "E2E",
                ])

            let user = try #require(try await User.query(on: app.db).first())
            #expect(user.username == "ci")
            #expect(user.email == "ci@example.com")
            #expect(user.isSystemAdmin)

            let org = try #require(try await Organization.query(on: app.db).first())
            #expect(org.name == "CI Org")
            #expect(user.currentOrganizationId == org.id)

            let membership = try #require(try await UserOrganization.query(on: app.db).first())
            #expect(membership.role == "admin")

            let project = try #require(try await Project.query(on: app.db).first())
            #expect(project.name == "E2E")
            let expectedPath = "/\(org.id!.uuidString)/\(project.id!.uuidString)"
            #expect(project.path == expectedPath)

            // IAM dual-write: explicit admin bindings on both the org and the project.
            let orgBindings = try await RoleBindingService.activeBindings(
                nodeType: .organization, nodeID: org.id!, on: app.db)
            #expect(orgBindings.map(\.role) == [IAMRole.admin.seededID.uuidString])
            let projectBindings = try await RoleBindingService.activeBindings(
                nodeType: .project, nodeID: project.id!, on: app.db)
            #expect(projectBindings.map(\.role) == [IAMRole.admin.seededID.uuidString])

            // --quiet prints exactly the key, and its hash matches the stored row.
            let printedKey = try #require(console.lines.first).trimmingCharacters(in: .whitespacesAndNewlines)
            #expect(console.lines.count == 1)
            #expect(printedKey.hasPrefix("sk_"))
            let apiKey = try #require(try await APIKey.query(on: app.db).first())
            #expect(apiKey.keyHash == APIKey.hashAPIKey(printedKey))
            #expect(apiKey.scopes == [APIKeyScope.admin.rawValue])
            #expect(apiKey.isActive)
            #expect(apiKey.expiresAt == nil)
        }
    }

    @Test("Refuses when any user already exists")
    func refusesWhenUsersExist() async throws {
        try await withTestApp { app in
            let existing = User(username: "someone", email: "someone@example.com", displayName: "Someone")
            try await existing.save(on: app.db)

            await #expect(throws: BootstrapCommand.RefusedError.self) {
                try await runBootstrap(app, arguments: ["--quiet"])
            }
            let userCount = try await User.query(on: app.db).count()
            #expect(userCount == 1)
            let orgCount = try await Organization.query(on: app.db).count()
            #expect(orgCount == 0)
        }
    }

    @Test("A second run refuses instead of duplicating seed data")
    func secondRunRefuses() async throws {
        try await withTestApp { app in
            try await runBootstrap(app, arguments: ["--quiet"])
            await #expect(throws: BootstrapCommand.RefusedError.self) {
                try await runBootstrap(app, arguments: ["--quiet"])
            }
            let keyCount = try await APIKey.query(on: app.db).count()
            #expect(keyCount == 1)
        }
    }
}
