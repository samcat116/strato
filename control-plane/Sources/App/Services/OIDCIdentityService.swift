import Fluent
import Foundation
import Vapor

/// Maps a validated OIDC identity onto Strato's user/group/role model.
///
/// Owns everything that happens after ID-token validation on an OIDC login:
/// resolving (or JIT-provisioning) the user record, converging the OIDC and
/// SCIM identity paths onto one user, enforcing SCIM deactivation, and syncing
/// IdP-managed group memberships and the org role from token claims
/// (issue #363). Lives outside `OIDCController` so tests can drive it without
/// a fake IdP.
struct OIDCIdentityService {
    let db: Database
    let spicedb: SpiceDBServiceProtocol
    let logger: Logger

    // MARK: - Claim extraction

    /// Extract the group/role values from an ID token's payload for the given
    /// claim name. Accepts a JSON array of strings (non-strings are ignored)
    /// or a single string value; a missing claim yields an empty array.
    ///
    /// The token's signature must already have been verified — this reads the
    /// payload without any validation.
    static func extractGroupClaimValues(idToken: String, claim: String) throws -> [String] {
        let parts = idToken.split(separator: ".")
        guard parts.count == 3 else {
            throw Abort(.badRequest, reason: "Invalid ID token format")
        }
        let payloadData = try OIDCValidation.decodeBase64URLSafe(String(parts[1]))
        guard let payload = try JSONSerialization.jsonObject(with: payloadData) as? [String: Any] else {
            throw Abort(.badRequest, reason: "Invalid ID token payload")
        }
        switch payload[claim] {
        case let values as [Any]:
            return values.compactMap { $0 as? String }
        case let value as String:
            return [value]
        default:
            return []
        }
    }

    // MARK: - User resolution

    /// Find the user for a validated OIDC identity, or JIT-provision one.
    ///
    /// Resolution order converges the OIDC and SCIM identity paths on a single
    /// user record: (1) previously linked OIDC user, (2) SCIM-provisioned user
    /// whose externalId matches the OIDC subject, (3) org member with the same
    /// email; both (2) and (3) link the user to the provider. Otherwise a new
    /// user is created and added to the org with the role derived from the
    /// provider's admin claim values and configured default role, mirrored to
    /// SpiceDB (previously the tuple was never written for JIT users).
    func resolveUser(
        userInfo: OIDCUserInfo,
        provider: OIDCProvider,
        organization: Organization,
        groupValues: [String]
    ) async throws -> User {
        guard let providerID = provider.id, let organizationID = organization.id else {
            throw Abort(.internalServerError, reason: "Provider and organization IDs are required")
        }

        if let existingUser = try await User.findOIDCUser(subject: userInfo.subject, providerID: providerID, on: db) {
            return existingUser
        }

        // A SCIM-provisioned user whose externalId matches the OIDC subject is
        // the same identity arriving via the other provisioning path.
        if let internalID = try await SCIMExternalID.findInternalID(
            externalId: userInfo.subject,
            resourceType: .user,
            organizationID: organizationID,
            on: db
        ), let scimUser = try await User.find(internalID, on: db) {
            scimUser.linkToOIDCProvider(providerID, subject: userInfo.subject)
            try await scimUser.save(on: db)
            logger.info(
                "Linked OIDC login to SCIM-provisioned user",
                metadata: [
                    "user_id": .string(internalID.uuidString),
                    "provider_id": .string(providerID.uuidString),
                ])
            return scimUser
        }

        // Fall back to an existing org member with the same email.
        if let email = userInfo.email {
            let usersWithEmail = try await User.query(on: db)
                .filter(\.$email == email)
                .with(\.$organizations)
                .all()

            for user in usersWithEmail {
                let userOrgIDs = user.organizations.compactMap { $0.id }
                if userOrgIDs.contains(organizationID) {
                    user.linkToOIDCProvider(providerID, subject: userInfo.subject)
                    try await user.save(on: db)
                    return user
                }
            }
        }

        // JIT-provision a new user.
        let username = userInfo.preferredUsername ?? userInfo.email ?? "oidc_\(userInfo.subject.prefix(8))"
        let displayName = userInfo.name ?? username
        let email = userInfo.email ?? ""

        let user = User(
            username: username,
            email: email,
            displayName: displayName,
            isSystemAdmin: false,
            oidcProviderID: providerID,
            oidcSubject: userInfo.subject
        )

        try await user.save(on: db)

        guard let userID = user.id else {
            throw Abort(.internalServerError, reason: "User ID is required")
        }

        let role = desiredOrganizationRole(provider: provider, groupValues: groupValues)
        let membership = UserOrganization(
            userID: userID,
            organizationID: organizationID,
            role: role
        )
        try await membership.save(on: db)

        try await spicedb.setOrganizationRole(
            userID: userID.uuidString,
            organizationID: organizationID.uuidString,
            oldRole: nil,
            newRole: role
        )

        return user
    }

    // MARK: - SCIM deactivation

    /// Deny login for users the IdP has deactivated via SCIM. Mirrors
    /// `rejectDisabledAccount` for the SCIM soft-delete flag: a deactivated
    /// user must never get a session, even though their row still exists.
    func enforceSCIMActive(_ user: User) throws {
        if user.scimProvisioned && !user.scimActive {
            throw Abort(.forbidden, reason: "Account has been deactivated")
        }
    }

    // MARK: - Group membership sync

    /// Converge the user's membership in IdP-managed groups with the token's
    /// claim values. Only groups listed in the provider's mappings are
    /// touched: a mapped claim value present in the token ensures membership,
    /// a mapped group with none of its claim values present is removed.
    /// Memberships in unmapped groups (manual or SCIM-managed) are untouched.
    func syncGroupMemberships(
        user: User,
        provider: OIDCProvider,
        organizationID: UUID,
        groupValues: [String]
    ) async throws {
        let mappings = provider.groupMappingsArray
        guard !mappings.isEmpty, let userID = user.id else { return }

        let claimValues = Set(groupValues)

        // Several claim values may map to the same group; membership is
        // desired if any of them is present.
        var desiredByGroup: [UUID: Bool] = [:]
        for mapping in mappings {
            desiredByGroup[mapping.groupID, default: false] =
                desiredByGroup[mapping.groupID, default: false] || claimValues.contains(mapping.claimValue)
        }

        for (groupID, desired) in desiredByGroup {
            guard let group = try await Group.find(groupID, on: db),
                group.$organization.id == organizationID
            else {
                logger.warning(
                    "OIDC group mapping references a missing or foreign group; skipping",
                    metadata: ["group_id": .string(groupID.uuidString)])
                continue
            }

            let isMember = try await group.hasMember(userID, on: db)
            if desired && !isMember {
                try await group.addMember(userID, on: db)
                try await spicedb.addUserToGroup(userID: userID.uuidString, groupID: groupID.uuidString)
            } else if !desired && isMember {
                try await group.removeMember(userID, on: db)
                try await spicedb.removeUserFromGroup(userID: userID.uuidString, groupID: groupID.uuidString)
            }
        }
    }

    // MARK: - Org role reconciliation

    /// Reconcile the user's org role with the token's claims. Opt-in: does
    /// nothing unless the provider configures admin claim values. When
    /// configured, the IdP is authoritative — a matching claim value grants
    /// "admin", otherwise the user is set to the provider's default role.
    /// Demoting the organization's last admin is skipped so a misconfigured
    /// IdP cannot lock everyone out.
    func reconcileOrganizationRole(
        user: User,
        provider: OIDCProvider,
        organizationID: UUID,
        groupValues: [String]
    ) async throws {
        guard !provider.adminClaimValuesArray.isEmpty, let userID = user.id else { return }

        guard
            let membership = try await UserOrganization.query(on: db)
                .filter(\.$user.$id == userID)
                .filter(\.$organization.$id == organizationID)
                .first()
        else {
            return
        }

        let desired = desiredOrganizationRole(provider: provider, groupValues: groupValues)
        guard membership.role != desired else { return }

        if membership.role == "admin" {
            let otherAdmins = try await UserOrganization.query(on: db)
                .filter(\.$organization.$id == organizationID)
                .filter(\.$role == "admin")
                .filter(\.$user.$id != userID)
                .count()
            if otherAdmins == 0 {
                logger.warning(
                    "OIDC role mapping would demote the organization's last admin; skipping",
                    metadata: [
                        "user_id": .string(userID.uuidString),
                        "organization_id": .string(organizationID.uuidString),
                    ])
                return
            }
        }

        let oldRole = membership.role
        membership.role = desired
        try await membership.save(on: db)

        try await spicedb.setOrganizationRole(
            userID: userID.uuidString,
            organizationID: organizationID.uuidString,
            oldRole: oldRole,
            newRole: desired
        )
    }

    /// The org role the token's claims call for: "admin" when any configured
    /// admin claim value is present, the provider's default role otherwise.
    func desiredOrganizationRole(provider: OIDCProvider, groupValues: [String]) -> String {
        let adminValues = Set(provider.adminClaimValuesArray)
        if !adminValues.isEmpty && groupValues.contains(where: adminValues.contains) {
            return "admin"
        }
        return provider.defaultRole
    }
}
