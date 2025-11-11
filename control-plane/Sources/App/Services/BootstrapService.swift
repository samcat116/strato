import Fluent
import Vapor
import Foundation

/// Service responsible for bootstrapping the application with initial admin user and API key
struct BootstrapService {
    let app: Application

    /// Bootstrap the application with an initial admin user, organization, project, and API key
    /// This only runs if no system admin exists in the database
    func bootstrap() async throws {
        let logger = app.logger
        logger.info("Checking if bootstrap is needed...")

        // Check if any system admin exists
        let hasAdmin = try await User.hasSystemAdmin(on: app.db)

        if hasAdmin {
            logger.info("System admin already exists, skipping bootstrap")
            return
        }

        logger.info("No system admin found, bootstrapping initial admin user...")

        // Create admin user
        let adminUser = User(
            username: "admin",
            email: "admin@strato.local",
            displayName: "Administrator",
            isSystemAdmin: true
        )

        try await adminUser.save(on: app.db)
        logger.info("Created admin user with ID: \(adminUser.id?.uuidString ?? "unknown")")

        // Create default organization
        let organization = Organization(
            name: "Default Organization",
            description: "Initial organization created during bootstrap"
        )

        try await organization.save(on: app.db)
        logger.info("Created default organization with ID: \(organization.id?.uuidString ?? "unknown")")

        // Link admin user to organization with admin role
        let userOrganization = UserOrganization(
            userID: adminUser.id!,
            organizationID: organization.id!,
            role: "admin"
        )

        try await userOrganization.save(on: app.db)
        logger.info("Linked admin user to organization")

        // Set current organization for admin user
        adminUser.currentOrganizationId = organization.id
        try await adminUser.save(on: app.db)

        // Create default project
        let project = Project(
            name: "Default Project",
            description: "Initial project created during bootstrap",
            organizationID: organization.id,
            path: "/\(organization.id!.uuidString)/\(UUID().uuidString)",
            defaultEnvironment: "development",
            environments: ["development", "staging", "production"]
        )

        try await project.save(on: app.db)

        // Update project path with actual project ID
        project.path = try await project.buildPath(on: app.db)
        try await project.save(on: app.db)

        logger.info("Created default project with ID: \(project.id?.uuidString ?? "unknown")")

        // Generate API key for admin
        let apiKeyString = APIKey.generateAPIKey()
        let keyHash = APIKey.hashAPIKey(apiKeyString)
        let keyPrefix = String(apiKeyString.prefix(12))

        let apiKey = APIKey(
            userID: adminUser.id!,
            name: "Bootstrap Admin Key",
            keyHash: keyHash,
            keyPrefix: keyPrefix,
            scopes: ["read", "write", "admin"],
            isActive: true,
            expiresAt: nil // Never expires
        )

        try await apiKey.save(on: app.db)
        logger.info("Created API key for admin user with prefix: \(keyPrefix)")

        // Save API key to disk
        try await saveAPIKeyToDisk(apiKeyString, logger: logger)

        logger.info("Bootstrap completed successfully!")
        logger.info("Admin credentials saved to disk")
    }

    /// Save the API key to disk at a well-known location
    private func saveAPIKeyToDisk(_ apiKey: String, logger: Logger) async throws {
        // Try to save to /var/strato/admin-api-key.txt first (production path)
        let productionPath = "/var/strato/admin-api-key.txt"
        let fallbackPath = "./admin-api-key.txt"

        var savedPath: String?

        // Try production path first
        do {
            // Ensure directory exists
            let productionDir = "/var/strato"
            let fileManager = FileManager.default
            if !fileManager.fileExists(atPath: productionDir) {
                try fileManager.createDirectory(atPath: productionDir, withIntermediateDirectories: true)
            }

            try apiKey.write(toFile: productionPath, atomically: true, encoding: .utf8)
            savedPath = productionPath
            logger.info("API key saved to: \(productionPath)")
        } catch {
            // Fall back to current directory
            logger.warning("Could not save to \(productionPath): \(error.localizedDescription)")
            logger.info("Falling back to current directory: \(fallbackPath)")

            do {
                try apiKey.write(toFile: fallbackPath, atomically: true, encoding: .utf8)
                savedPath = fallbackPath
                logger.info("API key saved to: \(fallbackPath)")
            } catch {
                logger.error("Failed to save API key to disk: \(error.localizedDescription)")
                throw Abort(.internalServerError, reason: "Failed to save API key to disk")
            }
        }

        // Set restrictive permissions (owner read-only)
        if let path = savedPath {
            #if os(Linux) || os(macOS)
            let fileManager = FileManager.default
            do {
                try fileManager.setAttributes([.posixPermissions: 0o400], ofItemAtPath: path)
                logger.info("Set restrictive permissions (0400) on API key file")
            } catch {
                logger.warning("Could not set restrictive permissions on API key file: \(error.localizedDescription)")
            }
            #endif
        }

        // Log instructions for the user
        logger.info("=================================================")
        logger.info("INITIAL ADMIN API KEY")
        logger.info("=================================================")
        logger.info("An initial admin user has been created with an API key.")
        logger.info("API Key Location: \(savedPath ?? "unknown")")
        logger.info("")
        logger.info("To use the API key:")
        logger.info("  cat \(savedPath ?? "admin-api-key.txt")")
        logger.info("  curl -H \"Authorization: Bearer $(cat \(savedPath ?? "admin-api-key.txt"))\" http://localhost:8080/api/vms")
        logger.info("")
        logger.info("Admin User Details:")
        logger.info("  Username: admin")
        logger.info("  Email: admin@strato.local")
        logger.info("  Organization: Default Organization")
        logger.info("  Project: Default Project")
        logger.info("")
        logger.info("IMPORTANT: Store this API key securely and delete the file after saving it elsewhere!")
        logger.info("=================================================")
    }
}
