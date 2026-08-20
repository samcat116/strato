import ControlPlanePostgres
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

        let selector: String
        let user: RecoverableAccountSnapshot?
        if let email = signature.email?.trimmingCharacters(in: .whitespacesAndNewlines) {
            selector = "email '\(email)'"
            user = try await app.accountRecoveryPersistence.account(email: email)
        } else {
            let username = signature.username!.trimmingCharacters(in: .whitespacesAndNewlines)
            selector = "username '\(username)'"
            user = try await app.accountRecoveryPersistence.account(username: username)
        }
        guard let user else { throw NotFoundError(selector: selector) }
        let userID = user.id

        if signature.claim {
            // Both mirror gates the claim endpoints apply, refused here so the
            // operator finds out now rather than from a link that 4xx's mid-outage:
            // `claimBegin`/`claimFinish` call `rejectDisabledAccount`, and a
            // local passkey invite is not how an OIDC/SCIM identity signs in.
            guard user.disabledAt == nil else { throw DisabledAccountError(username: user.username) }
            guard user.source == "local" else {
                throw NonLocalAccountError(username: user.username, source: user.source)
            }
        }

        let claimToken = signature.claim ? AccountClaimSecret.generateToken() : nil
        let claimExpiresAt = Date().addingTimeInterval(UserController.claimTokenTTL)
        let issue = claimToken.map {
            AccountClaimIssue(
                tokenHash: AccountClaimSecret.hashToken($0),
                tokenPrefix: AccountClaimSecret.extractPrefix($0),
                expiresAt: claimExpiresAt,
                createdByID: userID
            )
        }
        let recovery: PlatformAdminRecoveryResult
        do {
            recovery = try await app.accountRecoveryPersistence.grantPlatformAdmin(
                userID: userID,
                claim: issue
            )
        } catch AccountRecoveryPersistenceError.alreadyEnrolled {
            throw AlreadyEnrolledError(username: user.username)
        } catch AccountRecoveryPersistenceError.accountDisabled {
            throw DisabledAccountError(username: user.username)
        } catch AccountRecoveryPersistenceError.accountIsNotLocal(let source) {
            throw NonLocalAccountError(username: user.username, source: source)
        } catch AccountRecoveryPersistenceError.accountNotFound {
            throw NotFoundError(selector: selector)
        }
        let wasAlreadyAdmin = recovery.wasAlreadySystemAdmin

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
                console.print(
                    UserController.claimURL(
                        for: claimToken, configuration: app.controlPlaneConfiguration))
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
        let claimURL = UserController.claimURL(
            for: claimToken,
            configuration: app.controlPlaneConfiguration)
        console.print("    \(claimURL)")
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
