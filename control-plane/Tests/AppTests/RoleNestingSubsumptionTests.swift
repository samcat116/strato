import Foundation
import Testing

@testable import App

/// IAM phase 7 (issue #484): the role-nesting invariant, proved symbolically.
///
/// `viewer ⊂ operator ⊂ editor ⊂ admin` is the direction
/// docs/architecture/iam.md warns is easy to get backwards, and getting it
/// backwards means `role:viewer` silently reaches everything. `CedarSchemaTests`
/// already checks it by enumerating the action inventory; this checks the
/// compiled *policies* with a solver, which is the check that keeps working
/// when the answer stops being a finite enumeration — a role policy that grows
/// a condition, say.
///
/// Runs in CI, where cvc5 is installed; skipped elsewhere.
@Suite("IAM Role Nesting Subsumption", .enabled(if: solverPath() != nil))
struct RoleNestingSubsumptionTests {

    private var analyzer: SymCCGuardrailAnalyzer { SymCCGuardrailAnalyzer(solverPath: solverPath()!) }

    /// The reach of one role, as a policy: everything in its action group.
    private func rolePolicy(_ role: IAMRole) -> CedarPolicySource {
        CedarPolicySource(
            id: "role-\(role.rawValue)",
            text: """
                @id("role-\(role.rawValue)")
                permit (
                    principal,
                    action in Action::\(CedarText.stringLiteral(CedarSchemaBuilder.roleGroupName(role))),
                    resource
                );
                """
        )
    }

    /// A request environment each action is actually declared for.
    /// Named distinctly from the locals that hold its result: `let environment
    /// = environment(for:)` is a self-referential declaration, which the Linux
    /// toolchain resolves to the variable being declared rather than to this
    /// method — and inside a `#require` expansion that surfaces as a baffling
    /// "cannot call value of non-function type".
    private func requestEnvironment(for action: String) -> CedarRequestEnvironment? {
        guard let resourceType = CedarSchemaBuilder.resourceTypes(for: action).first else { return nil }
        return CedarRequestEnvironment(principalType: .user, action: action, resourceType: resourceType)
    }

    @Test("Each role's reach is contained in the role above it")
    func lowerRolesAreSubsumed() async throws {
        let schemaText = CedarSchemaBuilder.schemaText()
        for higher in IAMRole.allCases {
            guard let lower = higher.implies else { continue }
            for action in IAMRoleRegistry.actions(for: lower).sorted() {
                guard let environment = requestEnvironment(for: action) else { continue }
                let result = try await analyzer.implies(
                    schemaText: schemaText, [rolePolicy(lower)], [rolePolicy(higher)],
                    in: environment)
                #expect(
                    result.holds,
                    "\(lower.rawValue) reaches \(action) but \(higher.rawValue) does not: \(result.counterexample ?? "")"
                )
            }
        }
    }

    @Test("The nesting is strict: the higher role reaches more")
    func higherRolesAreNotSubsumed() async throws {
        let schemaText = CedarSchemaBuilder.schemaText()
        for higher in IAMRole.allCases {
            guard let lower = higher.implies else { continue }
            // An action the higher role has and the lower one does not; the
            // subsumption must fail there, or the two groups are the same set
            // and the nesting is decorative.
            let exclusive = IAMRoleRegistry.actions(for: higher)
                .subtracting(IAMRoleRegistry.actions(for: lower))
            let action = try #require(exclusive.sorted().first)
            let candidate = requestEnvironment(for: action)
            let environment = try #require(candidate)

            let result = try await analyzer.implies(
                schemaText: schemaText, [rolePolicy(higher)], [rolePolicy(lower)],
                in: environment)
            #expect(!result.holds, "\(higher.rawValue) collapsed into \(lower.rawValue) at \(action)")
        }
    }
}
