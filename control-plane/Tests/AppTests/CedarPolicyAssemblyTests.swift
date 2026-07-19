import Foundation
import Testing

@testable import App

/// IAM phase 3 (issue #480): assembly of the static policies and the
/// guardrail forbids.
@Suite("Cedar Policy Assembly Tests")
struct CedarPolicyAssemblyTests {

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

    // MARK: - Static policies

    @Test("Static set carries the platform permits and one policy per role")
    func staticPolicies() {
        let text = CedarPolicyAssembler.staticPolicyText()

        #expect(text.contains("@id(\"platform-system-admin\")"))
        #expect(text.contains("when { principal.systemAdmin };"))
        #expect(text.contains("@id(\"platform-open-network-read\")"))
        #expect(text.contains("resource is Network"))
        #expect(text.contains("@id(\"org-membership\")"))
        #expect(text.contains("action in [Action::\"org:read\", Action::\"project:create\"]"))
        #expect(text.contains("when { resource in principal.memberOfOrgs };"))

        for role in IAMRole.allCases {
            #expect(text.contains("@id(\"role-\(role.rawValue)\")"))
            #expect(text.contains("action in Action::\"role:\(role.rawValue)\""))
            #expect(text.contains("context.grants[\"\(role.grantsUsersField)\"]"))
            #expect(text.contains("context.grants[\"\(role.grantsGroupsField)\"]"))
        }

        // Tier separation: nothing in the static set forbids.
        #expect(!text.contains("forbid"))
    }

    // MARK: - Guardrail compilation

    @Test("Guardrail compilation emits forbids and nothing else")
    func guardrailsAreForbidOnly() {
        let guardrails = [
            makeGuardrail(actions: ["*"]),
            makeGuardrail(actions: ["vm:*", "volume:attach"], principalMatch: .user(UUID())),
            makeGuardrail(principalMatch: .group(UUID()), resourceMatch: .environment("production")),
        ]
        let result = CedarPolicyAssembler.guardrailPolicyText(guardrails, organizationIDsByGuardrail: [:])

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

        let wildcardText = CedarPolicyAssembler.guardrailPolicyText([wildcard], organizationIDsByGuardrail: [:])
            .policyText
        let patternText = CedarPolicyAssembler.guardrailPolicyText([patterns], organizationIDsByGuardrail: [:])
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
        let text = CedarPolicyAssembler.guardrailPolicyText([guardrail], organizationIDsByGuardrail: [:]).policyText
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

        let userText = CedarPolicyAssembler.guardrailPolicyText([user], organizationIDsByGuardrail: [:]).policyText
        let groupText = CedarPolicyAssembler.guardrailPolicyText([group], organizationIDsByGuardrail: [:]).policyText
        let externalText = CedarPolicyAssembler.guardrailPolicyText(
            [external], organizationIDsByGuardrail: [externalID: orgID]
        ).policyText

        #expect(userText.contains("principal == User::\"\(userID.uuidString.lowercased())\""))
        // `in`, not `==`: the ceiling has to reach the group's members the
        // same way a grant does.
        #expect(groupText.contains("principal in Group::\"\(groupID.uuidString.lowercased())\""))
        #expect(
            externalText.contains(
                "when { !(principal.memberOfOrgs.contains(Organization::\"\(orgID.uuidString.lowercased())\")) }"))
    }

    @Test("An external-principal guardrail with no resolvable org is skipped, not misdirected")
    func externalWithoutOrgSkipped() {
        let guardrail = makeGuardrail(principalMatch: .externalToOrganization)
        let result = CedarPolicyAssembler.guardrailPolicyText([guardrail], organizationIDsByGuardrail: [:])

        #expect(result.compiledGuardrailIDs.isEmpty)
        #expect(result.skipped.count == 1)
        #expect(result.policyText.isEmpty)
    }

    @Test("Environment match compiles with a has-guard so unenvironmented resources fall outside it")
    func environmentMatchCompilation() {
        let guardrail = makeGuardrail(resourceMatch: .environment("production"))
        let text = CedarPolicyAssembler.guardrailPolicyText([guardrail], organizationIDsByGuardrail: [:]).policyText
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
        let text = CedarPolicyAssembler.guardrailPolicyText(
            [guardrail], organizationIDsByGuardrail: [externalID: orgID]
        ).policyText
        #expect(text.contains(") && resource has environment && resource.environment == \"production\" }"))
    }

    @Test("Environment values are escaped as Cedar string literals")
    func stringEscaping() {
        let guardrail = makeGuardrail(resourceMatch: .environment("pro\"d\\1"))
        let text = CedarPolicyAssembler.guardrailPolicyText([guardrail], organizationIDsByGuardrail: [:]).policyText
        #expect(text.contains("resource.environment == \"pro\\\"d\\\\1\""))
    }

    @Test("Compilation order is deterministic across input orderings")
    func deterministicOrdering() {
        let a = makeGuardrail()
        let b = makeGuardrail()
        let forward = CedarPolicyAssembler.guardrailPolicyText([a, b], organizationIDsByGuardrail: [:]).policyText
        let reverse = CedarPolicyAssembler.guardrailPolicyText([b, a], organizationIDsByGuardrail: [:]).policyText
        #expect(forward == reverse)
    }
}
