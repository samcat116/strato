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
    /// parse + strict validation runs once.
    private static let compiled: any CedarCompiledPolicySet = {
        do {
            return try SwiftCedarEngine().compile(
                schemaText: CedarSchemaBuilder.schemaText(),
                policies: CedarPolicyAssembler.staticPolicies())
        } catch {
            fatalError("static Cedar set failed to compile: \(error)")
        }
    }()

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
            grants.addUser(userID, role: role)
        }

        return try Self.compiled.authorize(
            principal: principal,
            action: action,
            resource: resource,
            context: .record(["grants": grants.contextValue]),
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
                    #expect(decision.determiningPolicyIDs == ["role-\(role.rawValue)"])
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
        let compiledGuardrails = CedarPolicyAssembler.guardrailPolicyText(
            [guardrail], organizationIDsByGuardrail: [:])
        #expect(compiledGuardrails.skipped.isEmpty)

        let compiled = try SwiftCedarEngine().compile(
            schemaText: CedarSchemaBuilder.schemaText(),
            policies: CedarPolicyAssembler.staticPolicies() + compiledGuardrails.policies)

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
        grants.addUser(userID, role: .admin)

        let decision = try compiled.authorize(
            principal: principal,
            action: "vm:start",
            resource: vm,
            context: .record(["grants": grants.contextValue]),
            entitiesJSON: CedarText.json(entities))

        #expect(!decision.allowed)
        #expect(decision.determiningPolicyIDs == ["guardrail-\(guardrailID.uuidString.lowercased())"])
        #expect(decision.tier == "guardrail")

        // Off the guardrail's subtree the same grant still works.
        let elsewhere = try compiled.authorize(
            principal: principal,
            action: "vm:start",
            resource: vm,
            context: .record(["grants": grants.contextValue]),
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
        grants.addGroup(groupID, role: .viewer)

        let decision = try Self.compiled.authorize(
            principal: principal,
            action: "vm:read",
            resource: vm,
            context: .record(["grants": grants.contextValue]),
            entitiesJSON: CedarText.json(entities))
        #expect(decision.allowed)
        #expect(decision.determiningPolicyIDs == ["role-viewer"])
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
                schemaText: CedarSchemaBuilder.schemaText(),
                policies: [bogus])
        }
    }
}
