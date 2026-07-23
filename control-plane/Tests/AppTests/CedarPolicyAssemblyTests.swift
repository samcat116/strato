import Foundation
import Testing

@testable import App

/// IAM phase 3 (issue #480): assembly of the static (platform + role)
/// policies. The guardrail forbids render in `GuardrailRendering` and are
/// pinned by `GuardrailRenderingTests`.
@Suite("Cedar Policy Assembly Tests")
struct CedarPolicyAssemblyTests {

    // MARK: - Static policies

    private var seededDescriptors: [RoleDescriptor] {
        IAMRole.allCases.map { role in
            let actions = IAMRoleRegistry.actions(for: role).sorted()
            return RoleDescriptor(
                id: role.seededID,
                name: role.rawValue,
                cedarText: RoleDescriptor.canonicalPermitText(id: role.seededID, actions: actions),
                actions: actions
            )
        }
    }

    @Test("Static set carries the platform permits and one policy per role row")
    func staticPolicies() {
        let text = CedarPolicyAssembler.staticPolicyText(roles: seededDescriptors)

        #expect(text.contains("@id(\"platform-system-admin\")"))
        #expect(text.contains("when { principal.systemAdmin };"))
        #expect(text.contains("@id(\"platform-open-network-read\")"))
        #expect(text.contains("resource is Network"))
        #expect(text.contains("@id(\"org-membership\")"))
        #expect(text.contains("action in [Action::\"org:read\", Action::\"project:create\"]"))
        #expect(text.contains("when { resource in principal.memberOfOrgs };"))

        for role in seededDescriptors {
            #expect(text.contains("@id(\"\(role.policyID)\")"))
            #expect(text.contains("context.grants[\"\(role.grantsUsersField)\"]"))
            #expect(text.contains("context.grants[\"\(role.grantsGroupsField)\"]"))
        }

        // Tier separation: the only forbid in the static set is the tier-1
        // cross-tenant agent interlock. Guardrail forbids stay tier 2 — a
        // second `forbid` appearing here means one leaked into the static set.
        #expect(text.components(separatedBy: "forbid").count - 1 == 1)
        #expect(text.contains("@id(\"platform-agent-foreign-workloads\")"))
    }

    @Test("Role rows compile verbatim under their policy id; empty text compiles to no permit")
    func rolePolicyAssembly() {
        let live = RoleDescriptor(
            id: UUID(),
            name: "auditor",
            cedarText: RoleDescriptor.canonicalPermitText(id: UUID(), actions: ["vm:read", "vm:list"]),
            actions: ["vm:list", "vm:read"]
        )
        let empty = RoleDescriptor(id: UUID(), name: "pending", cedarText: "", actions: [])

        let policies = CedarPolicyAssembler.staticPolicies(roles: [live, empty])
        #expect(policies.contains { $0.id == live.policyID && $0.text == live.cedarText })
        #expect(!policies.contains { $0.id == empty.policyID })
    }

    @Test("Role policy order is deterministic across input orderings")
    func rolePolicyDeterministicOrdering() {
        let forward = CedarPolicyAssembler.staticPolicyText(roles: seededDescriptors)
        let reversed = CedarPolicyAssembler.staticPolicyText(roles: seededDescriptors.reversed())
        #expect(forward == reversed)
    }
}
