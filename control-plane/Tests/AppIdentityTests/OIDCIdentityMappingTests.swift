import ControlPlanePostgres
import Foundation
import Testing
import Vapor
import VaporTesting

import AppTestSupport
@testable import App

/// Tests for OIDC authorization & identity mapping (issue #363): group/role
/// claim extraction, JIT provisioning with a configurable default role, IdP
/// group membership sync, org role reconciliation, and SCIM ↔ OIDC
/// convergence. Drives `OIDCIdentityService` directly (no fake IdP needed —
/// the service starts after ID-token validation) and asserts on the DB state:
/// organization membership rows, group pivot rows, and `role_bindings`.
@Suite("OIDC Identity Mapping Tests", .serialized)
final class OIDCIdentityMappingTests {

    // MARK: - Claim extraction (pure)

    /// Builds an unsigned JWT-shaped token with the given payload; the
    /// extractor only reads the payload segment.
    private func fakeToken(payload: [String: Any]) throws -> String {
        let payloadData = try JSONSerialization.data(withJSONObject: payload)
        let payloadPart = payloadData.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "eyJhbGciOiJSUzI1NiJ9.\(payloadPart).c2ln"
    }

    @Test("extractGroupClaimValues reads a string array claim")
    func extractArrayClaim() throws {
        let token = try fakeToken(payload: ["sub": "u1", "groups": ["engineering", "admins"]])
        let values = try OIDCIdentityService.extractGroupClaimValues(idToken: token, claim: "groups")
        #expect(values == ["engineering", "admins"])
    }

    @Test("extractGroupClaimValues wraps a single string claim")
    func extractSingleStringClaim() throws {
        let token = try fakeToken(payload: ["roles": "admin"])
        let values = try OIDCIdentityService.extractGroupClaimValues(idToken: token, claim: "roles")
        #expect(values == ["admin"])
    }

    @Test("extractGroupClaimValues ignores non-string entries and missing claims")
    func extractMixedAndMissing() throws {
        let mixed = try fakeToken(payload: ["groups": ["a", 42, ["nested"], "b"]])
        let mixedValues = try OIDCIdentityService.extractGroupClaimValues(idToken: mixed, claim: "groups")
        #expect(mixedValues == ["a", "b"])

        let missing = try fakeToken(payload: ["sub": "u1"])
        let missingValues = try OIDCIdentityService.extractGroupClaimValues(idToken: missing, claim: "groups")
        #expect(missingValues.isEmpty)

        let null = try fakeToken(payload: ["groups": NSNull()])
        #expect(try OIDCIdentityService.extractGroupClaimValues(idToken: null, claim: "groups").isEmpty)

        let object = try fakeToken(payload: ["groups": ["unexpected": "shape"]])
        #expect(try OIDCIdentityService.extractGroupClaimValues(idToken: object, claim: "groups").isEmpty)
    }

    @Test("extractGroupClaimValues rejects malformed tokens")
    func extractMalformed() {
        #expect(throws: Abort.self) {
            _ = try OIDCIdentityService.extractGroupClaimValues(idToken: "not-a-jwt", claim: "groups")
        }
    }

    // MARK: - Harness

    /// Boots a test app with an org and a provider configured for claim
    /// mapping.
    private func withIdentityTestApp(
        groupsClaim: String? = "groups",
        groupMappings: (TestDataBuilder, Organization) async throws -> [OIDCGroupMapping] = { _, _ in [] },
        adminClaimValues: [String] = [],
        roleMappings: (TestDataBuilder, Organization) async throws -> [OIDCRoleMapping] = { _, _ in [] },
        defaultRoleID: (TestDataBuilder, Organization) async throws -> UUID? = { _, _ in nil },
        _ test: (Application, Organization, OIDCProviderSnapshot, OIDCIdentityService) async throws -> Void
    ) async throws {
        let app = try await Application.makeForTesting()

        do {
            try await configure(app)

            let builder = TestDataBuilder(app: app)
            let org = try await builder.createOrganization(name: "IdP Org")

            let provider = try await app.oidcProvidersPersistence.create(OIDCProviderWrite(
                organizationID: org.id!,
                name: "Test IdP",
                clientID: "client",
                encryptedClientSecret: "secret",
                groupsClaim: groupsClaim,
                groupMappings: try await groupMappings(builder, org).map(\.persistenceValue),
                adminClaimValues: adminClaimValues,
                roleMappings: try await roleMappings(builder, org).map(\.persistenceValue),
                defaultRoleID: try await defaultRoleID(builder, org)
            ))

            let service = OIDCIdentityService(
                providers: app.oidcProvidersPersistence,
                groups: app.groupsPersistence,
                externalIDs: app.scimExternalIDsPersistence,
                users: app.userDirectoryPersistence,
                hierarchy: app.hierarchyPersistence,
                iam: app.iamPersistence,
                logger: app.logger
            )
            try await test(app, org, provider, service)

        } catch {
            try await app.shutdownForTesting()
            throw error
        }

        try await app.shutdownForTesting()
    }

    private func userInfo(
        subject: String = "sub-1", email: String? = "jit@example.com", emailVerified: Bool = true
    ) -> OIDCUserInfo {
        OIDCUserInfo(
            subject: subject, email: email, emailVerified: emailVerified,
            name: "JIT User", preferredUsername: "jituser-\(subject)")
    }

    /// Create an org-owned custom role bindable at `orgID`.
    private func makeOrgRole(
        name: String, orgID: UUID, actions: [String] = ["vm:read"], on db: PostgresStoreContext
    ) async throws -> LegacyIAMRoleRecord {
        let id = UUID()
        return try await RoleStore.insertLegacy(IAMRoleSnapshot(
            id: id, name: name, description: nil,
            ownerType: IAMRoleOwnerType.organization.rawValue, ownerID: orgID,
            cedarText: RoleDescriptor.canonicalPermitText(id: id, actions: actions),
            actions: actions, managed: false, createdBy: nil), on: db)
    }

    private func orgBindingRoles(_ userID: UUID, _ orgID: UUID, on db: PostgresStoreContext) async throws -> [UUID] {
        try await LegacyRoleBindingStore.bindings(
            principalType: IAMPrincipalType.user.rawValue,
            principalID: userID,
            nodeType: IAMNodeType.organization.rawValue,
            nodeID: orgID,
            on: db)
            .map(\.roleID)
    }

    // MARK: - JIT provisioning

    @Test("JIT user gets the provider's default role and an org role binding")
    func jitUsesDefaultRole() async throws {
        try await withIdentityTestApp(defaultRoleID: { _, _ in IAMRole.admin.seededID }) {
            app, org, provider, service in
            let user = try await service.resolveUser(
                userInfo: userInfo(), provider: provider, organization: org, groupValues: [])

            let membership = try await OrganizationMembershipStore.membership(
                userID: user.id!, organizationID: org.id!, on: app.testPostgres)
            #expect(membership?.roleID == IAMRole.admin.seededID)

            // The admin role binding is written alongside the membership row —
            // without it the new user authenticates but every check denies.
            let bindings = try await LegacyRoleBindingStore.bindings(
                principalType: IAMPrincipalType.user.rawValue,
                principalID: user.id!,
                nodeType: IAMNodeType.organization.rawValue,
                nodeID: org.id!,
                on: app.testPostgres)
            #expect(bindings.map(\.roleID) == [IAMRole.admin.seededID])
        }
    }

    @Test("JIT user with a matching admin claim value is provisioned as admin")
    func jitAdminClaimValue() async throws {
        try await withIdentityTestApp(adminClaimValues: ["strato-admins"]) {
            app, org, provider, service in
            let admin = try await service.resolveUser(
                userInfo: userInfo(subject: "sub-a", email: "a@example.com"),
                provider: provider, organization: org, groupValues: ["strato-admins", "other"])
            let adminMembership = try await OrganizationMembershipStore.membership(
                userID: admin.id!, organizationID: org.id!, on: app.testPostgres)
            #expect(adminMembership?.roleID == IAMRole.admin.seededID)

            let member = try await service.resolveUser(
                userInfo: userInfo(subject: "sub-b", email: "b@example.com"),
                provider: provider, organization: org, groupValues: ["other"])
            let memberMembership = try await OrganizationMembershipStore.membership(
                userID: member.id!, organizationID: org.id!, on: app.testPostgres)
            #expect(memberMembership?.roleID == nil)
        }
    }

    // MARK: - SCIM ↔ OIDC convergence

    @Test("OIDC subject matching a SCIM externalId resolves to the SCIM user and links the provider")
    func scimExternalIDLinksUser() async throws {
        try await withIdentityTestApp { app, org, provider, service in
            let scimUser = User(
                username: "scimuser", email: "scim@example.com", displayName: "SCIM User",
                isSystemAdmin: false, scimProvisioned: true, scimActive: true)
            try await scimUser.save(on: app.testPostgres)
            try await TestDataBuilder(app: app).addUserToOrganization(user: scimUser, organization: org)
            _ = try await app.scimExternalIDsPersistence.assign(
                externalID: "idp-sub-42", to: scimUser.id!,
                resourceType: .user, organizationID: org.id!)

            let resolved = try await service.resolveUser(
                userInfo: userInfo(subject: "idp-sub-42", email: "different@example.com"),
                provider: provider, organization: org, groupValues: [])

            #expect(resolved.id == scimUser.id)
            #expect(resolved.oidcSubject == "idp-sub-42")
            #expect(resolved.oidcProviderID == provider.id)

            // No duplicate user was created for the identity.
            let userCount = try await User.count(on: app.testPostgres)
            #expect(userCount == 1)

            // A later login resolves via the OIDC link directly.
            let again = try await service.resolveUser(
                userInfo: userInfo(subject: "idp-sub-42", email: nil),
                provider: provider, organization: org, groupValues: [])
            #expect(again.id == scimUser.id)
        }
    }

    @Test("SCIM externalId matching is skipped when the org has multiple providers")
    func scimExternalIDRequiresSoleProvider() async throws {
        try await withIdentityTestApp { app, org, provider, service in
            // Second provider: subjects are no longer attributable to one
            // IdP, so a sub match must not log the caller into the SCIM
            // user's account.
            let other = try await app.oidcProvidersPersistence.create(OIDCProviderWrite(
                organizationID: org.id!,
                name: "Other IdP",
                clientID: "other",
                encryptedClientSecret: "secret"
            ))

            let scimUser = User(
                username: "scimuser", email: "scim@example.com", displayName: "SCIM User",
                isSystemAdmin: false, scimProvisioned: true, scimActive: true)
            try await scimUser.save(on: app.testPostgres)
            try await TestDataBuilder(app: app).addUserToOrganization(user: scimUser, organization: org)
            _ = try await app.scimExternalIDsPersistence.assign(
                externalID: "idp-sub-42", to: scimUser.id!,
                resourceType: .user, organizationID: org.id!)

            let resolved = try await service.resolveUser(
                userInfo: userInfo(subject: "idp-sub-42", email: "different@example.com"),
                provider: provider, organization: org, groupValues: [])

            // JIT-provisioned as a fresh user, not linked to the SCIM record.
            #expect(resolved.id != scimUser.id)
            let userCount = try await User.count(on: app.testPostgres)
            #expect(userCount == 2)

            // A verified email match still converges the identities.
            let byEmail = try await service.resolveUser(
                userInfo: userInfo(subject: "sub-via-email", email: "scim@example.com"),
                provider: other, organization: org, groupValues: [])
            #expect(byEmail.id == scimUser.id)
        }
    }

    @Test("An unverified email does not link to or take over an existing account")
    func unverifiedEmailDoesNotLink() async throws {
        try await withIdentityTestApp { app, org, provider, service in
            let existing = User(
                username: "victim", email: "victim@example.com", displayName: "Victim",
                isSystemAdmin: false)
            try await existing.save(on: app.testPostgres)
            try await TestDataBuilder(app: app).addUserToOrganization(user: existing, organization: org)

            // Same email but the IdP has NOT verified it: linking is refused, and
            // because the address is already taken the login is denied outright
            // (fail closed) rather than adopting or provisioning onto that account.
            await #expect(throws: (any Error).self) {
                _ = try await service.resolveUser(
                    userInfo: userInfo(subject: "attacker-sub", email: "victim@example.com", emailVerified: false),
                    provider: provider, organization: org, groupValues: [])
            }

            // The victim's account is untouched: no new identity was bound to it.
            let victim = try await User.find(existing.id!, on: app.testPostgres)
            #expect(victim?.oidcProviderID == nil)
        }
    }

    @Test("SCIM-deactivated users are denied login")
    func scimDeactivatedDenied() async throws {
        try await withIdentityTestApp { app, org, provider, service in
            let deactivated = User(
                username: "gone", email: "gone@example.com", displayName: "Gone",
                isSystemAdmin: false, scimProvisioned: true, scimActive: false)
            try await deactivated.save(on: app.testPostgres)

            #expect(throws: Abort.self) {
                try service.enforceSCIMActive(deactivated)
            }

            let active = User(
                username: "here", email: "here@example.com", displayName: "Here",
                isSystemAdmin: false, scimProvisioned: true, scimActive: true)
            try service.enforceSCIMActive(active)

            // Non-SCIM users are unaffected by the flag.
            let local = User(
                username: "local", email: "local@example.com", displayName: "Local",
                isSystemAdmin: false, scimProvisioned: false, scimActive: false)
            try service.enforceSCIMActive(local)
        }
    }

    // MARK: - Group membership sync

    @Test("Mapped claim value adds the user to the group")
    func groupSyncAdds() async throws {
        var engineeringID: UUID!
        try await withIdentityTestApp(groupMappings: { builder, org in
            let engineering = try await builder.createGroup(
                name: "Engineering", description: "eng", organization: org)
            engineeringID = engineering.id!
            return [OIDCGroupMapping(claimValue: "idp-engineering", groupID: engineering.id!)]
        }) { app, org, provider, service in
            let user = try await service.resolveUser(
                userInfo: userInfo(), provider: provider, organization: org, groupValues: [])

            try await service.syncGroupMemberships(
                user: user, provider: provider, organizationID: org.id!,
                groupValues: ["idp-engineering", "unrelated"])

            // The pivot row is what the Cedar evaluator reads for
            // group-derived access.
            let isMember = try await app.groupsPersistence.hasMember(
                userID: user.id!, groupID: engineeringID)
            #expect(isMember)
        }
    }

    @Test("Mapped group absent from claims is removed; unmapped groups are untouched")
    func groupSyncRemovesOnlyMapped() async throws {
        var mappedID: UUID!
        try await withIdentityTestApp(groupMappings: { builder, org in
            let mapped = try await builder.createGroup(
                name: "Mapped", description: "idp-managed", organization: org)
            mappedID = mapped.id!
            return [OIDCGroupMapping(claimValue: "idp-mapped", groupID: mapped.id!)]
        }) { app, org, provider, service in
            let builder = TestDataBuilder(app: app)
            let manual = try await builder.createGroup(
                name: "Manual", description: "manually managed", organization: org)

            let user = try await service.resolveUser(
                userInfo: userInfo(), provider: provider, organization: org, groupValues: [])

            _ = try await app.groupsPersistence.addMembers(
                [user.id!], to: mappedID, organizationID: org.id!)
            try await builder.addUserToGroup(user: user, group: manual)

            // Token no longer carries the mapped claim value.
            try await service.syncGroupMemberships(
                user: user, provider: provider, organizationID: org.id!, groupValues: [])

            let stillMapped = try await app.groupsPersistence.hasMember(
                userID: user.id!, groupID: mappedID)
            #expect(!stillMapped)
            let stillManual = try await app.groupsPersistence.hasMember(
                userID: user.id!, groupID: manual.requireID())
            #expect(stillManual)
        }
    }

    @Test("Clearing groupsClaim disables mapping: no removals or demotions from empty claims")
    func unsetGroupsClaimDisablesMapping() async throws {
        // Mappings and admin claim values remain saved, but the groups claim
        // is cleared — the token never carries values, and that must not be
        // read as "the user lost every mapped group and the admin role".
        var mappedID: UUID!
        try await withIdentityTestApp(
            groupsClaim: nil,
            groupMappings: { builder, org in
                let mapped = try await builder.createGroup(
                    name: "Mapped", description: "idp-managed", organization: org)
                mappedID = mapped.id!
                return [OIDCGroupMapping(claimValue: "idp-mapped", groupID: mapped.id!)]
            },
            adminClaimValues: ["strato-admins"]
        ) { app, org, provider, service in
            let builder = TestDataBuilder(app: app)
            let user = try await builder.createUser(username: "keeper", email: "keeper@example.com")
            try await builder.addUserToOrganization(user: user, organization: org, role: "admin")
            // A second admin, so it's the groupsClaim guard (not the
            // last-admin guard) keeping the role below.
            let other = try await builder.createUser(username: "otheradmin", email: "otheradmin@example.com")
            try await builder.addUserToOrganization(user: other, organization: org, role: "admin")

            _ = try await app.groupsPersistence.addMembers(
                [user.id!], to: mappedID, organizationID: org.id!)

            try await service.syncGroupMemberships(
                user: user, provider: provider, organizationID: org.id!, groupValues: [])
            try await service.reconcileOrganizationRole(
                user: user, provider: provider, organizationID: org.id!, groupValues: [])

            let stillMember = try await app.groupsPersistence.hasMember(
                userID: user.id!, groupID: mappedID)
            #expect(stillMember)
            let membership = try await OrganizationMembershipStore.membership(
                userID: user.id!, organizationID: org.id!, on: app.testPostgres)
            #expect(membership?.roleID == IAMRole.admin.seededID)
        }
    }

    @Test("A user removed from the org gains no group memberships from claims")
    func groupSyncSkipsNonMembers() async throws {
        // Removal from the org deletes the membership row but keeps the
        // OIDC link, so the user still resolves on a later login. Their
        // claims must not re-grant org group memberships (which carry
        // project permissions through group role bindings).
        var mappedID: UUID!
        try await withIdentityTestApp(groupMappings: { builder, org in
            let mapped = try await builder.createGroup(
                name: "Mapped", description: "idp-managed", organization: org)
            mappedID = mapped.id!
            return [OIDCGroupMapping(claimValue: "idp-mapped", groupID: mapped.id!)]
        }) { app, org, provider, service in
            // OIDC-linked user with no membership row for this org.
            let removed = User(
                username: "removed", email: "removed@example.com", displayName: "Removed",
                isSystemAdmin: false, oidcProviderID: provider.id, oidcSubject: "sub-removed")
            try await removed.save(on: app.testPostgres)

            try await service.syncGroupMemberships(
                user: removed, provider: provider, organizationID: org.id!, groupValues: ["idp-mapped"])

            let isMember = try await app.groupsPersistence.hasMember(
                userID: removed.id!, groupID: mappedID)
            #expect(!isMember)
        }
    }

    @Test("Mapping to a deleted group is skipped without failing the login")
    func groupSyncSkipsMissingGroup() async throws {
        try await withIdentityTestApp(groupMappings: { _, _ in
            [OIDCGroupMapping(claimValue: "ghost", groupID: UUID())]
        }) { app, org, provider, service in
            let user = try await service.resolveUser(
                userInfo: userInfo(), provider: provider, organization: org, groupValues: [])
            try await service.syncGroupMemberships(
                user: user, provider: provider, organizationID: org.id!, groupValues: ["ghost"])
        }
    }

    // MARK: - Org role reconciliation

    @Test("Admin claim value promotes an existing member; losing it demotes back")
    func roleReconcilePromoteAndDemote() async throws {
        try await withIdentityTestApp(adminClaimValues: ["strato-admins"]) { app, org, provider, service in
            let builder = TestDataBuilder(app: app)
            // A standing admin so the last-admin guard never trips here.
            let standing = try await builder.createUser(username: "standing", email: "standing@example.com")
            try await builder.addUserToOrganization(user: standing, organization: org, role: "admin")

            let user = try await service.resolveUser(
                userInfo: userInfo(), provider: provider, organization: org, groupValues: [])

            func adminBindingCount() async throws -> Int {
                try await LegacyRoleBindingStore.bindings(
                    principalType: IAMPrincipalType.user.rawValue,
                    principalID: user.id!,
                    roleID: IAMRole.admin.seededID,
                    nodeType: IAMNodeType.organization.rawValue,
                    nodeID: org.id!,
                    on: app.testPostgres).count
            }

            try await service.reconcileOrganizationRole(
                user: user, provider: provider, organizationID: org.id!, groupValues: ["strato-admins"])
            let promoted = try await OrganizationMembershipStore.membership(
                userID: user.id!, organizationID: org.id!, on: app.testPostgres)
            #expect(promoted?.roleID == IAMRole.admin.seededID)

            // The admin binding is written alongside the mirror-row update.
            let bindingsAfterPromotion = try await adminBindingCount()
            #expect(bindingsAfterPromotion == 1)

            try await service.reconcileOrganizationRole(
                user: user, provider: provider, organizationID: org.id!, groupValues: [])
            let demoted = try await OrganizationMembershipStore.membership(
                userID: user.id!, organizationID: org.id!, on: app.testPostgres)
            #expect(demoted?.roleID == nil)

            // Demotion revokes the binding again (bare membership has none).
            let bindingsAfterDemotion = try await adminBindingCount()
            #expect(bindingsAfterDemotion == 0)
        }
    }

    @Test("Role reconciliation is a no-op when no admin claim values are configured")
    func roleReconcileOptIn() async throws {
        try await withIdentityTestApp(adminClaimValues: []) { app, org, provider, service in
            let builder = TestDataBuilder(app: app)
            let user = try await builder.createUser(username: "manual", email: "manual@example.com")
            try await builder.addUserToOrganization(user: user, organization: org, role: "admin")

            try await service.reconcileOrganizationRole(
                user: user, provider: provider, organizationID: org.id!, groupValues: [])

            let membership = try await OrganizationMembershipStore.membership(
                userID: user.id!, organizationID: org.id!, on: app.testPostgres)
            #expect(membership?.roleID == IAMRole.admin.seededID)
        }
    }

    @Test("The organization's last usable admin is never demoted by claim mapping")
    func roleReconcileLastAdminGuard() async throws {
        try await withIdentityTestApp(adminClaimValues: ["strato-admins"]) { app, org, provider, service in
            let builder = TestDataBuilder(app: app)
            let user = try await builder.createUser(username: "lastadmin", email: "last@example.com")
            try await builder.addUserToOrganization(user: user, organization: org, role: "admin")

            // Other admins exist but none can sign in: one disabled by SSF,
            // one deactivated via SCIM. They must not count as available
            // admins, or demoting `user` locks the org out.
            let disabled = try await builder.createUser(username: "ssfdisabled", email: "ssf@example.com")
            try await disabled.replacing(disabledAt: .some(Date())).save(on: app.testPostgres)
            try await builder.addUserToOrganization(user: disabled, organization: org, role: "admin")

            let deactivated = User(
                username: "scimgone", email: "scimgone@example.com", displayName: "Gone",
                isSystemAdmin: false, scimProvisioned: true, scimActive: false)
            try await deactivated.save(on: app.testPostgres)
            try await builder.addUserToOrganization(user: deactivated, organization: org, role: "admin")

            try await service.reconcileOrganizationRole(
                user: user, provider: provider, organizationID: org.id!, groupValues: [])

            let membership = try await OrganizationMembershipStore.membership(
                userID: user.id!, organizationID: org.id!, on: app.testPostgres)
            #expect(membership?.roleID == IAMRole.admin.seededID)

            // With a usable second admin, the demotion proceeds.
            let usable = try await builder.createUser(username: "usableadmin", email: "usable@example.com")
            try await builder.addUserToOrganization(user: usable, organization: org, role: "admin")
            try await service.reconcileOrganizationRole(
                user: user, provider: provider, organizationID: org.id!, groupValues: [])
            let demoted = try await OrganizationMembershipStore.membership(
                userID: user.id!, organizationID: org.id!, on: app.testPostgres)
            #expect(demoted?.roleID == nil)
        }
    }

    // MARK: - Custom-role claim mapping (issue #611)

    @Test("A role mapping provisions a JIT user with the mapped custom role and binds it")
    func jitRoleMappingCustomRole() async throws {
        var auditorID: UUID!
        try await withIdentityTestApp(roleMappings: { builder, org in
            let auditor = try await self.makeOrgRole(name: "auditor", orgID: org.id!, on: builder.db)
            auditorID = auditor.id
            return [OIDCRoleMapping(claimValue: "idp-auditors", roleID: auditor.id)]
        }) { app, org, provider, service in
            let user = try await service.resolveUser(
                userInfo: userInfo(), provider: provider, organization: org,
                groupValues: ["idp-auditors", "unrelated"])

            // Membership metadata and the authoritative binding name the same role id.
            let membership = try await OrganizationMembershipStore.membership(
                userID: user.id!, organizationID: org.id!, on: app.testPostgres)
            #expect(membership?.roleID == auditorID)
            let bindings = try await orgBindingRoles(user.id!, org.id!, on: app.testPostgres)
            #expect(bindings == [auditorID])
        }
    }

    @Test("A custom-role default role provisions and binds that role when no claim matches")
    func jitDefaultRoleCustomRole() async throws {
        var auditorID: UUID!
        try await withIdentityTestApp(defaultRoleID: { builder, org in
            let auditor = try await self.makeOrgRole(name: "auditor", orgID: org.id!, on: builder.db)
            auditorID = auditor.id
            return auditor.id
        }) { app, org, provider, service in
            let user = try await service.resolveUser(
                userInfo: userInfo(), provider: provider, organization: org, groupValues: [])

            let membership = try await OrganizationMembershipStore.membership(
                userID: user.id!, organizationID: org.id!, on: app.testPostgres)
            #expect(membership?.roleID == auditorID)
            let bindings = try await orgBindingRoles(user.id!, org.id!, on: app.testPostgres)
            #expect(bindings == [auditorID])
        }
    }

    @Test("Role mappings drive reconciliation without admin claim values, and reset to default when the claim is lost")
    func reconcileCustomRoleAndBack() async throws {
        var auditorID: UUID!
        try await withIdentityTestApp(roleMappings: { builder, org in
            let auditor = try await self.makeOrgRole(name: "auditor", orgID: org.id!, on: builder.db)
            auditorID = auditor.id
            return [OIDCRoleMapping(claimValue: "idp-auditors", roleID: auditor.id)]
        }) { app, org, provider, service in
            let builder = TestDataBuilder(app: app)
            let user = try await builder.createUser(username: "member1", email: "member1@example.com")
            try await builder.addUserToOrganization(user: user, organization: org, role: "member")

            // Claim present → promoted to the custom role, with a matching binding.
            try await service.reconcileOrganizationRole(
                user: user, provider: provider, organizationID: org.id!, groupValues: ["idp-auditors"])
            var membership = try await OrganizationMembershipStore.membership(
                userID: user.id!, organizationID: org.id!, on: app.testPostgres)
            #expect(membership?.roleID == auditorID)
            #expect(try await orgBindingRoles(user.id!, org.id!, on: app.testPostgres) == [auditorID])

            // Claim lost → reset to the provider default (bare "member"), binding revoked.
            try await service.reconcileOrganizationRole(
                user: user, provider: provider, organizationID: org.id!, groupValues: [])
            membership = try await OrganizationMembershipStore.membership(
                userID: user.id!, organizationID: org.id!, on: app.testPostgres)
            #expect(membership?.roleID == nil)
            #expect(try await orgBindingRoles(user.id!, org.id!, on: app.testPostgres).isEmpty)
        }
    }

    @Test("An admin claim value takes precedence over a matching role mapping")
    func adminClaimBeatsRoleMapping() async throws {
        try await withIdentityTestApp(
            adminClaimValues: ["strato-admins"],
            roleMappings: { builder, org in
                let auditor = try await self.makeOrgRole(name: "auditor", orgID: org.id!, on: builder.db)
                return [OIDCRoleMapping(claimValue: "idp-auditors", roleID: auditor.id)]
            }
        ) { app, org, provider, service in
            // Token carries both the admin claim value and the role-mapped value.
            let user = try await service.resolveUser(
                userInfo: userInfo(), provider: provider, organization: org,
                groupValues: ["strato-admins", "idp-auditors"])

            let membership = try await OrganizationMembershipStore.membership(
                userID: user.id!, organizationID: org.id!, on: app.testPostgres)
            #expect(membership?.roleID == IAMRole.admin.seededID)
            #expect(try await orgBindingRoles(user.id!, org.id!, on: app.testPostgres) == [IAMRole.admin.seededID])
        }
    }

    @Test("A role mapping to a deleted role falls back to the default without failing login")
    func roleMappingToMissingRoleFallsBack() async throws {
        try await withIdentityTestApp(roleMappings: { _, _ in
            [OIDCRoleMapping(claimValue: "idp-auditors", roleID: UUID())]
        }) { app, org, provider, service in
            let user = try await service.resolveUser(
                userInfo: userInfo(), provider: provider, organization: org, groupValues: ["idp-auditors"])

            // Fell back to bare membership; no binding, and no crash.
            let membership = try await OrganizationMembershipStore.membership(
                userID: user.id!, organizationID: org.id!, on: app.testPostgres)
            #expect(membership?.roleID == nil)
            #expect(try await orgBindingRoles(user.id!, org.id!, on: app.testPostgres).isEmpty)
        }
    }
}
