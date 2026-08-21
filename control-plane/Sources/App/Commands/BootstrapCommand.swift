import ControlPlanePostgres
import Vapor

/// `App bootstrap` — seed a first admin user, organization, and project, and
/// print an API key once, so a fresh deployment can be driven programmatically
/// (CI, end-to-end tests, IaC) without a human completing the WebAuthn
/// first-user flow in a browser.
///
/// Guard: refuses outright when any user already exists. This is the same
/// trust-on-first-use model as the web flow (the first registrant becomes
/// system admin), so the command needs no extra "I really mean it" flag — on a
/// deployment that has any user at all it does nothing.
///
/// Two shapes, chosen by `--admin-email` (STR-178):
///
/// - **With `--admin-email`** the seeded account belongs to a *person*. It gets
///   an account claim, and the command prints the claim link they open in
///   a browser to enroll a passkey. This is the recommended path for an
///   interactive install: the operator ends up administering the deployment as
///   themselves, rather than through a second account.
/// - **Without it** the seeded account is a headless automation identity with
///   no WebAuthn credential, reachable only through the printed API key — the
///   original behaviour, kept for CI and IaC.
///
/// Either way it consumes the first-user slot, so a person who self-registers
/// in the browser afterwards does NOT become system admin. That is why the
/// human path exists at all: before it, a fresh deployment's only admin was an
/// account nobody could log in as. Runs after `configure`, so migrations and
/// the IAM role registry are already in place.
struct BootstrapCommand: AsyncCommand {
    private let persistence: BootstrapPersistence

    init(persistence: BootstrapPersistence) {
        self.persistence = persistence
    }

    struct Signature: CommandSignature {
        @Option(
            name: "admin-email",
            help: """
                Email of the person who will administer this deployment. Seeds them as the \
                first admin and prints a one-time claim link for enrolling a passkey. \
                Recommended for interactive installs; mutually exclusive with --email.
                """)
        var adminEmail: String?

        @Option(
            name: "username",
            help: "Username for the seeded admin user (default: bootstrap, or the local part of --admin-email)")
        var username: String?

        @Option(
            name: "email",
            help: "Email for the seeded headless automation user (default: bootstrap@localhost)")
        var email: String?

        @Option(name: "org-name", help: "Organization name (default: Default Organization)")
        var orgName: String?

        @Option(name: "project-name", help: "Project name (default: Default Project)")
        var projectName: String?

        @Option(name: "key-name", help: "Name of the created API key (default: bootstrap)")
        var keyName: String?

        @Flag(
            name: "no-api-key",
            help: "Skip the admin-scoped API key. Useful with --admin-email, where the passkey is the credential.")
        var noAPIKey: Bool

        @Flag(
            name: "quiet", short: "q",
            help: "Print only the secrets on stdout, one per line: the API key, then the claim URL if minted")
        var quiet: Bool
    }

    var help: String {
        "Seed a first admin user + organization + project and print an API key once. Refuses if any user exists."
    }

    struct RefusedError: Error, CustomStringConvertible {
        var description: String {
            "bootstrap refused: users already exist. This command only seeds an empty deployment."
        }
    }

    struct ConflictingEmailError: Error, CustomStringConvertible {
        var description: String {
            """
            bootstrap refused: pass either --admin-email (a person who claims the account \
            in a browser) or --email (a headless automation identity), not both.
            """
        }
    }

    struct UnreachableSeedError: Error, CustomStringConvertible {
        var description: String {
            """
            bootstrap refused: --no-api-key without --admin-email would seed an administrator with \
            neither a passkey nor a key — nothing could reach it. Pass --admin-email, or keep the \
            API key.
            """
        }
    }

    struct UnusableDerivedUsernameError: Error, CustomStringConvertible {
        let localPart: String
        let reason: String
        var description: String {
            """
            bootstrap refused: cannot derive a username from --admin-email — \(reason) \
            (local part '\(localPart)'). Pass --username explicitly.
            """
        }
    }

    func run(using context: CommandContext, signature: Signature) async throws {
        let app = context.application
        let console = context.console

        guard !(try await persistence.hasUsers()) else {
            console.error("Refusing to bootstrap: one or more users already exist.")
            console.error("This command only seeds a brand-new deployment; manage access through the UI/API instead.")
            throw RefusedError()
        }

        // `--admin-email` and `--email` name the same column for opposite
        // purposes, so taking both would silently drop one. Only the human path
        // is validated: the headless default (`bootstrap@localhost`) has no dot
        // in its domain and `validateEmail` would rightly refuse it.
        guard signature.adminEmail == nil || signature.email == nil else { throw ConflictingEmailError() }
        // Dropping the key is only safe when something else can reach the
        // account. Without `--admin-email` there is no passkey either, and the
        // seeded admin would be unreachable by construction — the exact failure
        // STR-178 is about, made worse.
        guard !signature.noAPIKey || signature.adminEmail != nil else { throw UnreachableSeedError() }
        let adminEmail = try signature.adminEmail.map { try UserController.validateEmail($0) }

        let username = try Self.resolveUsername(signature.username, adminEmail: adminEmail)
        let email = adminEmail ?? signature.email ?? "bootstrap@localhost"
        let orgName = signature.orgName ?? "Default Organization"
        // A label, not a role: nothing resolves a project by name (issue #1059),
        // so `--project-name` is free to be anything. It did matter once — VM
        // and sandbox creates with no `projectId` looked for a project named
        // exactly "Default Project", so bootstrapping with any other name left
        // an installation where those two endpoints refused and the other five
        // quietly worked.
        let projectName = signature.projectName ?? "Default Project"
        let keyName = signature.keyName ?? "bootstrap"

        let userID = UUID()
        let orgID = UUID()
        let projectID = UUID()
        let siteID = UUID()
        // A permanent admin-scoped credential in terminal scrollback is exactly
        // what the headless path needs and what the human path usually does not
        // — there, the passkey is the credential. Opt-out rather than opt-in so
        // existing automation keeps working unchanged.
        let fullKey = signature.noAPIKey ? nil : APIKeyCredential.generate()
        // Minted outside the transaction like the API key, so the raw value
        // survives for printing; only its hash is ever stored. Nil on the
        // headless path, which seeds no credential of any kind.
        let claimToken = adminEmail == nil ? nil : AccountClaimSecret.generateToken()
        let claimExpiresAt = Date().addingTimeInterval(UserController.claimTokenTTL)
        let claim = claimToken.map {
            AccountClaimIssue(
                tokenHash: AccountClaimSecret.hashToken($0),
                tokenPrefix: AccountClaimSecret.extractPrefix($0),
                expiresAt: claimExpiresAt,
                createdByID: userID
            )
        }
        let apiKey = fullKey.map {
            APIKeyWrite(
                userID: userID,
                name: keyName,
                keyHash: APIKeyCredential.hash($0),
                keyPrefix: String($0.prefix(12)) + "...",
                restriction: CredentialRestriction.unrestricted.stored
            )
        }
        do {
            _ = try await persistence.createInstallation(
                BootstrapInstallationWrite(
                    userID: userID,
                    username: username,
                    email: email,
                    organizationID: orgID,
                    organizationName: orgName,
                    projectID: projectID,
                    projectName: projectName,
                    siteID: siteID,
                    siteName: Site.defaultName(forOrganizationNamed: orgName),
                    adminRoleID: IAMRole.admin.seededID,
                    claim: claim,
                    apiKey: apiKey
                )
            )
        } catch BootstrapPersistenceError.alreadyInitialized {
            throw RefusedError()
        }

        if signature.quiet {
            // One secret per line, in a fixed order. The extra lines appear
            // only in flag combinations that did not exist before, so no script
            // reading the first line can break.
            if let fullKey { console.print(fullKey) }
            if let claimToken {
                console.print(
                    UserController.claimURL(
                        for: claimToken, configuration: app.controlPlaneConfiguration))
            }
            return
        }

        console.success("Bootstrap complete.")
        console.print()
        console.print("  User:         \(username) <\(email)> (system admin, id \(userID.uuidString))")
        console.print("  Organization: \(orgName) (id \(orgID.uuidString))")
        console.print("  Project:      \(projectName) (id \(projectID.uuidString))")
        console.print("  Site:         \(Site.defaultName(forOrganizationNamed: orgName))")
        if let fullKey {
            console.print()
            console.print("  API key (unrestricted — shown once, store it now):")
            console.print()
            console.print("    \(fullKey)")
            console.print()
            console.print("  Use it as:  Authorization: Bearer <key>")
        }

        guard let claimToken else {
            console.warning("The seeded user has no passkey and cannot log in to the UI, and the")
            console.warning("first-user-becomes-admin slot is now used: users registering in the")
            console.warning("browser get no special privileges. Manage them with this API key, or")
            console.warning("re-run with --admin-email to seed a person who can sign in instead.")
            return
        }

        console.print()
        console.success("  Next: open this link in a browser to register your passkey.")
        console.print("  Single use, valid until \(Self.expiryFormatter.string(from: claimExpiresAt)).")
        console.print()
        let claimURL = UserController.claimURL(
            for: claimToken,
            configuration: app.controlPlaneConfiguration)
        console.print("    \(claimURL)")
        console.print()
        console.warning("The link's origin comes from WEBAUTHN_RELYING_PARTY_ORIGIN and must match")
        console.warning("the URL you browse to, or the passkey ceremony will fail.")
    }

    /// The seeded account's username: the flag when given, `bootstrap` for the
    /// headless identity, otherwise the admin email's local part.
    ///
    /// Only the *derived* name is validated, and only the local part that needs
    /// no editing is accepted. Deriving `adaci` from `ada+ci@example.com` would
    /// seed an account under a name the operator never typed and, under
    /// `--quiet`, never sees — so a local part carrying anything outside the
    /// username alphabet asks for `--username` instead of being quietly
    /// mangled. `UserController.usernameAllowedCharacters` is the shared
    /// source of that alphabet; a second copy here could drift from it.
    ///
    /// An explicit `--username` is passed through as it always has been —
    /// tightening it here would break existing automation over a rule this
    /// command never enforced.
    private static func resolveUsername(_ explicit: String?, adminEmail: String?) throws -> String {
        if let explicit { return explicit }
        guard let adminEmail else { return "bootstrap" }

        let localPart = String(adminEmail.prefix { $0 != "@" })
        guard localPart.unicodeScalars.allSatisfy(UserController.usernameAllowedCharacters.contains) else {
            throw UnusableDerivedUsernameError(
                localPart: localPart,
                reason: "it contains characters a username may not")
        }
        do {
            return try UserController.validateUsername(localPart)
        } catch {
            throw UnusableDerivedUsernameError(
                localPart: localPart,
                reason: "it is not between 3 and 64 characters")
        }
    }

    private static let expiryFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm 'UTC'"
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter
    }()
}
