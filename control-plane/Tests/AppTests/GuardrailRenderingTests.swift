import Foundation
import Testing

@testable import App

/// The one rendering of a guardrail row: the compiled Cedar forbid, the
/// solver-facing permit, and the structural match are projections of a single
/// parsed representation (`GuardrailRendering`), and these tests pin both the
/// projections and the agreements between them.
@Suite("Guardrail Rendering Tests")
struct GuardrailRenderingTests {

    private func makeGuardrail(
        id: UUID = UUID(),
        name: String = "ceiling",
        node: IAMNode = IAMNode(type: .organization, id: UUID()),
        actions: [String] = ["*"],
        principalMatch: GuardrailPrincipalMatch = .any,
        resourceMatch: GuardrailResourceMatch = .any
    ) -> Guardrail {
        Guardrail(
            id: id,
            name: name,
            nodeType: node.type,
            nodeID: node.id,
            actions: actions,
            principalMatch: principalMatch,
            resourceMatch: resourceMatch
        )
    }

    // MARK: - The compiled forbid

    @Test("Guardrail compilation emits forbids and nothing else")
    func guardrailsAreForbidOnly() {
        let guardrails = [
            makeGuardrail(actions: ["*"]),
            makeGuardrail(actions: ["vm:*", "volume:attach"], principalMatch: .user(UUID())),
            makeGuardrail(principalMatch: .group(UUID()), resourceMatch: .environment("production")),
        ]
        let result = GuardrailRendering.forbids(for: guardrails, organizationIDsByGuardrail: [:])

        #expect(result.compiledGuardrailIDs.count == 3)
        #expect(result.skipped.isEmpty)
        // Every policy in the output is a forbid; a permit-shaped guardrail
        // must be structurally impossible to emit.
        #expect(!result.policyText.contains("permit"))
        let forbidCount = result.policyText.components(separatedBy: "forbid (").count - 1
        #expect(forbidCount == 3)
    }

    @Test("Wildcard actions compile to an unconstrained action, patterns to group/action refs")
    func actionPatternCompilation() {
        let node = IAMNode(type: .project, id: UUID())
        let id = UUID()
        let wildcard = makeGuardrail(id: id, node: node, actions: ["*"])
        let patterns = makeGuardrail(node: node, actions: ["vm:*", "volume:attach"])

        let wildcardText = GuardrailRendering.forbids(for: [wildcard], organizationIDsByGuardrail: [:])
            .policyText
        let patternText = GuardrailRendering.forbids(for: [patterns], organizationIDsByGuardrail: [:])
            .policyText

        #expect(wildcardText.contains("forbid (principal, action, resource in Project::"))
        #expect(wildcardText.contains("@id(\"guardrail-\(id.uuidString.lowercased())\")"))
        // A service pattern targets the service action group, so the ceiling
        // keeps covering actions shipped after it was written.
        #expect(patternText.contains("action in [Action::\"svc:vm\", Action::\"volume:attach\"]"))
    }

    @Test("Attach node compiles to `resource in <node>` with the Cedar type name")
    func attachNodeCompilation() {
        let folderID = UUID()
        let guardrail = makeGuardrail(node: IAMNode(type: .organizationalUnit, id: folderID))
        let text = GuardrailRendering.forbids(for: [guardrail], organizationIDsByGuardrail: [:]).policyText
        #expect(text.contains("resource in Folder::\"\(folderID.uuidString.lowercased())\""))
    }

    @Test("Principal matches compile to ==, in, and the external-org condition")
    func principalMatchCompilation() {
        let userID = UUID()
        let groupID = UUID()
        let orgID = UUID()
        let externalID = UUID()

        let user = makeGuardrail(principalMatch: .user(userID))
        let group = makeGuardrail(principalMatch: .group(groupID))
        let external = makeGuardrail(id: externalID, principalMatch: .externalToOrganization)

        let userText = GuardrailRendering.forbids(for: [user], organizationIDsByGuardrail: [:]).policyText
        let groupText = GuardrailRendering.forbids(for: [group], organizationIDsByGuardrail: [:]).policyText
        let externalText = GuardrailRendering.forbids(
            for: [external], organizationIDsByGuardrail: [externalID: orgID]
        ).policyText

        #expect(userText.contains("principal == User::\"\(userID.uuidString.lowercased())\""))
        // `in`, not `==`: the ceiling has to reach the group's members the
        // same way a grant does.
        #expect(groupText.contains("principal in Group::\"\(groupID.uuidString.lowercased())\""))
        #expect(
            externalText.contains(
                "when { !(principal is User && principal.memberOfOrgs.contains(Organization::\"\(orgID.uuidString.lowercased())\")) }"
            ))
    }

    @Test("An external-principal guardrail with no resolvable org is skipped, not misdirected")
    func externalWithoutOrgSkipped() {
        let guardrail = makeGuardrail(principalMatch: .externalToOrganization)
        let result = GuardrailRendering.forbids(for: [guardrail], organizationIDsByGuardrail: [:])

        #expect(result.compiledGuardrailIDs.isEmpty)
        #expect(result.skipped.count == 1)
        #expect(result.policyText.isEmpty)
    }

    @Test("Unparseable rows are skipped with the reason, not rendered")
    func unparseableRowsSkipped() {
        let noID = makeGuardrail()
        noID.id = nil
        let badMatch = makeGuardrail(name: "corrupt")
        badMatch.principalMatchKind = "bogus"

        let result = GuardrailRendering.forbids(for: [noID, badMatch], organizationIDsByGuardrail: [:])

        #expect(result.policies.isEmpty)
        #expect(result.skipped.count == 2)
        #expect(result.skipped.contains { $0.reason == "row has no id" })
        #expect(result.skipped.contains { $0.name == "corrupt" && $0.reason.hasPrefix("unreadable match") })
    }

    @Test("Environment match compiles with a has-guard so unenvironmented resources fall outside it")
    func environmentMatchCompilation() {
        let guardrail = makeGuardrail(resourceMatch: .environment("production"))
        let text = GuardrailRendering.forbids(for: [guardrail], organizationIDsByGuardrail: [:]).policyText
        #expect(text.contains("when { resource has environment && resource.environment == \"production\" }"))
    }

    @Test("Both-sided guardrail combines conditions with &&")
    func combinedConditions() {
        let externalID = UUID()
        let orgID = UUID()
        let guardrail = makeGuardrail(
            id: externalID,
            principalMatch: .externalToOrganization,
            resourceMatch: .environment("production")
        )
        let text = GuardrailRendering.forbids(
            for: [guardrail], organizationIDsByGuardrail: [externalID: orgID]
        ).policyText
        #expect(text.contains(") && resource has environment && resource.environment == \"production\" }"))
    }

    @Test("Environment values are escaped as Cedar string literals")
    func stringEscaping() {
        let guardrail = makeGuardrail(resourceMatch: .environment("pro\"d\\1"))
        let text = GuardrailRendering.forbids(for: [guardrail], organizationIDsByGuardrail: [:]).policyText
        #expect(text.contains("resource.environment == \"pro\\\"d\\\\1\""))
    }

    @Test("Compilation order is deterministic across input orderings")
    func deterministicOrdering() {
        let a = makeGuardrail()
        let b = makeGuardrail()
        let forward = GuardrailRendering.forbids(for: [a, b], organizationIDsByGuardrail: [:]).policyText
        let reverse = GuardrailRendering.forbids(for: [b, a], organizationIDsByGuardrail: [:]).policyText
        #expect(forward == reverse)
    }

    // MARK: - The structural action match

    @Test("Action patterns cover exact actions, service wildcards, and the global wildcard")
    func actionPatternMatching() {
        #expect(GuardrailRendering.patternsCover(["vm:*"], action: "vm:delete"))
        #expect(GuardrailRendering.patternsCover(["vm:*"], action: "vm:migrate"))
        #expect(!GuardrailRendering.patternsCover(["vm:*"], action: "volume:delete"))
        #expect(GuardrailRendering.patternsCover(["*"], action: "anything:at:all"))
        #expect(GuardrailRendering.patternsCover(["vm:delete"], action: "vm:delete"))
        #expect(!GuardrailRendering.patternsCover(["vm:delete"], action: "vm:deleteSnapshot"))
    }

    @Test("The structural action match agrees with the compiled action clause over the registry")
    func actionProjectionsAgree() {
        // The prefix match (structural) and the schema's per-service action
        // group (compiled) must cover the same registry actions, or the
        // matcher surfaces and the evaluator drift. The schema files an
        // action into its service group by the same `service:` prefix, so
        // equality here is the invariant, not a coincidence.
        for service in IAMRoleRegistry.actionServices {
            let structural = IAMRoleRegistry.allActions.filter {
                GuardrailRendering.patternsCover(["\(service):*"], action: $0)
            }
            let byPrefix = IAMRoleRegistry.allActions.filter { $0.hasPrefix("\(service):") }
            #expect(structural == byPrefix, "service \(service)")
        }
    }

    // MARK: - Forbid/permit agreement

    @Test("The solver permit carries the forbid's action clause and resource scope")
    func permitAgreesWithForbid() throws {
        let node = IAMNode(type: .project, id: UUID())
        let guardrail = makeGuardrail(
            node: node,
            actions: ["vm:*", "volume:attach"],
            resourceMatch: .environment("production")
        )
        let rendering = try GuardrailRendering(guardrail)
        let forbid = try rendering.forbid(organizationID: nil).text
        let permit = rendering.permit().text

        // Same scope, flipped effect: disjointness against the permit answers
        // reachability of the forbid.
        #expect(forbid.contains("forbid ("))
        #expect(permit.contains("permit ("))
        let sharedClauses = [
            "action in [Action::\"svc:vm\", Action::\"volume:attach\"]",
            "resource in Project::\"\(node.id.uuidString.lowercased())\"",
            "when { resource has environment && resource.environment == \"production\" }",
        ]
        for clause in sharedClauses {
            #expect(forbid.contains(clause), "\(clause)")
            #expect(permit.contains(clause), "\(clause)")
        }
    }

    @Test("The solver permit leaves the principal side open, even for an external-principal ceiling")
    func permitPrincipalIsOpen() throws {
        // The principal side is settled against the database before the
        // solver runs; restating it symbolically would let the solver invent
        // memberships nobody has. So the permit never carries a principal
        // condition — which is also why it needs no organization id.
        let guardrail = makeGuardrail(principalMatch: .externalToOrganization)
        let rendering = try GuardrailRendering(guardrail)
        let permit = rendering.permit().text
        #expect(permit.contains("principal,"))
        #expect(!permit.contains("memberOfOrgs"))
    }
}
