import Foundation
import Testing

@testable import App

/// IAM phase 4 (issue #481): the real Cedar engine behind the `CedarEngine`
/// seam. Phase 3 verified the generated schema, policies, and entity encoding
/// against the `cedar-policy` crate out-of-band; with swift-cedar as a
/// dependency that verification now lives here — including the full
/// (role × action) enumeration, which over a finite action inventory is the
/// role-subsumption check in full, this time through the actual evaluator.
@Suite("Swift Cedar Engine Tests")
struct SwiftCedarEngineTests {

    /// The compiled static set (no guardrails), shared across tests — schema
    /// parse + strict validation runs once. Roles come from the seeded
    /// descriptors, exactly what `RoleRegistrySync` writes to the store.
    private static let compiled: any CedarCompiledPolicySet = {
        do {
            return try SwiftCedarEngine().compile(
                schemaText: CedarSchemaBuilder.schemaText(roles: RoleDescriptor.seededDefaults()),
                policies: CedarPolicyAssembler.staticPolicies(roles: RoleDescriptor.seededDefaults()))
        } catch {
            fatalError("static Cedar set failed to compile: \(error)")
        }
    }()

    /// The role ids the compiled schema declares — what `Built.roleIDs`
    /// carries in production.
    private static let seededRoleIDs = Set(IAMRole.allCases.map(\.seededID))

    private let userID = UUID()

    /// A minimal slice for one check: the principal, the resource (with the
    /// attributes the schema requires), and a grants context carrying at most
    /// one role for the user.
    private func evaluate(
        action: String,
        resourceType: CedarEntityType,
        resourceID: UUID = UUID(),
        role: IAMRole? = nil,
        systemAdmin: Bool = false,
        memberOfOrgs: [UUID] = [],
        resourceAttrs: [String: CedarValue] = [:],
        resourceParents: [CedarEntityUID] = [],
        extraEntities: [CedarEntity] = []
    ) throws -> CedarCheckDecision {
        let principal = CedarEntityUID(type: .user, id: userID)
        let resource = CedarEntityUID(type: resourceType, id: resourceID)

        var attrs = resourceAttrs
        if resourceType == .network, attrs["openToAllUsers"] == nil {
            attrs["openToAllUsers"] = .bool(false)
        }
        if resourceType == .user {
            // `User` is a resource type as well as a principal type, and its
            // schema attributes are required in both roles — the same rule the
            // entity-slice loader follows for a user standing as the resource.
            if attrs["memberOfOrgs"] == nil { attrs["memberOfOrgs"] = .set([]) }
            if attrs["systemAdmin"] == nil { attrs["systemAdmin"] = .bool(false) }
        }

        var entities: [CedarEntity] = [
            CedarEntity(
                uid: principal,
                attrs: [
                    "memberOfOrgs": .set(
                        memberOfOrgs.map { .entity(CedarEntityUID(type: .organization, id: $0)) }),
                    "systemAdmin": .bool(systemAdmin),
                ],
                parents: []),
            CedarEntity(uid: resource, attrs: attrs, parents: resourceParents),
        ]
        entities.append(contentsOf: extraEntities)

        var grants = CedarRoleGrants()
        if let role {
            grants.addUser(userID, roleID: role.seededID)
        }

        return try Self.compiled.authorize(
            principal: principal,
            action: action,
            resource: resource,
            context: .record(["grants": grants.contextValue(roleIDs: Self.seededRoleIDs)]),
            entitiesJSON: CedarText.json(entities))
    }

    @Test("The generated schema and static policies compile and validate strictly")
    func compiles() throws {
        #expect(Self.compiled is SwiftCedarEngine.Compiled)
    }

    @Test("Every (role, action) pair evaluates exactly as the registry says")
    func roleActionEnumeration() throws {
        for role in IAMRole.allCases {
            let granted = IAMRoleRegistry.actions(for: role)
            for action in IAMRoleRegistry.allActions.sorted() {
                // The first appliesTo type is the action's own resource type
                // (containers follow), so every request here is schema-valid.
                let resourceType = CedarSchemaBuilder.resourceTypes(for: action).first!
                let decision = try evaluate(action: action, resourceType: resourceType, role: role)
                let expected = granted.contains(action)
                #expect(
                    decision.allowed == expected,
                    "\(role.rawValue) on \(action): got \(decision.allowed), expected \(expected) \(decision.evaluationErrors)"
                )
                if expected {
                    #expect(decision.determiningPolicyIDs == [RoleDescriptor.policyID(role.seededID)])
                    #expect(decision.tier == "grant")
                } else {
                    #expect(decision.tier == "default-deny")
                }
            }
        }
    }

    @Test("With no grants at all, every action denies by default")
    func defaultDeny() throws {
        for action in IAMRoleRegistry.allActions.sorted() {
            let resourceType = CedarSchemaBuilder.resourceTypes(for: action).first!
            let decision = try evaluate(action: action, resourceType: resourceType)
            #expect(!decision.allowed, "\(action) allowed with no grants")
            #expect(decision.determiningPolicyIDs.isEmpty)
        }
    }

    @Test("The system-admin bypass flows through the evaluator and names its policy")
    func systemAdmin() throws {
        let decision = try evaluate(action: "vm:delete", resourceType: .vm, systemAdmin: true)
        #expect(decision.allowed)
        #expect(decision.determiningPolicyIDs == ["platform-system-admin"])
        #expect(decision.tier == "platform")
    }

    @Test("Org membership grants exactly org:read and project:create, via the membership policy")
    func orgMembership() throws {
        let orgID = UUID()
        let read = try evaluate(
            action: "org:read", resourceType: .organization, resourceID: orgID,
            memberOfOrgs: [orgID])
        #expect(read.allowed)
        #expect(read.determiningPolicyIDs == ["org-membership"])
        #expect(read.tier == "platform")

        // project:create anywhere in the org: the folder's parent edge climbs
        // to an org the principal is a member of.
        let folderID = UUID()
        let orgEntity = CedarEntity(
            uid: CedarEntityUID(type: .organization, id: orgID), attrs: [:], parents: [])
        let create = try evaluate(
            action: "project:create", resourceType: .folder, resourceID: folderID,
            memberOfOrgs: [orgID],
            resourceParents: [CedarEntityUID(type: .organization, id: orgID)],
            extraEntities: [orgEntity])
        #expect(create.allowed)
        #expect(create.determiningPolicyIDs == ["org-membership"])

        // Nothing else comes with membership.
        let update = try evaluate(
            action: "org:update", resourceType: .organization, resourceID: orgID,
            memberOfOrgs: [orgID])
        #expect(!update.allowed)
    }

    @Test("A global network is readable by anyone; a project one is not")
    func openNetworkRead() throws {
        let open = try evaluate(
            action: "network:read", resourceType: .network,
            resourceAttrs: ["openToAllUsers": .bool(true)])
        #expect(open.allowed)
        #expect(open.determiningPolicyIDs == ["platform-open-network-read"])

        let closed = try evaluate(action: "network:read", resourceType: .network)
        #expect(!closed.allowed)
    }

    @Test("A guardrail forbid beats a grant and the decision names the ceiling")
    func guardrailWins() throws {
        let orgID = UUID()
        let guardrailID = UUID()
        let guardrail = Guardrail(
            id: guardrailID,
            name: "no-vm-ops",
            nodeType: .organization,
            nodeID: orgID,
            actions: ["vm:*"],
            principalMatch: .any,
            resourceMatch: .any
        )
        let compiledGuardrails = GuardrailRendering.forbids(
            for: [guardrail], organizationIDsByGuardrail: [:])
        #expect(compiledGuardrails.skipped.isEmpty)

        let compiled = try SwiftCedarEngine().compile(
            schemaText: CedarSchemaBuilder.schemaText(roles: RoleDescriptor.seededDefaults()),
            policies: CedarPolicyAssembler.staticPolicies(roles: RoleDescriptor.seededDefaults())
                + compiledGuardrails.policies)

        let principal = CedarEntityUID(type: .user, id: userID)
        let vmID = UUID()
        let projectID = UUID()
        let vm = CedarEntityUID(type: .vm, id: vmID)
        let entities: [CedarEntity] = [
            CedarEntity(
                uid: principal,
                attrs: ["memberOfOrgs": .set([]), "systemAdmin": .bool(false)],
                parents: []),
            CedarEntity(uid: vm, attrs: [:], parents: [CedarEntityUID(type: .project, id: projectID)]),
            CedarEntity(
                uid: CedarEntityUID(type: .project, id: projectID), attrs: [:],
                parents: [CedarEntityUID(type: .organization, id: orgID)]),
            CedarEntity(uid: CedarEntityUID(type: .organization, id: orgID), attrs: [:], parents: []),
        ]
        var grants = CedarRoleGrants()
        grants.addUser(userID, roleID: IAMRole.admin.seededID)

        let decision = try compiled.authorize(
            principal: principal,
            action: "vm:start",
            resource: vm,
            context: .record(["grants": grants.contextValue(roleIDs: Self.seededRoleIDs)]),
            entitiesJSON: CedarText.json(entities))

        #expect(!decision.allowed)
        #expect(decision.determiningPolicyIDs == ["guardrail-\(guardrailID.uuidString.lowercased())"])
        #expect(decision.tier == "guardrail")

        // Off the guardrail's subtree the same grant still works.
        let elsewhere = try compiled.authorize(
            principal: principal,
            action: "vm:start",
            resource: vm,
            context: .record(["grants": grants.contextValue(roleIDs: Self.seededRoleIDs)]),
            entitiesJSON: CedarText.json([
                entities[0],
                CedarEntity(uid: vm, attrs: [:], parents: []),
            ]))
        #expect(elsewhere.allowed)
        #expect(elsewhere.tier == "grant")
    }

    @Test("A group grant reaches the group's members through the parent edge")
    func groupGrant() throws {
        let groupID = UUID()
        let principal = CedarEntityUID(type: .user, id: userID)
        let vm = CedarEntityUID(type: .vm, id: UUID())
        let entities: [CedarEntity] = [
            CedarEntity(
                uid: principal,
                attrs: ["memberOfOrgs": .set([]), "systemAdmin": .bool(false)],
                parents: [CedarEntityUID(type: .group, id: groupID)]),
            CedarEntity(uid: CedarEntityUID(type: .group, id: groupID), attrs: [:], parents: []),
            CedarEntity(uid: vm, attrs: [:], parents: []),
        ]
        var grants = CedarRoleGrants()
        grants.addGroup(groupID, roleID: IAMRole.viewer.seededID)

        let decision = try Self.compiled.authorize(
            principal: principal,
            action: "vm:read",
            resource: vm,
            context: .record(["grants": grants.contextValue(roleIDs: Self.seededRoleIDs)]),
            entitiesJSON: CedarText.json(entities))
        #expect(decision.allowed)
        #expect(decision.determiningPolicyIDs == [RoleDescriptor.policyID(IAMRole.viewer.seededID)])
    }

    @Test("A user-created role's permit works end-to-end, quoted UUID grants fields included")
    func userCreatedRole() throws {
        let roleID = UUID()
        let custom = RoleDescriptor(
            id: roleID,
            name: "vm-auditor",
            cedarText: RoleDescriptor.canonicalPermitText(id: roleID, actions: ["vm:read", "vm:list"]),
            actions: ["vm:list", "vm:read"]
        )
        let roles = RoleDescriptor.seededDefaults() + [custom]
        let compiled = try SwiftCedarEngine().compile(
            schemaText: CedarSchemaBuilder.schemaText(roles: roles),
            policies: CedarPolicyAssembler.staticPolicies(roles: roles))
        let roleIDs = Set(roles.map(\.id))

        let principal = CedarEntityUID(type: .user, id: userID)
        let vm = CedarEntityUID(type: .vm, id: UUID())
        let entities: [CedarEntity] = [
            CedarEntity(
                uid: principal,
                attrs: ["memberOfOrgs": .set([]), "systemAdmin": .bool(false)],
                parents: []),
            CedarEntity(uid: vm, attrs: [:], parents: []),
        ]
        var grants = CedarRoleGrants()
        grants.addUser(userID, roleID: roleID)

        let read = try compiled.authorize(
            principal: principal,
            action: "vm:read",
            resource: vm,
            context: .record(["grants": grants.contextValue(roleIDs: roleIDs)]),
            entitiesJSON: CedarText.json(entities))
        #expect(read.allowed)
        #expect(read.determiningPolicyIDs == [custom.policyID])
        #expect(read.tier == "grant")

        // Outside the role's action list: default deny.
        let start = try compiled.authorize(
            principal: principal,
            action: "vm:start",
            resource: vm,
            context: .record(["grants": grants.contextValue(roleIDs: roleIDs)]),
            entitiesJSON: CedarText.json(entities))
        #expect(!start.allowed)

        // The stale-schema shape: a compiled set that predates the role. The
        // context filter drops the grants (under-grant), and the request
        // still evaluates — no unknown-attribute validation error.
        let stale = try Self.compiled.authorize(
            principal: principal,
            action: "vm:read",
            resource: vm,
            context: .record(["grants": grants.contextValue(roleIDs: Self.seededRoleIDs)]),
            entitiesJSON: CedarText.json(entities))
        #expect(!stale.allowed)
    }

    @Test("A request whose action does not apply to the resource type errors instead of deciding")
    func schemaInvalidRequest() throws {
        #expect(throws: (any Error).self) {
            _ = try evaluate(action: "vm:viewConsole", resourceType: .volume)
        }
    }

    @Test("An unvalidatable policy set refuses to compile")
    func validationFailure() throws {
        let bogus = CedarPolicySource(
            id: "bogus",
            text: #"permit (principal, action == Action::"no:such-action", resource);"#)
        #expect(throws: (any Error).self) {
            _ = try SwiftCedarEngine().compile(
                schemaText: CedarSchemaBuilder.schemaText(roles: RoleDescriptor.seededDefaults()),
                policies: [bogus])
        }
    }

    @Test("policyIssue screens a single bad policy without failing the good ones")
    func policyIssueScreening() throws {
        let schema = CedarSchemaBuilder.schemaText(roles: RoleDescriptor.seededDefaults())
        let engine = SwiftCedarEngine()

        let good = CedarPolicySource(
            id: RoleDescriptor.seededDefaults()[0].policyID,
            text: RoleDescriptor.seededDefaults()[0].cedarText)
        #expect(engine.policyIssue(schemaText: schema, policy: good) == nil)

        let unknownAction = CedarPolicySource(
            id: "role-bogus",
            text: #"permit (principal, action == Action::"no:such-action", resource);"#)
        #expect(engine.policyIssue(schemaText: schema, policy: unknownAction) != nil)

        let unparsable = CedarPolicySource(id: "role-broken", text: "permit (")
        #expect(engine.policyIssue(schemaText: schema, policy: unparsable) != nil)
    }
}
