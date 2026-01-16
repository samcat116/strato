import Vapor
import Fluent

struct OnboardingController: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        // API endpoint for onboarding setup
        let onboarding = routes.grouped("api", "onboarding")
        onboarding.post("setup", use: setupOrganization)
    }

    func setupOrganization(req: Request) async throws -> OrganizationSetupResponse {
        // Only allow access if user is system admin
        guard let user = req.auth.get(User.self) else {
            throw Abort(.unauthorized)
        }

        guard user.isSystemAdmin else {
            throw Abort(.forbidden, reason: "Access denied")
        }

        // Decode organization data
        let setupRequest = try req.content.decode(OrganizationSetupRequest.self)

        // Create the organization
        let organization = Organization(
            name: setupRequest.name,
            description: setupRequest.description
        )
        try await organization.save(on: req.db)

        // Add user as admin of the organization
        let userOrganization = UserOrganization(
            userID: user.id!,
            organizationID: organization.id!,
            role: "admin"
        )
        try await userOrganization.save(on: req.db)

        // Set this as the user's current organization
        user.currentOrganizationId = organization.id
        try await user.save(on: req.db)

        // Remove system admin from default organization if they were added there
        try await removeUserFromDefaultOrganization(user: user, req: req)

        // Create SpiceDB relationships
        do {
            let userID = user.id!.uuidString
            let orgID = organization.id!.uuidString

            // Create admin relationship
            try await req.spicedb.writeRelationship(
                entity: "organization",
                entityId: orgID,
                relation: "admin",
                subject: "user",
                subjectId: userID
            )

            // Create member relationship
            try await req.spicedb.writeRelationship(
                entity: "organization",
                entityId: orgID,
                relation: "member",
                subject: "user",
                subjectId: userID
            )
        } catch {
            req.logger.warning("Failed to create SpiceDB relationships: \(error)")
            // Don't fail the setup if SpiceDB fails
        }

        return OrganizationSetupResponse(
            organization: organization.asPublic(),
            success: true
        )
    }

    // MARK: - Helper Functions

    private func removeUserFromDefaultOrganization(user: User, req: Request) async throws {
        // Find default organization
        guard let defaultOrg = try await Organization.query(on: req.db)
            .filter(\.$name == "Default Organization")
            .first() else {
            return // No default organization exists
        }

        // Find and remove user's membership in default organization
        if let membership = try await UserOrganization.query(on: req.db)
            .filter(\.$user.$id == user.id!)
            .filter(\.$organization.$id == defaultOrg.id!)
            .first() {

            try await membership.delete(on: req.db)
            req.logger.info("Removed system admin \(user.username) from default organization")

            // Note: SpiceDB relationships for default org are not deleted since system admins bypass permissions anyway
            req.logger.info("System admin \(user.username) removed from default org, SpiceDB bypass in effect")
        }
    }
}

// MARK: - DTOs

struct OrganizationSetupRequest: Content {
    let name: String
    let description: String
}

struct OrganizationSetupResponse: Content {
    let organization: Organization.Public
    let success: Bool
}
