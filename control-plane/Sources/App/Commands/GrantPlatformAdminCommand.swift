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
/// It is refused for an account that already has a passkey, one that is
/// disabled, and one provisioned by OIDC or SCIM — in each case the invite
/// would be useless at best and a lockout at worst.
///
/// Every run writes an `iam.platform_admin_granted` audit event. Observability
/// is most of what a named command buys over the raw SQL, so it is not
/// optional: the record is flushed before the command returns.
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

        @Flag(
            name: "quiet", short: "q",
            help: "Suppress prose; with --claim, print only the claim URL on stdout")
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

    struct DisabledAccountError: Error, CustomStringConvertible {
        let username: String
        var description: String {
            """
            grant-platform-admin refused: '\(username)' is disabled, and every claim endpoint \
            rejects a disabled account — the link would be dead on arrival. Re-enable the account \
            first.
            """
        }
    }

    struct NonLocalAccountError: Error, CustomStringConvertible {
        let username: String
        let source: String
        var description: String {
            """
            grant-platform-admin refused: '\(username)' is provisioned by \(source), so a local \
            passkey invite is not how it signs in. Promote it without --claim and have them \
            authenticate through their identity provider.
            """
        }
    }

    func run(using context: CommandContext, signature: Signature) async throws {
        let app = context.application
        let console = context.console

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

        if signature.claim {
            // Both mirror gates the claim endpoints apply, refused here so the
            // operator finds out now rather than from a link that 4xx's mid-outage:
            // `claimBegin`/`claimFinish` call `rejectDisabledAccount`, and a
            // local passkey invite is not how an OIDC/SCIM identity signs in.
            guard user.disabledAt == nil else { throw DisabledAccountError(username: user.username) }
            guard user.source == .local else {
                throw NonLocalAccountError(username: user.username, source: user.source.rawValue)
            }
        }

        let claimToken = signature.claim ? AccountClaimToken.generateToken() : nil
        let claimExpiresAt = Date().addingTimeInterval(UserController.claimTokenTTL)
        let wasAlreadyAdmin = user.isSystemAdmin

        try await app.db.transaction { db in
            // The enrollment check belongs *inside* the transaction that mints.
            // Read outside it, a concurrent claim or self-registration could
            // enroll the account's first credential in the gap, and this would
            // then write an unclaimed invite onto an account that now has a
            // passkey — `beginRegistration` refuses those, so the recovery
            // command would itself cause the lockout it exists to undo.
            if signature.claim {
                let credentialCount = try await UserCredential.query(on: db)
                    .filter(\.$user.$id == userID)
                    .count()
                guard credentialCount == 0 else { throw AlreadyEnrolledError(username: user.username) }
            }

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

        // The highest-privilege mutation in the system, made outside the
        // evaluator — so the trail is the only thing that can answer "who
        // granted this, and when" afterwards. Flushed explicitly rather than
        // left to shutdown ordering: a one-shot command must not depend on the
        // retention handler running to persist its own record.
        await app.audit.record(
            AuditRecord(
                eventType: "iam.platform_admin_granted",
                userID: userID,
                username: user.username,
                resourceType: "user",
                resourceID: userID.uuidString,
                action: "grant",
                adminBypass: true,
                metadata: [
                    "via": "cli",
                    "already_admin": String(wasAlreadyAdmin),
                    "claim_minted": String(claimToken != nil),
                ]))
        await app.audit.flush(waitingUpTo: .seconds(5))

        if signature.quiet {
            // A pure output modifier, as in `bootstrap`: it never changes what
            // the command does, so a scripted promotion without --claim simply
            // prints nothing.
            if let claimToken {
                console.print(UserController.claimURL(for: claimToken))
            }
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
