import Fluent
import Foundation
import Testing
import Vapor
import VaporTesting

@testable import App

/// The authored-policy API (`/api/iam/policies`, issue #606) and the way an
/// authored permit/forbid flows through the real Cedar evaluator.
///
/// The real engine stays in place, like `RoleEndpointTests`: containment,
/// effect derivation, and the compile check are half of what these routes
/// promise, and a rejection this suite asserts on is the rejection production
/// makes. Decision recording is on so the authorizer tests can read back the
/// tier an authored policy produces.
@Suite("Policy Endpoint Tests", .serialized)
final class PolicyEndpointTests {

    private struct Fixture {
        let user: User
        let token: String
        let org: Organization
        let project: Project
    }

    private func withApp(
        _ test: (Application, Fixture) async throws -> Void
    ) async throws {
        let app = try await Application.makeForTesting()
        do {
            try await configure(app)
            try await app.autoMigrate()
            // The authorizer tests read back the recorded decision's tier.
            app.iamDecisionLogConfig.recordDecisions = true

            let builder = TestDataBuilder(db: app.db)
            let user = try await builder.createUser(
                username: "policyuser", email: "policy@example.com", displayName: "Policy User")
            let org = try await builder.createOrganization(name: "Policy Org")
            try await builder.addUserToOrganization(user: user, organization: org, role: "admin")
            user.currentOrganizationId = org.id
            try await user.save(on: app.db)
            let project = try await builder.createProject(
                name: "Policy Project", description: "d", organization: org)

            let token = try await user.generateAPIKey(on: app.db)
            try await test(app, Fixture(user: user, token: token, org: org, project: project))
        } catch {
            try await app.shutdownForTesting()
            throw error
        }
        try await app.shutdownForTesting()
    }

    // MARK: - Cedar text helpers

    /// A permit granting `action` to a specific user, scoped to a project. Ids
    /// are lowercased so the literals match the entity slice at evaluation.
    private func permitText(user: UUID, action: String, project: UUID) -> String {
        """
        permit (
            principal == User::"\(user.uuidString.lowercased())",
            action == Action::"\(action)",
            resource in Project::"\(project.uuidString.lowercased())"
        );
        """
    }

    private func forbidText(user: UUID, action: String, project: UUID) -> String {
        """
        forbid (
            principal == User::"\(user.uuidString.lowercased())",
            action == Action::"\(action)",
            resource in Project::"\(project.uuidString.lowercased())"
        );
        """
    }

    private func createBody(
        name: String, ownerType: IAMRoleOwnerType, ownerId: UUID, cedarText: String, enabled: Bool? = nil
    ) -> PolicyController.CreatePolicyRequest {
        PolicyController.CreatePolicyRequest(
            name: name, description: "test policy", ownerType: ownerType, ownerId: ownerId,
            cedarText: cedarText, enabled: enabled, id: nil)
    }

    private func createPolicy(
        _ body: PolicyController.CreatePolicyRequest, token: String, on app: Application
    ) async throws -> PolicyController.PolicyDTO {
        var created: PolicyController.PolicyDTO?
        try await app.test(
            .POST, "/api/iam/policies",
            beforeRequest: { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: token)
                try req.content.encode(body)
            },
            afterResponse: { res in
                #expect(res.status == .created, "\(res.status): \(res.body.string)")
                created = try res.content.decode(PolicyController.PolicyDTO.self)
            })
        guard let created else { throw Abort(.internalServerError, reason: "policy was not created") }
        return created
    }

    /// Insert a policy straight through the store (no HTTP gate, so no decision
    /// rows) and bump the version — the way the authorizer tests stage a policy
    /// before rebuilding the compiled set.
    @discardableResult
    private func insertPolicy(
        _ app: Application, name: String, ownerType: IAMRoleOwnerType, ownerID: UUID,
        cedarText: String, enabled: Bool = true
    ) async throws -> IAMPolicy {
        let id = UUID()
        let prepared = try await PolicyStore.prepare(
            id: id, cedarText: cedarText, ownerType: ownerType, ownerID: ownerID,
            engine: app.cedarEngine, on: app.db)
        return try await PolicySetVersionService.withPolicySetChange(on: app.db) { db in
            let policy = try await PolicyStore.create(
                id: id, name: name, description: nil, ownerType: ownerType, ownerID: ownerID,
                prepared: prepared, createdBy: nil, enabled: enabled, on: db)
            try await PolicySetVersionService.bump(reason: "test policy: \(name)", on: db)
            return policy
        }
    }

    private func check(
        _ app: Application, user: User, permission: String, resourceType: String, resourceID: String
    ) async throws -> Bool {
        try await IAMAuthorizer.checkLegacyVocabulary(
            userID: user.id!, permission: permission, resourceType: resourceType, resourceID: resourceID,
            context: IAMCheckContext(path: "/api/vms", method: "GET", requestID: "policy-test"),
            state: nil, app: app, db: app.db)
    }

    private func onlyDecision(_ app: Application) async throws -> IAMDecisionLog {
        var entries: [IAMDecisionLog] = []
        for _ in 0..<200 {
            entries = try await IAMDecisionLog.query(on: app.db).all()
            if !entries.isEmpty { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(entries.count == 1)
        return try #require(entries.first)
    }

    // MARK: - Create + containment

    @Test("Creating a policy derives its effect and bumps the version")
    func createDerivesEffectAndBumps() async throws {
        try await withApp { app, fixture in
            let before = try await PolicySetVersionService.current(on: app.db)

            let policy = try await createPolicy(
                createBody(
                    name: "allow-read", ownerType: .project, ownerId: fixture.project.id!,
                    cedarText: permitText(
                        user: fixture.user.id!, action: "vm:read", project: fixture.project.id!)),
                token: fixture.token, on: app)

            #expect(policy.effect == .permit)
            #expect(policy.ownerType == .project)
            #expect(policy.enabled)

            let after = try await PolicySetVersionService.current(on: app.db)
            #expect(after == before + 1)
        }
    }

    @Test("A forbid policy is stored with effect forbid")
    func forbidEffectDerived() async throws {
        try await withApp { app, fixture in
            let policy = try await createPolicy(
                createBody(
                    name: "deny-delete", ownerType: .organization, ownerId: fixture.org.id!,
                    cedarText: forbidText(
                        user: fixture.user.id!, action: "vm:delete", project: fixture.project.id!)),
                token: fixture.token, on: app)
            #expect(policy.effect == .forbid)
            #expect(policy.ownerType == .organization)
        }
    }

    @Test("An org-owned policy may be scoped to a project inside the org")
    func containmentAcceptsSubtree() async throws {
        try await withApp { app, fixture in
            let policy = try await createPolicy(
                createBody(
                    name: "org-scoped-to-project", ownerType: .organization, ownerId: fixture.org.id!,
                    cedarText: permitText(
                        user: fixture.user.id!, action: "vm:read", project: fixture.project.id!)),
                token: fixture.token, on: app)
            #expect(policy.effect == .permit)
        }
    }

    @Test("A policy scoped outside its owner's subtree is a 400")
    func containmentRejectsForeignSubtree() async throws {
        try await withApp { app, fixture in
            // A second project under the same org — a sibling of the owner.
            let sibling = try await TestDataBuilder(db: app.db).createProject(
                name: "Sibling", description: "d", organization: fixture.org)
            let before = try await PolicySetVersionService.current(on: app.db)

            try await app.test(
                .POST, "/api/iam/policies",
                beforeRequest: { req in
                    req.headers.bearerAuthorization = BearerAuthorization(token: fixture.token)
                    try req.content.encode(
                        self.createBody(
                            name: "trespass", ownerType: .project, ownerId: fixture.project.id!,
                            cedarText: self.permitText(
                                user: fixture.user.id!, action: "vm:read", project: sibling.id!)))
                },
                afterResponse: { res in
                    #expect(res.status == .badRequest)
                    #expect(res.body.string.contains("not inside its owner"))
                })

            let stored = try await IAMPolicy.query(on: app.db).count()
            #expect(stored == 0)
            let after = try await PolicySetVersionService.current(on: app.db)
            #expect(after == before)
        }
    }

    @Test("A project-owned policy cannot reach the org above it")
    func containmentRejectsUpward() async throws {
        try await withApp { app, fixture in
            try await app.test(
                .POST, "/api/iam/policies",
                beforeRequest: { req in
                    req.headers.bearerAuthorization = BearerAuthorization(token: fixture.token)
                    try req.content.encode(
                        self.createBody(
                            name: "reach-up", ownerType: .project, ownerId: fixture.project.id!,
                            cedarText: """
                                permit (
                                    principal,
                                    action == Action::"vm:read",
                                    resource in Organization::"\(fixture.org.id!.uuidString.lowercased())"
                                );
                                """))
                },
                afterResponse: { res in
                    #expect(res.status == .badRequest)
                    #expect(res.body.string.contains("not inside its owner"))
                })
        }
    }

    @Test("A policy with no concrete resource scope is a 400")
    func unscopedResourceRejected() async throws {
        try await withApp { app, fixture in
            try await app.test(
                .POST, "/api/iam/policies",
                beforeRequest: { req in
                    req.headers.bearerAuthorization = BearerAuthorization(token: fixture.token)
                    try req.content.encode(
                        self.createBody(
                            name: "unscoped", ownerType: .project, ownerId: fixture.project.id!,
                            cedarText: "permit (principal, action == Action::\"vm:read\", resource);"))
                },
                afterResponse: { res in
                    #expect(res.status == .badRequest)
                    #expect(res.body.string.contains("resource scope"))
                })
        }
    }

    @Test("Unparseable Cedar text is a 400")
    func unparseableRejected() async throws {
        try await withApp { app, fixture in
            try await app.test(
                .POST, "/api/iam/policies",
                beforeRequest: { req in
                    req.headers.bearerAuthorization = BearerAuthorization(token: fixture.token)
                    try req.content.encode(
                        self.createBody(
                            name: "broken", ownerType: .project, ownerId: fixture.project.id!,
                            cedarText: "this is not cedar"))
                },
                afterResponse: { res in
                    #expect(res.status == .badRequest)
                })
        }
    }

    @Test("Managing policies requires admin over the owner")
    func nonAdminForbidden() async throws {
        try await withApp { app, fixture in
            let member = try await TestDataBuilder(db: app.db).createUser(
                username: "policy-member", email: "policy-member@example.com")
            try await TestDataBuilder(db: app.db).addUserToOrganization(
                user: member, organization: fixture.org, role: "member")
            let memberToken = try await member.generateAPIKey(on: app.db)

            try await app.test(
                .POST, "/api/iam/policies",
                beforeRequest: { req in
                    req.headers.bearerAuthorization = BearerAuthorization(token: memberToken)
                    try req.content.encode(
                        self.createBody(
                            name: "not-allowed", ownerType: .project, ownerId: fixture.project.id!,
                            cedarText: self.permitText(
                                user: member.id!, action: "vm:read", project: fixture.project.id!)))
                },
                afterResponse: { res in
                    #expect(res.status == .forbidden)
                })

            let stored = try await IAMPolicy.query(on: app.db).count()
            #expect(stored == 0)
        }
    }

    // MARK: - Update / enable-disable / delete

    @Test("Editing a policy's text bumps the version and re-derives the effect")
    func updateRewritesAndBumps() async throws {
        try await withApp { app, fixture in
            let policy = try await createPolicy(
                createBody(
                    name: "editable", ownerType: .project, ownerId: fixture.project.id!,
                    cedarText: permitText(
                        user: fixture.user.id!, action: "vm:read", project: fixture.project.id!)),
                token: fixture.token, on: app)
            let before = try await PolicySetVersionService.current(on: app.db)

            try await app.test(
                .PATCH, "/api/iam/policies/\(policy.id)",
                beforeRequest: { req in
                    req.headers.bearerAuthorization = BearerAuthorization(token: fixture.token)
                    try req.content.encode(
                        PolicyController.UpdatePolicyRequest(
                            name: "renamed", description: nil,
                            cedarText: self.forbidText(
                                user: fixture.user.id!, action: "vm:read", project: fixture.project.id!),
                            enabled: nil))
                },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    let updated = try res.content.decode(PolicyController.PolicyDTO.self)
                    #expect(updated.name == "renamed")
                    #expect(updated.effect == .forbid)
                })

            let after = try await PolicySetVersionService.current(on: app.db)
            #expect(after == before + 1)
        }
    }

    @Test("Disabling a policy leaves the row but drops it from the compiled set")
    func disableKeepsRowDropsFromSet() async throws {
        try await withApp { app, fixture in
            let policy = try await createPolicy(
                createBody(
                    name: "toggleable", ownerType: .project, ownerId: fixture.project.id!,
                    cedarText: permitText(
                        user: fixture.user.id!, action: "vm:read", project: fixture.project.id!)),
                token: fixture.token, on: app)

            try await app.test(
                .PATCH, "/api/iam/policies/\(policy.id)",
                beforeRequest: { req in
                    req.headers.bearerAuthorization = BearerAuthorization(token: fixture.token)
                    try req.content.encode(
                        PolicyController.UpdatePolicyRequest(
                            name: nil, description: nil, cedarText: nil, enabled: false))
                },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    let decoded = try res.content.decode(PolicyController.PolicyDTO.self)
                    #expect(decoded.enabled == false)
                })

            // Still stored, but the compiled set skips disabled rows.
            let stored = try await IAMPolicy.query(on: app.db).count()
            #expect(stored == 1)
            let version = try await PolicySetVersionService.current(on: app.db)
            await app.cedarPolicySet.rebuild(version: version, on: app.db)
            let built = try #require(await app.cedarPolicySet.current)
            #expect(built.authoredPolicyCount == 0)
        }
    }

    @Test("Deleting a policy removes it and bumps the version")
    func deleteRemovesAndBumps() async throws {
        try await withApp { app, fixture in
            let policy = try await createPolicy(
                createBody(
                    name: "temporary", ownerType: .project, ownerId: fixture.project.id!,
                    cedarText: permitText(
                        user: fixture.user.id!, action: "vm:read", project: fixture.project.id!)),
                token: fixture.token, on: app)
            let afterCreate = try await PolicySetVersionService.current(on: app.db)

            try await app.test(
                .DELETE, "/api/iam/policies/\(policy.id)",
                beforeRequest: { req in
                    req.headers.bearerAuthorization = BearerAuthorization(token: fixture.token)
                },
                afterResponse: { res in
                    #expect(res.status == .noContent)
                })

            let stored = try await IAMPolicy.query(on: app.db).count()
            #expect(stored == 0)
            let after = try await PolicySetVersionService.current(on: app.db)
            #expect(after == afterCreate + 1)
        }
    }

    @Test("Validate compiles and containment-checks without saving")
    func validateWithoutSaving() async throws {
        try await withApp { app, fixture in
            try await app.test(
                .POST, "/api/iam/policies/validate",
                beforeRequest: { req in
                    req.headers.bearerAuthorization = BearerAuthorization(token: fixture.token)
                    try req.content.encode(
                        PolicyController.ValidatePolicyRequest(
                            ownerType: .project, ownerId: fixture.project.id!,
                            cedarText: self.forbidText(
                                user: fixture.user.id!, action: "vm:read", project: fixture.project.id!),
                            id: nil))
                },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    let decoded = try res.content.decode(PolicyController.ValidatePolicyResponse.self)
                    #expect(decoded.effect == .forbid)
                })

            // Nothing stored, no version bump paths hit.
            let stored = try await IAMPolicy.query(on: app.db).count()
            #expect(stored == 0)
        }
    }

    // MARK: - End-to-end through the authorizer

    @Test("An authored permit grants an action with no role behind it")
    func authoredPermitGrants() async throws {
        try await withApp { app, fixture in
            let builder = TestDataBuilder(db: app.db)
            let subject = try await builder.createUser(
                username: "grantee", email: "grantee@example.com")
            try await builder.addUserToOrganization(user: subject, organization: fixture.org, role: "member")
            let vm = try await builder.createVM(name: "granted-vm", project: fixture.project)

            try await insertPolicy(
                app, name: "grant-read", ownerType: .project, ownerID: fixture.project.id!,
                cedarText: permitText(user: subject.id!, action: "vm:read", project: fixture.project.id!))

            let version = try await PolicySetVersionService.current(on: app.db)
            await app.cedarPolicySet.rebuild(version: version, on: app.db)

            let allowed = try await check(
                app, user: subject, permission: "read", resourceType: "virtual_machine",
                resourceID: vm.id!.uuidString)
            #expect(allowed)

            let entry = try await onlyDecision(app)
            #expect(entry.cedarDecision == "allow")
            #expect(entry.tier == "policy")
            #expect(entry.determiningPolicies.allSatisfy { $0.hasPrefix("policy-") })
            #expect(entry.policyVersion == version)
        }
    }

    @Test("An authored forbid ceilings a role grant and is attributed to the policy tier")
    func authoredForbidCeilingsGrant() async throws {
        try await withApp { app, fixture in
            let builder = TestDataBuilder(db: app.db)
            let subject = try await builder.createUser(
                username: "ceilinged", email: "ceilinged@example.com")
            try await builder.addUserToOrganization(user: subject, organization: fixture.org, role: "member")
            let vm = try await builder.createVM(name: "ceilinged-vm", project: fixture.project)

            // A role grant that would allow the read…
            try await RoleBindingService.grant(
                principalType: .user, principalID: subject.id!, role: .viewer,
                nodeType: .project, nodeID: fixture.project.id!, createdBy: nil, on: app.db)
            // …ceilinged by an authored forbid.
            try await insertPolicy(
                app, name: "no-read", ownerType: .project, ownerID: fixture.project.id!,
                cedarText: forbidText(user: subject.id!, action: "vm:read", project: fixture.project.id!))

            let version = try await PolicySetVersionService.current(on: app.db)
            await app.cedarPolicySet.rebuild(version: version, on: app.db)

            let allowed = try await check(
                app, user: subject, permission: "read", resourceType: "virtual_machine",
                resourceID: vm.id!.uuidString)
            #expect(!allowed)

            let entry = try await onlyDecision(app)
            #expect(entry.cedarDecision == "deny")
            #expect(entry.tier == "policy")
            #expect(entry.determiningPolicies.allSatisfy { $0.hasPrefix("policy-") })
        }
    }

    // MARK: - who-can honesty

    @Test("who-can reports authored policies in scope and flags the caveat")
    func whoCanReportsPoliciesAndCaveat() async throws {
        try await withApp { app, fixture in
            let builder = TestDataBuilder(db: app.db)
            let vm = try await builder.createVM(name: "who-vm", project: fixture.project)

            try await insertPolicy(
                app, name: "wc-permit", ownerType: .project, ownerID: fixture.project.id!,
                cedarText: permitText(user: fixture.user.id!, action: "vm:read", project: fixture.project.id!))

            try await app.test(
                .POST, "/api/authorization/who-can",
                beforeRequest: { req in
                    req.headers.bearerAuthorization = BearerAuthorization(token: fixture.token)
                    try req.content.encode(
                        AuthorizationController.WhoCanRequest(
                            resourceType: "virtual_machine", resourceId: vm.id!.uuidString, action: "vm:read"))
                },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    let decoded = try res.content.decode(AuthorizationController.WhoCanResponse.self)
                    #expect(decoded.authoredPolicyCaveat)
                    #expect(decoded.authoredPolicies.map(\.name) == ["wc-permit"])
                    let match = try #require(decoded.authoredPolicies.first)
                    #expect(match.effect == .permit)
                    #expect(match.actionMatch == .matches)
                })
        }
    }

    @Test("who-can does not report a policy scoped to a different subtree")
    func whoCanExcludesForeignSubtree() async throws {
        try await withApp { app, fixture in
            let builder = TestDataBuilder(db: app.db)
            let sibling = try await builder.createProject(
                name: "WC Sibling", description: "d", organization: fixture.org)
            let vm = try await builder.createVM(name: "wc-scoped-vm", project: fixture.project)

            // Owned by the org (so it is in scope by ownership) but scoped to a
            // sibling project the queried VM is not under.
            try await insertPolicy(
                app, name: "sibling-only", ownerType: .organization, ownerID: fixture.org.id!,
                cedarText: permitText(user: fixture.user.id!, action: "vm:read", project: sibling.id!))

            try await app.test(
                .POST, "/api/authorization/who-can",
                beforeRequest: { req in
                    req.headers.bearerAuthorization = BearerAuthorization(token: fixture.token)
                    try req.content.encode(
                        AuthorizationController.WhoCanRequest(
                            resourceType: "virtual_machine", resourceId: vm.id!.uuidString, action: "vm:read"))
                },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    let decoded = try res.content.decode(AuthorizationController.WhoCanResponse.self)
                    #expect(decoded.authoredPolicies.isEmpty)
                    #expect(!decoded.authoredPolicyCaveat)
                })
        }
    }
}
