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

            let console = try await run(
                app, arguments: ["--claim", "--quiet", "--email", "morpheus@example.com"])

            #expect(console.lines.count == 1)
            let claimURL = try #require(console.lines.first).trimmingCharacters(in: .whitespacesAndNewlines)
            let rawToken = try #require(claimURL.split(separator: "=").last.map(String.init))

            let claim = try #require(try await AccountClaimToken.query(on: app.db).first())
            #expect(claim.tokenHash == AccountClaimToken.hashToken(rawToken))
            #expect(claim.$user.id == user.id)
            #expect(claim.isValid)
            let promoted = try #require(try await User.find(user.id, on: app.db))
            #expect(promoted.isSystemAdmin)
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

            try await run(app, arguments: ["--claim", "--quiet", "--email", "morpheus@example.com"])

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
            let untouched = try #require(try await User.find(user.id, on: app.db))
            #expect(!untouched.isSystemAdmin)
            let claimCount = try await AccountClaimToken.query(on: app.db).count()
            #expect(claimCount == 0)
        }
    }

    /// `--quiet` is an output modifier, not a mode switch: a scripted plain
    /// promotion must work and must not mint anything.
    @Test("--quiet without --claim promotes silently and mints nothing")
    func quietWithoutClaimIsPurelyOutput() async throws {
        try await withTestApp { app in
            let user = try await makeUser(app)

            let console = try await run(app, arguments: ["--quiet", "--email", "morpheus@example.com"])

            #expect(console.lines.isEmpty)
            let promoted = try #require(try await User.find(user.id, on: app.db))
            #expect(promoted.isSystemAdmin)
            let claimCount = try await AccountClaimToken.query(on: app.db).count()
            #expect(claimCount == 0)
        }
    }

    /// The sharp edge of the old coupling: quiet promotion of an already-enrolled
    /// account used to hard-fail with no promotion at all.
    @Test("--quiet promotes an enrolled account instead of refusing")
    func quietPromotesEnrolledAccount() async throws {
        try await withTestApp { app in
            let user = try await makeUser(app)
            let credential = UserCredential(
                userID: try user.requireID(),
                credentialID: Data("credential".utf8),
                publicKey: Data("key".utf8)
            )
            try await credential.save(on: app.db)

            try await run(app, arguments: ["--quiet", "--email", "morpheus@example.com"])

            let promoted = try #require(try await User.find(user.id, on: app.db))
            #expect(promoted.isSystemAdmin)
        }
    }

    /// Every claim endpoint calls `rejectDisabledAccount`, so the link would be
    /// dead on arrival — better to say so now than mid-outage.
    @Test("--claim refuses a disabled account")
    func claimRefusesDisabledAccount() async throws {
        try await withTestApp { app in
            let user = try await makeUser(app)
            user.disabledAt = Date()
            try await user.save(on: app.db)

            await #expect(throws: GrantPlatformAdminCommand.DisabledAccountError.self) {
                try await run(app, arguments: ["--claim", "--email", "morpheus@example.com"])
            }
            let claimCount = try await AccountClaimToken.query(on: app.db).count()
            #expect(claimCount == 0)
        }
    }

    /// A local passkey invite is not how an OIDC or SCIM identity signs in.
    @Test("--claim refuses a non-local account")
    func claimRefusesNonLocalAccount() async throws {
        try await withTestApp { app in
            let user = try await makeUser(app)
            user.source = .oidc
            try await user.save(on: app.db)

            await #expect(throws: GrantPlatformAdminCommand.NonLocalAccountError.self) {
                try await run(app, arguments: ["--claim", "--email", "morpheus@example.com"])
            }
            // Promotion itself stays available for federated identities.
            try await run(app, arguments: ["--email", "morpheus@example.com"])
            let promoted = try #require(try await User.find(user.id, on: app.db))
            #expect(promoted.isSystemAdmin)
        }
    }

    @Test("Every run writes an audit event naming what it did")
    func writesAnAuditEvent() async throws {
        try await withTestApp { app in
            let user = try await makeUser(app)
            try await run(app, arguments: ["--claim", "--quiet", "--email", "morpheus@example.com"])

            let event = try #require(
                try await AuditEvent.query(on: app.db)
                    .filter(\.$eventType == "iam.platform_admin_granted")
                    .first())
            #expect(event.userID == user.id)
            #expect(event.resourceID == user.id?.uuidString)
            #expect(event.metadata?["claim_minted"] == "true")
            #expect(event.metadata?["already_admin"] == "false")
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

            let promoted = try #require(try await User.find(user.id, on: app.db))
            #expect(promoted.isSystemAdmin)
            #expect(console.lines.contains { $0.contains("was already a system administrator") })
        }
    }
}
