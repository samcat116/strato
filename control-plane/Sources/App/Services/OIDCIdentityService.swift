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
    /// provider's admin claim values and configured default role.
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

        // JIT-provision a new user. The user, membership, and role-binding
        // rows land in one transaction, so a failure re-runs provisioning
        // cleanly on the next login instead of early-returning a user that
        // authenticates but fails every permission check.
        let username = userInfo.preferredUsername ?? userInfo.email ?? "oidc_\(userInfo.subject.prefix(8))"
        let displayName = userInfo.name ?? username
        let email = userInfo.email ?? ""
        // The claim-driven role, resolved across the unified vocabulary — a
        // legacy literal, or a scoped custom role id (issue #611).
        let resolvedRole = await resolveDesiredOrgRole(
            provider: provider, organizationID: organizationID, groupValues: groupValues)

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
                source: .oidc,
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
                role: resolvedRole.storedRole
            )
            try await membership.save(on: transaction)

            // The claim-driven role gets its binding on the org node, in the
            // same transaction as the mirror row — without it the new user
            // authenticates but fails every permission check. Bare membership
            // (default "member") maps to no binding.
            //
            // Deliberately not gated by the write-time ceiling check (#484),
            // unlike the administrative grant APIs: this runs during sign-in,
            // and failing closed here would make an SMT solver a hard
            // dependency of authentication. Guardrails still apply to every
            // request this user makes, so a ceiling is enforced either way —
            // what is given up is only the explanation at write time, for a
            // grant no human is watching anyway.
            if let bindingRoleID = resolvedRole.bindingRoleID {
                try await RoleBindingService.grant(
                    principalType: .user,
                    principalID: userID,
                    roleID: bindingRoleID,
                    nodeType: .organization,
                    nodeID: organizationID,
                    createdBy: nil,
                    on: transaction
                )
            }

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
        // project permissions through group role bindings) to a non-member
        // would undo the removal — claims only ever map onto current org
        // members.
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

            let isMember = try await group.hasMember(userID, on: db)
            if desired && !isMember {
                try await group.addMember(userID, on: db)
            } else if !desired && isMember {
                try await group.removeMember(userID, on: db)
            }
        }
    }

    // MARK: - Org role reconciliation

    /// Reconcile the user's org role with the token's claims. Opt-in: does
    /// nothing unless the provider configures admin claim values or role
    /// mappings. When configured, the IdP is authoritative — a matching claim
    /// value grants the mapped role (admin, or a scoped custom role, issue
    /// #611), otherwise the user is set to the provider's default role.
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
        guard mapsOrganizationRole(provider), let userID = user.id else { return }

        guard
            let membership = try await UserOrganization.query(on: db)
                .filter(\.$user.$id == userID)
                .filter(\.$organization.$id == organizationID)
                .first()
        else {
            return
        }

        let resolved = await resolveDesiredOrgRole(
            provider: provider, organizationID: organizationID, groupValues: groupValues)
        guard membership.role != resolved.storedRole else { return }

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

        let previousRole = membership.role
        membership.role = resolved.storedRole
        try await db.transaction { transaction in
            try await membership.save(on: transaction)
            // Swap the role binding with the mirror-row update. The previously
            // stored value may be a legacy literal or a role id; bare
            // membership ("member") has no binding on either side.
            if let oldBindingID = MemberRoleResolver.organizationStoredRoleID(previousRole) {
                try await RoleBindingService.revoke(
                    principalType: .user,
                    principalID: userID,
                    roleID: oldBindingID,
                    nodeType: .organization,
                    nodeID: organizationID,
                    on: transaction
                )
            }
            if let newBindingID = resolved.bindingRoleID {
                try await RoleBindingService.grant(
                    principalType: .user,
                    principalID: userID,
                    roleID: newBindingID,
                    nodeType: .organization,
                    nodeID: organizationID,
                    createdBy: nil,
                    on: transaction
                )
            }
        }
    }

    /// The raw org role token the claims call for, before resolution. In
    /// precedence order (issue #611):
    ///  1. any configured admin claim value present → the literal `"admin"`;
    ///  2. the first role mapping whose claim value is present → its role id;
    ///  3. the provider's configured default role.
    ///
    /// Admin claim values keep the top of the order for backward compatibility:
    /// an org that grants "admin" by claim keeps doing so even if a role mapping
    /// also matches. The returned value is a *token* — a legacy literal, an IAM
    /// name, or a role id — that `resolveDesiredOrgRole` turns into a binding.
    func desiredOrganizationRole(provider: OIDCProvider, groupValues: [String]) -> String {
        let adminValues = Set(provider.adminClaimValuesArray)
        if !adminValues.isEmpty && groupValues.contains(where: adminValues.contains) {
            return "admin"
        }
        let claimValues = Set(groupValues)
        for mapping in provider.roleMappingsArray where claimValues.contains(mapping.claimValue) {
            return mapping.roleID.uuidString
        }
        return provider.defaultRole
    }

    /// True when the provider drives the org role from claims at all — either
    /// admin claim values or role mappings are configured. Role reconciliation
    /// is opt-in on this being true, so a provider that maps only group
    /// memberships never touches anyone's role.
    func mapsOrganizationRole(_ provider: OIDCProvider) -> Bool {
        !(provider.adminClaimValuesArray.isEmpty && provider.roleMappingsArray.isEmpty)
    }

    /// Resolve the claim-driven role token to a concrete org membership role
    /// and binding, scoped to the organization (issue #611).
    ///
    /// Resolution is lenient: a provider whose mapping names a role that was
    /// since deleted or moved out of scope must not block the login. On failure
    /// it falls back to the provider's default role, then to bare membership —
    /// mirroring how group-membership sync skips a vanished group rather than
    /// failing. Provider config is validated at write time, so this is the rare
    /// after-the-fact path.
    func resolveDesiredOrgRole(
        provider: OIDCProvider, organizationID: UUID, groupValues: [String]
    ) async -> MemberRoleResolver.ResolvedOrgRole {
        let raw = desiredOrganizationRole(provider: provider, groupValues: groupValues)
        do {
            return try await MemberRoleResolver.resolveOrganizationRole(
                raw, organizationID: organizationID, on: db)
        } catch {
            logger.warning(
                "OIDC role mapping did not resolve; falling back to the provider default role",
                metadata: [
                    "organization_id": .string(organizationID.uuidString),
                    "requested_role": .string(raw),
                    "error": .string(String(describing: error)),
                ])
            if raw != provider.defaultRole,
                let fallback = try? await MemberRoleResolver.resolveOrganizationRole(
                    provider.defaultRole, organizationID: organizationID, on: db)
            {
                return fallback
            }
            return MemberRoleResolver.ResolvedOrgRole(
                storedRole: "member", bindingRoleID: nil, actions: [], label: "member")
        }
    }
}
