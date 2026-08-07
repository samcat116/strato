import Foundation
import Testing

@testable import App

/// STR-115: the `credential-restriction` forbid, evaluated by the real engine.
///
/// The first test here is load-bearing beyond its own assertion. The platform
/// policies are the only ones the policy-set cache does *not* pre-screen
/// individually — role, guardrail and authored rows are screened and skipped,
/// but a platform policy that fails strict validation fails the whole compile,
/// which leaves `CedarPolicySetCache.current` nil and answers every request in
/// the fleet with a 503. So "does this policy validate against the generated
/// schema" is a thing to assert directly, not to discover from an outage.
@Suite("Credential Restriction Policy")
struct CredentialRestrictionPolicyTests {

    private static let roles = RoleDescriptor.seededDefaults()
    private static let schemaText = CedarSchemaBuilder.schemaText(roles: roles)
    private static let seededRoleIDs = Set(IAMRole.allCases.map(\.seededID))

    private static let compiled: any CedarCompiledPolicySet = {
        do {
            return try SwiftCedarEngine().compile(
                schemaText: schemaText, policies: CedarPolicyAssembler.staticPolicies(roles: roles))
        } catch {
            fatalError("static Cedar set failed to compile: \(error)")
        }
    }()

    @Test("The forbid passes strict validation on its own")
    func policyValidates() throws {
        let policy = CedarPolicyAssembler.staticPolicies(roles: Self.roles)
            .first { $0.id == CedarCheckDecision.credentialRestrictionPolicyID }
        let unwrapped = try #require(policy, "the assembler no longer emits the credential-restriction forbid")
        #expect(SwiftCedarEngine().policyIssue(schemaText: Self.schemaText, policy: unwrapped) == nil)
    }

    @Test("The schema declares credentialRestricted as an optional context attribute")
    func schemaDeclaresContextAttribute() {
        #expect(Self.schemaText.contains("\"credentialRestricted\"?: Bool"))
    }

    // MARK: - Evaluation

    private let userID = UUID()

    /// One check against the compiled static set, with the restriction flag
    /// set or not — the same two contexts `IAMDecisionEngine` builds.
    private func evaluate(
        action: String,
        role: IAMRole? = nil,
        systemAdmin: Bool = false,
        credentialRestricted: Bool
    ) throws -> CedarCheckDecision {
        let resourceType = CedarSchemaBuilder.resourceTypes(for: action).first!
        let principal = CedarEntityUID(type: .user, id: userID)
        let resource = CedarEntityUID(type: resourceType, id: UUID())

        var attrs: [String: CedarValue] = [:]
        if resourceType == .user {
            attrs["memberOfOrgs"] = .set([])
            attrs["systemAdmin"] = .bool(false)
        }
        let entities = [
            CedarEntity(
                uid: principal,
                attrs: ["memberOfOrgs": .set([]), "systemAdmin": .bool(systemAdmin)],
                parents: []),
            CedarEntity(uid: resource, attrs: attrs, parents: []),
        ]

        var grants = CedarRoleGrants()
        if let role { grants.addUser(userID, roleID: role.seededID) }

        var context: [String: CedarValue] = ["grants": grants.contextValue(roleIDs: Self.seededRoleIDs)]
        if credentialRestricted { context["credentialRestricted"] = .bool(true) }

        return try Self.compiled.authorize(
            principal: principal,
            action: action,
            resource: resource,
            context: .record(context),
            entitiesJSON: CedarText.json(entities))
    }

    @Test("A restricted credential is denied an action its bindings grant")
    func restrictionBeatsGrant() throws {
        let allowed = try evaluate(action: "vm:delete", role: .editor, credentialRestricted: false)
        #expect(allowed.allowed)

        let denied = try evaluate(action: "vm:delete", role: .editor, credentialRestricted: true)
        #expect(!denied.allowed)
        #expect(denied.determiningPolicyIDs.contains(CedarCheckDecision.credentialRestrictionPolicyID))
        #expect(denied.tier == CedarCheckDecision.credentialTier)
    }

    /// A forbid beats every permit, `platform-system-admin` included. A
    /// restricted token held by a system admin is still restricted — otherwise
    /// the narrowest credential in the system would be the most powerful one.
    @Test("A restricted credential binds a system admin too")
    func restrictionBindsSystemAdmin() throws {
        #expect(try evaluate(action: "vm:delete", systemAdmin: true, credentialRestricted: false).allowed)

        let denied = try evaluate(action: "vm:delete", systemAdmin: true, credentialRestricted: true)
        #expect(!denied.allowed)
        #expect(denied.determiningPolicyIDs.contains(CedarCheckDecision.credentialRestrictionPolicyID))
    }

    @Test("An unset flag changes nothing, for every action in the registry")
    func unsetFlagIsInert() throws {
        for action in IAMRoleRegistry.allActions.sorted() {
            let without = try evaluate(action: action, role: .admin, credentialRestricted: false)
            #expect(
                without.determiningPolicyIDs.allSatisfy {
                    $0 != CedarCheckDecision.credentialRestrictionPolicyID
                },
                "\(action) matched the credential forbid with no restriction set")
        }
    }

    @Test("The flag denies every action, so no restriction can be escaped by picking a verb")
    func flagDeniesEveryAction() throws {
        for action in IAMRoleRegistry.allActions.sorted() {
            let decision = try evaluate(action: action, role: .admin, systemAdmin: true, credentialRestricted: true)
            #expect(!decision.allowed, "\(action) survived the credential forbid")
        }
    }

    // MARK: - Tier attribution

    @Test("A guardrail outranks the credential in tier attribution")
    func guardrailOutranksCredential() {
        let both = CedarCheckDecision(
            allowed: false,
            determiningPolicyIDs: [
                CedarCheckDecision.credentialRestrictionPolicyID, "guardrail-\(UUID().uuidString.lowercased())",
            ],
            evaluationErrors: [])
        #expect(both.tier == "guardrail")

        let credentialOnly = CedarCheckDecision(
            allowed: false,
            determiningPolicyIDs: [CedarCheckDecision.credentialRestrictionPolicyID],
            evaluationErrors: [])
        #expect(credentialOnly.tier == CedarCheckDecision.credentialTier)
    }
}
