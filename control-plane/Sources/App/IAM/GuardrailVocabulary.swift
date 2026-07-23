import Foundation
import Vapor

// IAM phase 2 (issue #479): the tier-2 guardrail vocabulary.
//
// Guardrails are *ceilings*: they bound what tier-3 grants can reach, and they
// can only subtract. Customers never author policy text — a guardrail is
// assembled from the fixed vocabulary below, the same way a role binding is
// assembled from the role registry (docs/architecture/iam.md).

/// **INVARIANT: guardrails are `forbid`-only.**
///
/// The enum has exactly one case, so a permit-shaped guardrail is not
/// constructible in Swift at all; `GuardrailStore.validateEffect` rejects one
/// at the API boundary with a `400` rather than letting it round-trip, and the
/// table carries a `forbid`-only check on Postgres. Three layers because the
/// invariant is load-bearing: a ceiling that could grant is not a ceiling, and
/// nothing downstream re-checks the effect before applying a guardrail.
enum GuardrailEffect: String, Codable, Sendable, CaseIterable {
    case forbid
}

// MARK: - Principal side

/// The discriminator stored in `principal_match_kind`.
enum GuardrailPrincipalMatchKind: String, Codable, Sendable, CaseIterable {
    case any
    case user
    case group
    case externalToOrganization = "external_to_organization"
}

/// Which principals a guardrail constrains — the *principal-side* shape.
///
/// `any` is not an absence of a constraint: paired with a resource match it is
/// how a resource-side ceiling is written ("nobody, whoever they are, may
/// reach this").
enum GuardrailPrincipalMatch: Equatable, Sendable {
    case any
    case user(UUID)
    case group(UUID)
    /// Principals outside the resource's organization. This is the shape that
    /// makes cross-org access ceilable: bindings may name a principal from
    /// another org by design, and `forbid` is the only thing that can take that
    /// back (docs/architecture/iam.md, "Cross-org access").
    case externalToOrganization

    var kind: GuardrailPrincipalMatchKind {
        switch self {
        case .any: return .any
        case .user: return .user
        case .group: return .group
        case .externalToOrganization: return .externalToOrganization
        }
    }

    /// The subject id, for the two kinds that name one.
    var subjectID: UUID? {
        switch self {
        case .user(let id), .group(let id): return id
        case .any, .externalToOrganization: return nil
        }
    }

    /// Rebuild from the stored columns. Throws rather than defaulting: a row
    /// we cannot interpret must not quietly evaluate as "matches nobody",
    /// which would drop a ceiling on the floor.
    static func from(kind: GuardrailPrincipalMatchKind, subjectID: UUID?) throws -> GuardrailPrincipalMatch {
        switch kind {
        case .any: return .any
        case .externalToOrganization: return .externalToOrganization
        case .user:
            guard let subjectID else { throw GuardrailError.missingSubjectID(kind.rawValue) }
            return .user(subjectID)
        case .group:
            guard let subjectID else { throw GuardrailError.missingSubjectID(kind.rawValue) }
            return .group(subjectID)
        }
    }
}

// MARK: - Resource side

/// The discriminator stored in `resource_match_kind`.
enum GuardrailResourceMatchKind: String, Codable, Sendable, CaseIterable {
    case any
    case environment
}

/// Which resources a guardrail constrains — the *resource-side* shape.
enum GuardrailResourceMatch: Equatable, Sendable {
    case any
    /// Resources whose `environment` attribute equals this value. Environment
    /// is an attribute, never a container, so this matches the resource being
    /// acted on rather than anything in its ancestry.
    case environment(String)

    var kind: GuardrailResourceMatchKind {
        switch self {
        case .any: return .any
        case .environment: return .environment
        }
    }

    var value: String? {
        switch self {
        case .any: return nil
        case .environment(let value): return value
        }
    }

    static func from(kind: GuardrailResourceMatchKind, value: String?) throws -> GuardrailResourceMatch {
        switch kind {
        case .any: return .any
        case .environment:
            guard let value, !value.isEmpty else { throw GuardrailError.missingMatchValue(kind.rawValue) }
            return .environment(value)
        }
    }
}

// MARK: - Action patterns

/// The action set a guardrail forbids, as a list of patterns.
///
/// Wildcards exist because ceilings must cover actions we have not shipped
/// yet: "the default ceiling is fully permissive… ceilings only subtract, so
/// every new action we ship is automatically covered by existing guardrails"
/// (docs/architecture/iam.md). A `vm:*` ceiling written today keeps holding
/// when `vm:migrate` lands. Roles are the deliberate opposite — an action joins
/// a role only by an explicit, reviewed change.
enum GuardrailActions {
    /// Matches every action, present and future.
    static let wildcard = "*"

    // Pattern *interpretation* — which actions a stored pattern set covers —
    // lives in `GuardrailRendering.patternsCover`, beside the Cedar clause it
    // must agree with. This vocabulary owns which patterns are legal to store.

    /// Validate and canonicalize a pattern list.
    ///
    /// An empty list means "every action" — the broadest ceiling — and
    /// normalizes to `["*"]` so the stored row says what it does. Exact
    /// actions must exist in the role registry and service prefixes must name
    /// a real service: a ceiling silently protecting nothing because of a typo
    /// is the worst failure mode this store has.
    static func canonicalize(_ patterns: [String]) throws -> [String] {
        let trimmed = patterns.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !trimmed.isEmpty else { return [wildcard] }
        if trimmed.contains(wildcard) { return [wildcard] }

        for pattern in trimmed {
            if pattern.hasSuffix(":*") {
                let service = String(pattern.dropLast(2))
                guard IAMRoleRegistry.actionServices.contains(service) else {
                    throw GuardrailError.unknownActionService(service)
                }
            } else {
                guard IAMRoleRegistry.allActions.contains(pattern) else {
                    throw GuardrailError.unknownAction(pattern)
                }
            }
        }
        return Array(Set(trimmed)).sorted()
    }
}

// MARK: - Errors

/// Write-time rejections from the guardrail store. All of these are `400`s:
/// a malformed ceiling is a bad request, not a denied one — the same
/// distinction the design draws for illegal parentage.
enum GuardrailError: Error, AbortError, Equatable {
    case permitRejected(String)
    case unattachableNode(String)
    case unknownAction(String)
    case unknownActionService(String)
    case missingSubjectID(String)
    case missingMatchValue(String)
    case locksOutPolicyAdministration
    case duplicateName(String)
    // Authored (hand-written forbid Cedar) input, #610.
    case ambiguousInput
    case missingInput
    case emptyCedarText
    case authoredMustForbid(String)
    case authoredUnscopedResource
    case authoredPrincipalResourceScope(String)
    case authoredOutOfScope(attach: String, resource: String)
    case rejectedByCedar(String)
    case modeMismatch(String)

    var status: HTTPResponseStatus { .badRequest }

    var reason: String {
        switch self {
        case .permitRejected(let effect):
            return
                "Guardrails are forbid-only; effect '\(effect)' is not allowed. A ceiling can only subtract from what grants reach."
        case .unattachableNode(let type):
            return
                "Guardrails attach to organizations, folders, and projects; '\(type)' is not one of those. Ceilings inherit downward from a container."
        case .unknownAction(let action):
            return "Unknown action '\(action)'. Use an action from the role registry, 'service:*', or '*'."
        case .unknownActionService(let service):
            return "Unknown action service '\(service)' in pattern '\(service):*'."
        case .missingSubjectID(let kind):
            return "A '\(kind)' principal match requires a subject id."
        case .missingMatchValue(let kind):
            return "A '\(kind)' resource match requires a value."
        case .locksOutPolicyAdministration:
            return
                "A guardrail that forbids 'iam:setPolicy' for every principal on every resource would outlaw its own removal, locking the subtree's policy administration irrecoverably. Narrow the principals or the resources it applies to, or exclude 'iam:setPolicy' from its actions."
        case .duplicateName(let name):
            return "A guardrail named '\(name)' is already attached to this node."
        case .ambiguousInput:
            return
                "Send either the structured matchers ('actions'/'principalMatch'/'resourceMatch') or 'cedarText', not both — matchers assemble the forbid, and hand-written text supersedes them."
        case .missingInput:
            return
                "A guardrail needs either the structured matchers (the builder assembles the forbid) or 'cedarText' (advanced: a hand-written Cedar forbid)."
        case .emptyCedarText:
            return "'cedarText' is empty — it must be a single Cedar forbid."
        case .authoredMustForbid(let effect):
            return
                "Guardrails are forbid-only; the authored policy's effect is '\(effect)'. A ceiling can only subtract from what grants reach."
        case .authoredUnscopedResource:
            return
                "An authored guardrail's resource scope must name the attach node (or a resource inside it) — `resource in <Type>::\"<id>\"`. An unscoped `resource` would reach every resource across every organization, which a ceiling anchored to one subtree must not."
        case .authoredPrincipalResourceScope(let type):
            return
                "The authored guardrail's resource scope names '\(type)', which is a principal, not a resource. Scope it to the attach node or a resource inside it."
        case .authoredOutOfScope(let attach, let resource):
            return
                "The authored guardrail's resource scope (\(resource)) is not inside its attach node (\(attach)). A ceiling can only reach the subtree it hangs on."
        case .rejectedByCedar(let detail):
            return "Cedar rejected the guardrail: \(detail)"
        case .modeMismatch(let detail):
            return detail
        }
    }
}
