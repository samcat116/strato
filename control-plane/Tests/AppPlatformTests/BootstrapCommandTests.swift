import Fluent
import Testing
import Vapor

import AppTestSupport
@testable import App

/// Captures console output so printed secrets (the API key, a claim URL) can be
/// recovered and checked. Shared with `GrantPlatformAdminCommandTests`.
final class CaptureConsole: Console, @unchecked Sendable {
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

    @Test("The headless shape mints no claim invite")
    func headlessSeedIsNotClaimable() async throws {
        try await withTestApp { app in
            try await runBootstrap(app, arguments: ["--quiet"])
            let claimCount = try await AccountClaimToken.query(on: app.db).count()
            #expect(claimCount == 0)
        }
    }

    /// The STR-178 shape: the seeded admin is a person who can actually sign in.
    @Test("--admin-email seeds a claimable human and prints the claim link")
    func adminEmailSeedsClaimableHuman() async throws {
        try await withTestApp { app in
            let console = try await runBootstrap(
                app, arguments: ["--quiet", "--admin-email", "ada.lovelace@example.com"])

            let user = try #require(try await User.query(on: app.db).first())
            #expect(user.email == "ada.lovelace@example.com")
            // Derived from the local part rather than left as `bootstrap`.
            #expect(user.username == "ada.lovelace")
            #expect(user.isSystemAdmin)

            // --quiet stays machine-readable: key first, claim URL second.
            #expect(console.lines.count == 2)
            let printedKey = try #require(console.lines.first).trimmingCharacters(in: .whitespacesAndNewlines)
            #expect(printedKey.hasPrefix("sk_"))
            let claimURL = try #require(console.lines.last).trimmingCharacters(in: .whitespacesAndNewlines)

            // The printed link carries the one raw token the stored hash matches,
            // and the invite is live — this is the whole fix, so pin it end to end.
            let rawToken = try #require(claimURL.split(separator: "=").last.map(String.init))
            let claim = try #require(try await AccountClaimToken.query(on: app.db).first())
            #expect(claim.tokenHash == AccountClaimToken.hashToken(rawToken))
            #expect(claim.$user.id == user.id)
            #expect(claim.isValid)
        }
    }

    /// Explicit names are passed through unchanged — including ones the API's
    /// own validator would reject, which `seedsEverything`'s two-character `ci`
    /// already relies on. Only derived names are validated.
    @Test("--username wins over the address-derived name")
    func explicitUsernameOverridesDerivation() async throws {
        try await withTestApp { app in
            try await runBootstrap(
                app, arguments: ["--quiet", "--admin-email", "ada@example.com", "--username", "ci"])
            let user = try #require(try await User.query(on: app.db).first())
            #expect(user.username == "ci")
        }
    }

    @Test("--admin-email and --email are mutually exclusive")
    func conflictingEmailFlagsRefuse() async throws {
        try await withTestApp { app in
            await #expect(throws: BootstrapCommand.ConflictingEmailError.self) {
                try await runBootstrap(
                    app,
                    arguments: ["--quiet", "--admin-email", "ada@example.com", "--email", "ci@example.com"])
            }
            let userCount = try await User.query(on: app.db).count()
            #expect(userCount == 0)
        }
    }

    @Test("An address whose local part cannot make a username asks for --username")
    func underivableUsernameRefuses() async throws {
        try await withTestApp { app in
            await #expect(throws: BootstrapCommand.UnusableDerivedUsernameError.self) {
                try await runBootstrap(app, arguments: ["--quiet", "--admin-email", "a+b@example.com"])
            }
            let userCount = try await User.query(on: app.db).count()
            #expect(userCount == 0)
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
