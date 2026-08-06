import Fluent
import Foundation
import Testing
import Vapor

import AppTestSupport
@testable import App

/// The break-glass path back into a deployment with no reachable administrator
/// (STR-178). These pin the two ways it can go wrong: promoting nobody, and
/// minting an invite that takes away the sign-in it was meant to restore.
@Suite("Grant Platform Admin Command Tests")
struct GrantPlatformAdminCommandTests {
    @discardableResult
    private func run(_ app: Application, arguments: [String]) async throws -> CaptureConsole {
        var input = CommandInput(arguments: ["grant-platform-admin"] + arguments)
        let signature = try GrantPlatformAdminCommand.Signature(from: &input)
        let console = CaptureConsole()
        var context = CommandContext(console: console, input: input)
        context.application = app
        try await GrantPlatformAdminCommand().run(using: context, signature: signature)
        return console
    }

    private func makeUser(_ app: Application, username: String = "morpheus") async throws -> User {
        let user = User(
            username: username, email: "\(username)@example.com", displayName: username)
        try await user.save(on: app.db)
        return user
    }

    @Test("Promotes an existing user by email")
    func promotesByEmail() async throws {
        try await withTestApp { app in
            let user = try await makeUser(app)
            #expect(!user.isSystemAdmin)

            try await run(app, arguments: ["--email", "morpheus@example.com"])

            let promoted = try #require(try await User.find(user.id, on: app.db))
            #expect(promoted.isSystemAdmin)
            // No invite unless asked for: a promotion is not an enrollment.
            let claimCount = try await AccountClaimToken.query(on: app.db).count()
            #expect(claimCount == 0)
        }
    }

    @Test("Promotes an existing user by username")
    func promotesByUsername() async throws {
        try await withTestApp { app in
            let user = try await makeUser(app)
            try await run(app, arguments: ["--username", "morpheus"])
            let promoted = try #require(try await User.find(user.id, on: app.db))
            #expect(promoted.isSystemAdmin)
        }
    }

    /// The `bootstrap`-without-`--admin-email` recovery: the seeded account has
    /// no passkey, so promotion alone leaves it unreachable.
    @Test("--claim mints a live invite for a credential-less account")
    func claimMintsInviteForCredentiallessAccount() async throws {
        try await withTestApp { app in
            let user = try await makeUser(app)

            let console = try await run(app, arguments: ["--quiet", "--email", "morpheus@example.com"])

            #expect(console.lines.count == 1)
            let claimURL = try #require(console.lines.first).trimmingCharacters(in: .whitespacesAndNewlines)
            let rawToken = try #require(claimURL.split(separator: "=").last.map(String.init))

            let claim = try #require(try await AccountClaimToken.query(on: app.db).first())
            #expect(claim.tokenHash == AccountClaimToken.hashToken(rawToken))
            #expect(claim.$user.id == user.id)
            #expect(claim.isValid)
            #expect(try #require(try await User.find(user.id, on: app.db)).isSystemAdmin)
        }
    }

    /// Two live links to one account is the failure mode a lost-link recovery
    /// is trying to end, not create.
    @Test("--claim supersedes an older unclaimed invite")
    func claimSupersedesOlderInvite() async throws {
        try await withTestApp { app in
            let user = try await makeUser(app)
            let stale = AccountClaimToken(
                userID: try user.requireID(),
                tokenHash: AccountClaimToken.hashToken("claim_stale"),
                tokenPrefix: "claim_stale",
                expiresAt: Date().addingTimeInterval(3600),
                createdByID: nil
            )
            try await stale.save(on: app.db)

            try await run(app, arguments: ["--quiet", "--email", "morpheus@example.com"])

            let live = try await AccountClaimToken.query(on: app.db).all()
            #expect(live.count == 1)
            #expect(live.first?.tokenHash != AccountClaimToken.hashToken("claim_stale"))
        }
    }

    /// An unclaimed invite blocks `/auth/register/begin`, so minting one for an
    /// account that can already sign in would revoke its passkey path.
    @Test("--claim refuses an account that already has a passkey")
    func claimRefusesEnrolledAccount() async throws {
        try await withTestApp { app in
            let user = try await makeUser(app)
            let credential = UserCredential(
                userID: try user.requireID(),
                credentialID: Data("credential".utf8),
                publicKey: Data("key".utf8)
            )
            try await credential.save(on: app.db)

            await #expect(throws: GrantPlatformAdminCommand.AlreadyEnrolledError.self) {
                try await run(app, arguments: ["--claim", "--email", "morpheus@example.com"])
            }
            // Refusal is total: no promotion either, so the operator retries
            // deliberately rather than discovering a half-applied change.
            #expect(!(try #require(try await User.find(user.id, on: app.db))).isSystemAdmin)
            #expect(try await AccountClaimToken.query(on: app.db).count() == 0)
        }
    }

    @Test("Refuses when no user matches")
    func refusesUnknownUser() async throws {
        try await withTestApp { app in
            await #expect(throws: GrantPlatformAdminCommand.NotFoundError.self) {
                try await run(app, arguments: ["--email", "nobody@example.com"])
            }
        }
    }

    @Test("Refuses without exactly one selector")
    func refusesAmbiguousSelector() async throws {
        try await withTestApp { app in
            try await makeUser(app)
            await #expect(throws: GrantPlatformAdminCommand.SelectorError.self) {
                try await run(app, arguments: [])
            }
            await #expect(throws: GrantPlatformAdminCommand.SelectorError.self) {
                try await run(app, arguments: ["--email", "morpheus@example.com", "--username", "morpheus"])
            }
        }
    }

    @Test("Promoting an existing admin is a no-op that says so")
    func promotingAdminIsIdempotent() async throws {
        try await withTestApp { app in
            let user = User(
                username: "oracle", email: "oracle@example.com", displayName: "Oracle", isSystemAdmin: true)
            try await user.save(on: app.db)

            let console = try await run(app, arguments: ["--email", "oracle@example.com"])

            #expect(try #require(try await User.find(user.id, on: app.db)).isSystemAdmin)
            #expect(console.lines.contains { $0.contains("was already a system administrator") })
        }
    }
}
