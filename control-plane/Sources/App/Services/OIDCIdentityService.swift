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
    /// whose externalId matches the OIDC subject (only when this is the org's
    /// sole provider — subjects aren't unique across issuers), (3) org member
    /// with the same email; both (2) and (3) link the user to the provider. Otherwise a new
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
        // the same identity arriving via the other provisioning path. Subjects
        // are only unique per issuer and SCIM mappings don't record which IdP
        // they came from, so take this shortcut only when this is the org's
        // sole provider — with several providers, a subject collision across
        // IdPs could log the caller into another user's account. Multi-provider
        // orgs still converge on one record via the email match below.
        let orgProviderCount = try await OIDCProvider.query(on: db)
            .filter(\.$organization.$id == organizationID)
            .count()
        if orgProviderCount == 1,
            let internalID = try await SCIMExternalID.findInternalID(
                externalId: userInfo.subject,
                resourceType: .user,
                organizationID: organizationID,
                on: db
            ), let scimUser = try await User.find(internalID, on: db)
        {
            scimUser.linkToOIDCProvider(providerID, subject: userInfo.subject)
            if scimUser.currentOrganizationId == nil {
                scimUser.currentOrganizationId = organizationID
            }
            try await scimUser.save(on: db)
            logger.info(
                "Linked OIDC login to SCIM-provisioned user",
                metadata: [
                    "user_id": .string(internalID.uuidString),
                    "provider_id": .string(providerID.uuidString),
                ])
            return scimUser
        }

        // Fall back to an existing org member with the same email — but only when
        // the IdP asserts the email is verified. Linking on an unverified email
        // would let a user who can set an arbitrary `email` claim take over a
        // victim's existing account by matching their address.
        if let email = userInfo.email, userInfo.emailVerified {
            let usersWithEmail = try await User.query(on: db)
                .filter(\.$email == email)
                .with(\.$organizations)
                .all()

            for user in usersWithEmail {
                let userOrgIDs = user.organizations.compactMap { $0.id }
                if userOrgIDs.contains(organizationID) {
                    user.linkToOIDCProvider(providerID, subject: userInfo.subject)
                    if user.currentOrganizationId == nil {
                        user.currentOrganizationId = organizationID
                    }
                    try await user.save(on: db)
                    return user
                }
            }
        }

        // JIT-provision a new user. The SQL rows and the SpiceDB tuple must
        // land together: doing the SpiceDB write inside the transaction means
        // a failed write rolls the rows back, so the next login for this
        // subject re-runs provisioning cleanly instead of early-returning a
        // user that authenticates but fails every permission check.
        let username = userInfo.preferredUsername ?? userInfo.email ?? "oidc_\(userInfo.subject.prefix(8))"
        let displayName = userInfo.name ?? username
        let email = userInfo.email ?? ""
        let role = desiredOrganizationRole(provider: provider, groupValues: groupValues)
        let spicedb = self.spicedb

        // Reaching here with an email that already belongs to a user means we were
        // not allowed to link to that account — either the IdP didn't verify the
        // email, or the matching user isn't a member of this org. `users.email` is
        // unique, so JIT-provisioning would fail the constraint; deny with a clear
        // reason instead of surfacing a 500, and never auto-adopt the address.
        if !email.isEmpty {
            let emailTaken = try await User.query(on: db).filter(\.$email == email).first() != nil
            if emailTaken {
                logger.warning(
                    "Refusing to JIT-provision an OIDC user whose email is already in use",
                    metadata: [
                        "provider_id": .string(providerID.uuidString),
                        "subject": .string(userInfo.subject),
                    ])
                throw Abort(
                    .conflict,
                    reason:
                        "This email is already associated with an account and could not be automatically linked. Contact an administrator."
                )
            }
        }

        return try await db.transaction { transaction in
            let user = User(
                username: username,
                email: email,
                displayName: displayName,
                isSystemAdmin: false,
                oidcProviderID: providerID,
                oidcSubject: userInfo.subject
            )
            // Authorization on product routes needs a current org (middleware
            // rejects requests without one), so seed it at provisioning time.
            user.currentOrganizationId = organizationID

            try await user.save(on: transaction)

            guard let userID = user.id else {
                throw Abort(.internalServerError, reason: "User ID is required")
            }

            let membership = UserOrganization(
                userID: userID,
                organizationID: organizationID,
                role: role
            )
            try await membership.save(on: transaction)

            // Mirror the membership into SpiceDB, like OrganizationController's
            // addMember does — without this tuple the new user authenticates
            // but fails every permission check.
            try await spicedb.setOrganizationRole(
                userID: userID.uuidString,
                organizationID: organizationID.uuidString,
                oldRole: nil,
                newRole: role
            )

            return user
        }
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
        // An unset groups claim disables claim mapping entirely: without it
        // no values are ever extracted, and treating that as "every mapped
        // group is absent" would strip memberships.
        guard provider.groupsClaim != nil else { return }
        let mappings = provider.groupMappingsArray
        guard !mappings.isEmpty, let userID = user.id else { return }

        // A user removed from the org keeps their OIDC link, so resolveUser
        // still returns them. Granting org group memberships (which carry
        // project permissions through SpiceDB) to a non-member would undo
        // the removal — claims only ever map onto current org members.
        let membership = try await UserOrganization.query(on: db)
            .filter(\.$user.$id == userID)
            .filter(\.$organization.$id == organizationID)
            .first()
        guard membership != nil else {
            logger.warning(
                "OIDC login for a user without org membership; skipping group claim sync",
                metadata: [
                    "user_id": .string(userID.uuidString),
                    "organization_id": .string(organizationID.uuidString),
                ])
            return
        }

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

            // The SpiceDB call runs inside the transaction so a failed call
            // rolls the row back: with the row committed, the next login
            // would see the DB already converged and never retry the tuple,
            // leaving permissions permanently out of sync.
            let isMember = try await group.hasMember(userID, on: db)
            let spicedb = self.spicedb
            if desired && !isMember {
                try await db.transaction { transaction in
                    try await group.addMember(userID, on: transaction)
                    try await spicedb.addUserToGroup(userID: userID.uuidString, groupID: groupID.uuidString)
                }
            } else if !desired && isMember {
                try await db.transaction { transaction in
                    try await group.removeMember(userID, on: transaction)
                    try await spicedb.removeUserFromGroup(userID: userID.uuidString, groupID: groupID.uuidString)
                }
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
        // As with group sync, an unset groups claim disables role mapping —
        // empty claim values must not demote anyone.
        guard provider.groupsClaim != nil else { return }
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
            // Only admins who can actually sign in count: an admin disabled
            // by SSF or deactivated via SCIM keeps their membership row but
            // is blocked at login, so demoting the last *usable* admin would
            // still lock the org out.
            let otherAdmins = try await UserOrganization.query(on: db)
                .filter(\.$organization.$id == organizationID)
                .filter(\.$role == "admin")
                .filter(\.$user.$id != userID)
                .join(User.self, on: \UserOrganization.$user.$id == \User.$id)
                .filter(User.self, \.$disabledAt == nil)
                .group(.or) { active in
                    active.filter(User.self, \.$scimProvisioned == false)
                    active.filter(User.self, \.$scimActive == true)
                }
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
        // As in group sync, the SpiceDB update runs inside the transaction:
        // committing the row first would make the next login see
        // membership.role == desired and never retry the tuple change.
        let spicedb = self.spicedb
        try await db.transaction { transaction in
            try await membership.save(on: transaction)
            try await spicedb.setOrganizationRole(
                userID: userID.uuidString,
                organizationID: organizationID.uuidString,
                oldRole: oldRole,
                newRole: desired
            )
        }
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
