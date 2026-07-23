import Fluent
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
/// The seeded user has no WebAuthn credential and cannot log in to the UI; it
/// is an automation identity. Note that it consumes the first-user slot: a
/// person who registers in the browser afterwards will NOT become system
/// admin. Runs after `configure`, so migrations and the IAM role registry are
/// already in place.
struct BootstrapCommand: AsyncCommand {
    struct Signature: CommandSignature {
        @Option(name: "username", help: "Username for the seeded admin user (default: bootstrap)")
        var username: String?

        @Option(name: "email", help: "Email for the seeded admin user (default: bootstrap@localhost)")
        var email: String?

        @Option(name: "org-name", help: "Organization name (default: Default Organization)")
        var orgName: String?

        @Option(name: "project-name", help: "Project name (default: Default Project)")
        var projectName: String?

        @Option(name: "key-name", help: "Name of the created API key (default: bootstrap)")
        var keyName: String?

        @Flag(name: "quiet", short: "q", help: "Print only the API key on stdout (for scripting)")
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

    func run(using context: CommandContext, signature: Signature) async throws {
        let app = context.application
        let console = context.console

        guard try await User.isFirstUser(on: app.db) else {
            console.error("Refusing to bootstrap: one or more users already exist.")
            console.error("This command only seeds a brand-new deployment; manage access through the UI/API instead.")
            throw RefusedError()
        }

        let username = signature.username ?? "bootstrap"
        let email = signature.email ?? "bootstrap@localhost"
        let orgName = signature.orgName ?? "Default Organization"
        let projectName = signature.projectName ?? "Default Project"
        let keyName = signature.keyName ?? "bootstrap"

        // Mirrors UserController.finishRegistration (first user ⇒ system admin)
        // followed by OrganizationController.create — but as ONE transaction
        // covering every relational row including the API key. A failure at any
        // point rolls everything back, keeping `isFirstUser` true so the
        // command can simply be re-run.
        let user = User(username: username, email: email, displayName: username, isSystemAdmin: true)
        let organization = Organization(name: orgName, description: "Created by `App bootstrap`")
        let fullKey = APIKey.generateAPIKey()

        let project = try await app.db.transaction { db -> Project in
            try await user.save(on: db)
            let userID = try user.requireID()

            try await organization.save(on: db)
            let orgID = try organization.requireID()

            let membership = UserOrganization(userID: userID, organizationID: orgID, role: "admin")
            try await membership.save(on: db)
            try await RoleBindingService.grant(
                principalType: .user,
                principalID: userID,
                role: .admin,
                nodeType: .organization,
                nodeID: orgID,
                createdBy: userID,
                on: db
            )

            user.currentOrganizationId = orgID
            try await user.save(on: db)

            let project = Project(
                name: projectName,
                description: "Created by `App bootstrap`",
                organizationID: orgID,
                path: "/\(orgID.uuidString)"
            )
            try await project.save(on: db)
            let projectID = try project.requireID()
            project.path = "/\(orgID.uuidString)/\(projectID.uuidString)"
            try await project.save(on: db)

            try await RoleBindingService.grant(
                principalType: .user,
                principalID: userID,
                role: .admin,
                nodeType: .project,
                nodeID: projectID,
                createdBy: userID,
                on: db
            )

            // A default site (availability zone) so the seeded org can enroll
            // agents immediately — enrollment requires a site.
            try await Site.createDefault(forOrganization: orgID, named: orgName, on: db)

            let apiKey = APIKey(
                userID: userID,
                name: keyName,
                keyHash: APIKey.hashAPIKey(fullKey),
                keyPrefix: String(fullKey.prefix(12)) + "...",
                scopes: [APIKeyScope.admin.rawValue]
            )
            try await apiKey.save(on: db)
            return project
        }

        let userID = try user.requireID()
        let orgID = try organization.requireID()
        let projectID = try project.requireID()

        if signature.quiet {
            console.print(fullKey)
            return
        }

        console.success("Bootstrap complete.")
        console.print()
        console.print("  User:         \(username) <\(email)> (system admin, id \(userID.uuidString))")
        console.print("  Organization: \(orgName) (id \(orgID.uuidString))")
        console.print("  Project:      \(projectName) (id \(projectID.uuidString))")
        console.print("  Site:         \(Site.defaultName(forOrganizationNamed: orgName))")
        console.print()
        console.print("  API key (admin scope — shown once, store it now):")
        console.print()
        console.print("    \(fullKey)")
        console.print()
        console.print("  Use it as:  Authorization: Bearer <key>")
        console.warning("The seeded user has no passkey and cannot log in to the UI, and the")
        console.warning("first-user-becomes-admin slot is now used: users registering in the")
        console.warning("browser get no special privileges. Manage them with this API key.")
    }
}
