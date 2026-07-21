import CedarPolicy
import Foundation

// IAM phase 4 (issue #481): the real Cedar engine behind the `CedarEngine`
// seam — samcat116/swift-cedar, wrapping the cedar-policy crate via UniFFI.
//
// Compilation parses and *validates*: the schema, then every policy against
// the schema in strict mode. A policy set that fails validation throws, which
// keeps `CedarPolicySetCache` on its previous set — the same stale-beats-
// broken rule the cache applies to every other rebuild failure.

enum SwiftCedarEngineError: Error, CustomStringConvertible {
    case validationFailed([String])

    var description: String {
        switch self {
        case .validationFailed(let issues):
            return "Cedar policy validation failed: \(issues.joined(separator: "; "))"
        }
    }
}

struct SwiftCedarEngine: CedarEngine {

    /// The compiled set: parsed schema and policies plus the (stateless)
    /// authorizer, shared across checks.
    struct Compiled: CedarCompiledPolicySet {
        let schema: CedarPolicy.Schema
        let policies: CedarPolicy.PolicySet
        let authorizer: CedarPolicy.Authorizer

        func authorize(
            principal: CedarEntityUID,
            action: String,
            resource: CedarEntityUID,
            context: CedarValue,
            entitiesJSON: String
        ) throws -> CedarCheckDecision {
            // Parsed with the schema so Cedar attaches the schema-declared
            // action entities — the role/service action-group hierarchy that
            // `action in Action::"role:viewer"` resolves through. Without it
            // every role policy would silently never match.
            let entities = try CedarPolicy.Entities(json: entitiesJSON, schema: schema)

            guard case .record(let contextFields) = context else {
                throw CedarError.request("context must be a record")
            }

            let request = CedarPolicy.Request(
                principal: EntityUID(type: principal.type, id: principal.id),
                action: EntityUID(type: "Action", id: action),
                resource: EntityUID(type: resource.type, id: resource.id),
                context: contextFields.mapValues { Self.engineValue($0) }
            )
            // Schema-validated: a request whose action does not apply to the
            // resource type is an error, not a silent deny — the decision
            // log records it as such rather than as a verdict.
            let response = try authorizer.isAuthorized(
                request, policies: policies, entities: entities, schema: schema)
            return CedarCheckDecision(
                allowed: response.isAllowed,
                determiningPolicyIDs: response.determiningPolicies.sorted(),
                evaluationErrors: response.errors
            )
        }

        /// Our engine-independent value model, translated to the SDK's.
        private static func engineValue(_ value: CedarValue) -> CedarPolicy.CedarValue {
            switch value {
            case .bool(let bool): return .bool(bool)
            case .long(let long): return .long(long)
            case .string(let string): return .string(string)
            case .entity(let uid): return .entity(EntityUID(type: uid.type, id: uid.id))
            case .set(let values): return .set(values.map { engineValue($0) })
            case .record(let fields): return .record(fields.mapValues { engineValue($0) })
            }
        }
    }

    func policyIssue(schemaText: String, policy: CedarPolicySource) -> String? {
        do {
            let schema = try CedarPolicy.Schema(schemaText)
            let parsed = try CedarPolicy.Policy(policy.text, id: policy.id)
            let set = try CedarPolicy.PolicySet(policies: [parsed])
            let validation = schema.validate(set, mode: .strict)
            guard validation.passed else {
                return validation.errors.map(\.message).joined(separator: "; ")
            }
            return nil
        } catch {
            return "\(error)"
        }
    }

    func compile(schemaText: String, policies: [CedarPolicySource]) throws -> any CedarCompiledPolicySet {
        let schema = try CedarPolicy.Schema(schemaText)
        // Each policy is parsed individually with its assembler-assigned id —
        // the set parser would assign positional `policy0` ids and a decision
        // could never name `role-editor` or the guardrail that forbade it.
        let parsed = try policies.map { try CedarPolicy.Policy($0.text, id: $0.id) }
        let policySet = try CedarPolicy.PolicySet(policies: parsed)

        let validation = schema.validate(policySet, mode: .strict)
        guard validation.passed else {
            throw SwiftCedarEngineError.validationFailed(
                validation.errors.map { "\($0.policyID): \($0.message)" })
        }
        return Compiled(schema: schema, policies: policySet, authorizer: Authorizer())
    }
}
