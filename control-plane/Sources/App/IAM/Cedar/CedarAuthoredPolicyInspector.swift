import CedarPolicy
import Foundation
import Vapor

// IAM authored policies (issue #606): reading an authored policy's shape off
// its *parsed* Cedar text.
//
// An authored policy is freeform Cedar — permit or forbid, any principal, any
// conditions — so there is far less to enforce than a role. Two things are
// read here, both off Cedar's own EST rather than off the text, so a policy
// cannot say one thing to the evaluator and another to containment or who-can:
//
//   - its **effect** (`permit`/`forbid`), stored so the catalog, who-can, and
//     the UI can label it without re-parsing; and
//   - its **resource scope** — the concrete entity the policy is confined to,
//     which `PolicyStore` walks up the tree to prove is inside the owner's
//     subtree (structural containment, v1). Formal symcc-based analysis is
//     #484's follow-up.
//
// The action scope is read best-effort for who-can only (issue #606's who-can
// honesty), and never constrains a write — an authored policy is allowed an
// unscoped action.

/// The concrete entity an authored policy's resource scope names — `resource
/// == X` or `resource in X`. Containment is checked against this.
struct AuthoredResourceScope: Equatable, Sendable {
    let type: CedarEntityType
    let id: UUID
}

/// What an authored policy's action scope enumerates, as far as who-can can
/// tell from the text alone.
enum AuthoredActionScope: Equatable, Sendable {
    /// Unscoped `action` — every action.
    case all
    /// An explicit `==`/`in` list of registry actions.
    case explicit(Set<String>)
    /// A scope that cannot be enumerated from the text — an action-group
    /// reference, or anything the parser rendered in a shape we do not read.
    /// Who-can treats these as a possible match rather than guessing.
    case unknown
}

/// An authored policy's shape, read off its EST.
struct AuthoredPolicyShape: Equatable, Sendable {
    let effect: IAMPolicyEffect
    /// The concrete resource the policy is confined to, or nil when the scope
    /// is unconstrained (`resource`), a bare type (`resource is VM`), or names
    /// something that is not a resolvable entity.
    let resourceScope: AuthoredResourceScope?
    let actionScope: AuthoredActionScope
    /// Whether the principal scope is anything other than the unconstrained
    /// `principal` (`==`/`in`/`is`). Read for the authored-guardrail self-lock
    /// check (#610), which refuses an *unconditional* forbid that could reach
    /// `iam:setPolicy` for everyone.
    let principalConstrained: Bool
    /// Whether the policy carries any `when`/`unless` conditions. Same reader as
    /// `principalConstrained`: a conditioned forbid over `iam:setPolicy` leaves
    /// someone outside the condition able to undo it, so it is not self-locking.
    let hasConditions: Bool
}

/// Why a piece of authored-policy text is not usable as a policy. Every case
/// is a `400`: policy text is request input, and text that cannot be compiled
/// or does not stay inside its owner is malformed, not forbidden.
enum CedarAuthoredPolicyTextError: Error, AbortError, Equatable {
    case unparseable(String)
    case unknownEffect(String)

    var status: HTTPResponseStatus { .badRequest }

    var reason: String {
        switch self {
        case .unparseable(let detail):
            return "The policy's Cedar text is not a single parseable policy: \(detail)"
        case .unknownEffect(let effect):
            return "A policy's effect must be `permit` or `forbid`; '\(effect)' is neither."
        }
    }
}

/// Parses authored-policy text and reads its shape off Cedar's EST.
enum CedarAuthoredPolicyInspector {

    /// Parse `cedarText` as a single policy and read its effect, resource
    /// scope, and (best-effort) action scope.
    ///
    /// Throws only when the text is not a single parseable policy or carries an
    /// effect Cedar somehow rendered as neither `permit` nor `forbid`. The
    /// containment rule — that the resource scope names something inside the
    /// owner — is `PolicyStore`'s to enforce, because it needs the tree.
    static func describe(cedarText: String, policyID: String) throws -> AuthoredPolicyShape {
        let est = try parse(cedarText, policyID: policyID)

        let effectString = est["effect"] as? String ?? "unknown"
        guard let effect = IAMPolicyEffect(rawValue: effectString) else {
            throw CedarAuthoredPolicyTextError.unknownEffect(effectString)
        }

        return AuthoredPolicyShape(
            effect: effect,
            resourceScope: resourceScope(est),
            actionScope: actionScope(est),
            principalConstrained: principalConstrained(est),
            hasConditions: hasConditions(est)
        )
    }

    /// Whether the principal scope is constrained at all — anything other than
    /// the unconstrained `principal` (EST op `All`).
    private static func principalConstrained(_ est: [String: Any]) -> Bool {
        guard let scope = est["principal"] as? [String: Any], let op = scope["op"] as? String else {
            // An unreadable principal scope is treated as constrained: the
            // self-lock check errs toward *allowing* the write, and only the
            // clearly-unconstrained form should trip it.
            return true
        }
        return op != "All"
    }

    /// Whether the policy carries any `when`/`unless` conditions.
    private static func hasConditions(_ est: [String: Any]) -> Bool {
        guard let conditions = est["conditions"] as? [Any] else { return false }
        return !conditions.isEmpty
    }

    // MARK: - Parsing

    /// The policy's EST (Cedar's JSON policy format), as plain dictionaries —
    /// the same untyped read `CedarPolicyInspector` uses, for the same reason:
    /// the EST is wide and versioned, and only a handful of questions are asked
    /// of it.
    private static func parse(_ cedarText: String, policyID: String) throws -> [String: Any] {
        let policy: CedarPolicy.Policy
        do {
            // Text holding more than one policy fails here — `Policy` parses
            // exactly one.
            policy = try CedarPolicy.Policy(cedarText, id: policyID)
        } catch {
            throw CedarAuthoredPolicyTextError.unparseable("\(error)")
        }
        do {
            let json = try policy.toJSON()
            guard let est = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else {
                throw CedarAuthoredPolicyTextError.unparseable("the policy did not render as a JSON object")
            }
            return est
        } catch let error as CedarAuthoredPolicyTextError {
            throw error
        } catch {
            throw CedarAuthoredPolicyTextError.unparseable("\(error)")
        }
    }

    // MARK: - Resource scope

    /// The concrete entity the resource scope names, or nil when it names no
    /// single entity.
    ///
    /// `resource == X` and `resource in X` both confine the policy to X's
    /// subtree; `resource is T in X` does too, through its `in` clause. A bare
    /// `resource` or `resource is T` confines nothing — it reaches every
    /// resource of a type, across orgs — so it has no containment entity and a
    /// write against it is refused.
    private static func resourceScope(_ est: [String: Any]) -> AuthoredResourceScope? {
        guard let scope = est["resource"] as? [String: Any], let op = scope["op"] as? String else {
            return nil
        }
        switch op {
        case "==", "in":
            return entityScope(scope["entity"])
        case "is":
            // `resource is T in X` — the `in` clause carries the containment
            // entity; `resource is T` alone does not.
            if let inClause = scope["in"] as? [String: Any] {
                return entityScope(inClause["entity"])
            }
            return nil
        default:
            return nil
        }
    }

    /// An `AuthoredResourceScope` from an EST entity reference, or nil when the
    /// reference is missing, names an unknown type, or carries a non-UUID id.
    private static func entityScope(_ value: Any?) -> AuthoredResourceScope? {
        guard let entity = value as? [String: Any],
            let typeString = entity["type"] as? String,
            let type = CedarEntityType(rawValue: typeString),
            let idString = entity["id"] as? String,
            let id = UUID(uuidString: idString)
        else { return nil }
        return AuthoredResourceScope(type: type, id: id)
    }

    // MARK: - Action scope

    /// The action scope, as far as who-can can read it. Never throws — an
    /// unreadable shape is `.unknown`, which who-can treats as "might match".
    private static func actionScope(_ est: [String: Any]) -> AuthoredActionScope {
        guard let scope = est["action"] as? [String: Any], let op = scope["op"] as? String else {
            return .unknown
        }
        switch op {
        case "All":
            return .all
        case "==":
            guard let id = actionID(scope["entity"]) else { return .unknown }
            return classify([id])
        case "in":
            if let entities = scope["entities"] as? [[String: Any]] {
                let ids = entities.compactMap { actionID($0) }
                guard ids.count == entities.count else { return .unknown }
                return classify(ids)
            }
            // `action in Action::"x"` collapses to the singular entity form and
            // is indistinguishable from an action-group reference by shape — so
            // an id we do not recognize as a registry action is `.unknown`.
            guard let id = actionID(scope["entity"]) else { return .unknown }
            return classify([id])
        default:
            return .unknown
        }
    }

    /// A `[String]` of action ids becomes `.explicit` only when every id is a
    /// known registry action; any unknown id (an action group, or a stale
    /// action) makes the whole scope `.unknown`, so who-can never reports a
    /// non-match it cannot be sure of.
    private static func classify(_ ids: [String]) -> AuthoredActionScope {
        for id in ids where !IAMRoleRegistry.allActions.contains(id) {
            return .unknown
        }
        return .explicit(Set(ids))
    }

    /// The id of an `Action::"…"` reference; nil for a reference to anything
    /// else.
    private static func actionID(_ value: Any?) -> String? {
        guard let entity = value as? [String: Any], entity["type"] as? String == "Action" else {
            return nil
        }
        return entity["id"] as? String
    }
}

extension AuthoredActionScope {
    /// Whether this scope could cover `action`. `.unknown` answers `true` — the
    /// honest best-effort answer when the text cannot be enumerated.
    func couldMatch(_ action: String) -> Bool {
        switch self {
        case .all, .unknown:
            return true
        case .explicit(let actions):
            return actions.contains(action)
        }
    }
}
