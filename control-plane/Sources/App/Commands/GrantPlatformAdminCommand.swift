import Fluent
import Foundation
import Vapor

/// `App grant-platform-admin` — the break-glass path back into a deployment
/// whose admin surfaces have become unreachable (STR-178).
///
/// Granting the first administrator cannot itself be an authorization decision:
/// there is no principal to authorize and nothing to authorize against. That
/// makes this a root-of-trust operation, and the point of the command is to
/// give it a name and a documented shape instead of leaving operators to
/// hand-write `UPDATE users SET is_system_admin = true` — which is what the
/// issue found people doing.
///
/// Unlike `bootstrap` this runs on a populated deployment, and it promotes an
/// account that already exists rather than seeding one. Its only guard is
/// possession of the shell the control plane runs in, which is the same trust
/// level a direct database write already required.
///
/// `--claim` covers the other half of the lockout: an account with no passkey
/// (a `bootstrap`-seeded automation identity, or an invite whose link was lost)
/// cannot sign in at all, so the command can mint a fresh claim link for it.
struct GrantPlatformAdminCommand: AsyncCommand {
    struct Signature: CommandSignature {
        @Option(name: "email", help: "Email of the existing account to promote")
        var email: String?

        @Option(name: "username", help: "Username of the existing account to promote (alternative to --email)")
        var username: String?

        @Flag(
            name: "claim",
            help: "Also mint a one-time claim link, for an account that has no passkey yet")
        var claim: Bool

        @Flag(name: "quiet", short: "q", help: "Print only the claim URL on stdout (implies --claim)")
        var quiet: Bool
    }

    var help: String {
        "Promote an existing user to system administrator, optionally minting a passkey claim link."
    }

    struct SelectorError: Error, CustomStringConvertible {
        var description: String {
            "grant-platform-admin refused: pass exactly one of --email or --username."
        }
    }

    struct NotFoundError: Error, CustomStringConvertible {
        let selector: String
        var description: String {
            """
            grant-platform-admin refused: no user matches \(selector). This command promotes an \
            existing account; register one in the browser first, or run `App bootstrap` on an \
            empty deployment.
            """
        }
    }

    struct AlreadyEnrolledError: Error, CustomStringConvertible {
        let username: String
        var description: String {
            """
            grant-platform-admin refused: '\(username)' already has a passkey, so --claim would \
            lock them out — an unclaimed invite blocks passkey enrollment until it is redeemed. \
            Re-run without --claim to promote them, and have them sign in as usual.
            """
        }
    }

    func run(using context: CommandContext, signature: Signature) async throws {
        let app = context.application
        let console = context.console
        let wantsClaim = signature.claim || signature.quiet

        guard (signature.email == nil) != (signature.username == nil) else { throw SelectorError() }

        let query = User.query(on: app.db)
        let selector: String
        if let email = signature.email?.trimmingCharacters(in: .whitespacesAndNewlines) {
            query.filter(\.$email == email)
            selector = "email '\(email)'"
        } else {
            let username = signature.username!.trimmingCharacters(in: .whitespacesAndNewlines)
            query.filter(\.$username == username)
            selector = "username '\(username)'"
        }
        guard let user = try await query.first() else { throw NotFoundError(selector: selector) }
        let userID = try user.requireID()

        // Minting an invite for an account that can already sign in is not a
        // no-op: `/auth/register/begin` refuses any account holding an
        // unclaimed token, so this would take away the passkey path it was
        // meant to restore.
        if wantsClaim {
            let credentialCount = try await UserCredential.query(on: app.db)
                .filter(\.$user.$id == userID)
                .count()
            guard credentialCount == 0 else { throw AlreadyEnrolledError(username: user.username) }
        }

        let claimToken = wantsClaim ? AccountClaimToken.generateToken() : nil
        let claimExpiresAt = Date().addingTimeInterval(UserController.claimTokenTTL)
        let wasAlreadyAdmin = user.isSystemAdmin

        try await app.db.transaction { db in
            user.isSystemAdmin = true
            try await user.save(on: db)

            if let claimToken {
                // Any older invite is superseded — leaving it live would give
                // two working links to one account, and the stale one is
                // exactly what a lost-link recovery is trying to replace.
                try await AccountClaimToken.query(on: db)
                    .filter(\.$user.$id == userID)
                    .filter(\.$claimedAt == nil)
                    .delete()

                let claim = AccountClaimToken(
                    userID: userID,
                    tokenHash: AccountClaimToken.hashToken(claimToken),
                    tokenPrefix: AccountClaimToken.extractPrefix(claimToken),
                    expiresAt: claimExpiresAt,
                    createdByID: userID
                )
                try await claim.save(on: db)
            }
        }

        if signature.quiet, let claimToken {
            console.print(UserController.claimURL(for: claimToken))
            return
        }

        if wasAlreadyAdmin {
            console.print("\(user.username) <\(user.email)> was already a system administrator.")
        } else {
            console.success("Promoted \(user.username) <\(user.email)> to system administrator.")
        }

        guard let claimToken else { return }
        console.print()
        console.print(
            "  Passkey claim link — single use, valid until \(Self.expiryFormatter.string(from: claimExpiresAt)):")
        console.print()
        console.print("    \(UserController.claimURL(for: claimToken))")
        console.print()
        console.warning("The link's origin comes from WEBAUTHN_RELYING_PARTY_ORIGIN and must match")
        console.warning("the URL you browse to, or the passkey ceremony will fail.")
    }

    private static let expiryFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm 'UTC'"
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter
    }()
}
