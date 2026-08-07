import Fluent
import Foundation
import Vapor

/// What a credential is allowed to do, expressed in the ordinary IAM action and
/// node vocabulary (STR-115).
///
/// A credential is issued *on behalf of* a principal and never carries
/// authorization of its own — `docs/architecture/iam.md`'s "identity names the
/// principal" invariant. A restriction is the other half of that statement: it
/// can only ever *subtract* from what the principal's bindings already grant,
/// so the effective permission is `bindings ∩ restriction`. There is no
/// spelling of a restriction that grants anything.
///
/// Enforcement is not here. This type answers "does the restriction cover this
/// action on this resource?"; the answer rides into the Cedar request context
/// as `credentialRestricted` and the `credential-restriction` forbid does the
/// denying, so a restriction denial is an ordinary evaluator decision with a
/// decision-log row and a tier — not the parallel gate `APIKeyScopeMiddleware`
/// used to be.
///
/// Pattern matching deliberately reuses `GuardrailRendering.patternsCover`: a
/// restriction and a ceiling are both "which actions does this pattern set
/// name", and two implementations of that question would be two chances to
/// disagree.
struct CredentialRestriction: Equatable, Sendable {
    /// Action patterns, in the guardrail vocabulary: exact actions
    /// (`vm:read`), service wildcards (`vm:*`), or the universal `*` — plus one
    /// pattern of this vocabulary's own, `read`.
    ///
    /// `["*"]` permits every action; **`[]` permits none**. That asymmetry with
    /// `GuardrailActions.canonicalize` — where an empty pattern list means the
    /// broadest *ceiling*, i.e. everything — is the whole reason `validated`
    /// below rejects empty input before canonicalizing rather than after.
    let actions: [String]

    /// "Every action whose name says it reads", resolved against
    /// `IAMRoleRegistry.readActions` at *check* time.
    ///
    /// Symbolic on purpose. `readActions` is derived from action names so that
    /// an action shipped later lands on the right side by default, and a
    /// credential that stored today's expansion would quietly lose that: the
    /// next release's `dnsrecord:read` would 403 under a
    /// `credential-restriction` forbid nobody wrote, while a legacy
    /// `read`-scoped key picked it up for free. One pattern, resolved on every
    /// check, keeps the two spellings of "read only" the same statement
    /// forever.
    static let readPattern = "read"

    /// The subtree the credential may act in, or nil for "anywhere the
    /// principal can". A resource is in scope when the node appears in its
    /// ancestor chain (the node itself included).
    let node: IAMNode?

    /// Every action, anywhere — what a credential with no restriction columns
    /// and a `write`/`admin` legacy scope resolves to, and what a session
    /// cookie or an agent SVID carries.
    static let unrestricted = CredentialRestriction(actions: [GuardrailActions.wildcard], node: nil)

    /// Nothing, anywhere. The resolution of a legacy credential whose `scopes`
    /// array holds no recognized value: `APIKey.grants(_:)` already answers
    /// false for every scope in that state, so such a key is dead today and
    /// must stay dead — a shim that read "no scopes" as "unrestricted" would
    /// resurrect it with full power.
    static let denyAll = CredentialRestriction(actions: [], node: nil)

    /// Every action whose name says it reads, anywhere. What the legacy `read`
    /// scope resolves to, and what the API mints for a read-only credential —
    /// one value, so the two paths cannot drift.
    static let readOnly = CredentialRestriction(actions: [readPattern], node: nil)

    var isUnrestricted: Bool { self == .unrestricted }

    /// Whether this restriction covers `action` on a resource whose ancestor
    /// chain is `chain` (leaf first, the checked node at index 0 — the shape
    /// `CedarEntitySlice.chain` carries).
    ///
    /// Identity-plane *reads* are exempt from the node half. A user record is
    /// parentless by design (`IAMNodeType.user`), so its chain is one element
    /// long and could never contain a project — without this exemption a
    /// project-scoped credential could not read its own user record, and
    /// `strato whoami` and the frontend's identity bootstrap would break for
    /// every scoped token.
    ///
    /// The exemption stops at reads. `user:update` and `user:delete` are
    /// parentless for the same structural reason, but exempting them would let
    /// a credential scoped to one project mutate or delete any user in the
    /// deployment — the identity plane would be the one global surface a scoped
    /// token could still reach. The action half applies throughout.
    func permits(action: String, chain: [IAMNode]) -> Bool {
        guard permits(action: action) else { return false }
        guard let node else { return true }
        if IAMRoleRegistry.identityReadActions.contains(action) { return true }
        return chain.contains(node)
    }

    /// The action half on its own, for the node-less platform surfaces
    /// (`Request.allowsScopelessPlatformRow`) where there is no resource to
    /// scope against.
    func permits(action: String) -> Bool {
        if actions.contains(Self.readPattern), IAMRoleRegistry.readActions.contains(action) { return true }
        return GuardrailRendering.patternsCover(actions, action: action)
    }

    /// The restriction a pre-STR-115 credential resolves to, from its legacy
    /// `scopes` column.
    ///
    /// `write` and `admin` both mean unrestricted, which is the honest reading
    /// of what they did: `APIKeyScope.required(for:)` never asked for `admin`,
    /// so `read`+`write` was already full account power. `read` maps to the
    /// `read` pattern — the closest expressible statement of "safe methods
    /// only", now checked against the act rather than the HTTP verb, and the
    /// *same* value a credential minted read-only through the API carries.
    init(legacyScopes: [String]) {
        let granted = Set(legacyScopes.compactMap(APIKeyScope.init(rawValue:)))
        if granted.contains(.write) || granted.contains(.admin) {
            self = .unrestricted
        } else if granted.contains(.read) {
            self = .readOnly
        } else {
            self = .denyAll
        }
    }

    private init(actions: [String], node: IAMNode?) {
        self.actions = actions
        self.node = node
    }

    /// The restriction stored on a credential row, or nil when the row predates
    /// STR-115 and its legacy scopes should be read instead.
    init?(storedActions: [String]?, nodeType: String?, nodeID: UUID?) {
        guard let storedActions else { return nil }
        var node: IAMNode?
        if let nodeType, let nodeID {
            guard let type = IAMNodeType(rawValue: nodeType) else { return nil }
            node = IAMNode(type: type, id: nodeID)
        }
        self.init(actions: storedActions, node: node)
    }

    /// Validate a caller-supplied restriction for storage.
    ///
    /// - Throws: a `400` for an empty action list, an unknown action or service
    ///   prefix (via `GuardrailActions.canonicalize`), an unknown node type, or
    ///   a half-specified node.
    static func validated(actions: [String], nodeType: String?, nodeID: UUID?) throws -> Self {
        let trimmed = actions.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !trimmed.isEmpty else {
            throw Abort(
                .badRequest,
                reason:
                    "A credential restriction must name at least one action; use \"*\" for an unrestricted credential"
            )
        }
        // `read` is this vocabulary's, not the guardrail vocabulary's, so it is
        // held back from `canonicalize` — which would reject it as an unknown
        // action — and merged after. Canonicalizing an empty remainder would
        // hand back `["*"]` (the broadest *ceiling*), so a `read`-only list
        // skips the call entirely.
        let concrete = trimmed.filter { $0 != readPattern }
        let symbolic = trimmed.contains(readPattern) ? [readPattern] : []
        let canonicalConcrete = concrete.isEmpty ? [] : try GuardrailActions.canonicalize(concrete)
        let canonical =
            canonicalConcrete.contains(GuardrailActions.wildcard)
            ? [GuardrailActions.wildcard]
            : (canonicalConcrete + symbolic).sorted()

        var node: IAMNode?
        switch (nodeType, nodeID) {
        case (nil, nil):
            node = nil
        case (let type?, let id?):
            guard let parsed = IAMNodeType(rawValue: type) else {
                throw Abort(.badRequest, reason: "Unknown resource type '\(type)' in credential restriction")
            }
            node = IAMNode(type: parsed, id: id)
        default:
            throw Abort(
                .badRequest,
                reason: "A credential restriction's node scope needs both a resource type and an id")
        }
        return CredentialRestriction(actions: canonical, node: node)
    }

    /// Whether `other` permits nothing this restriction does not — the test a
    /// credential must pass before minting another. A restricted credential
    /// cannot issue one wider than itself, or narrowing would be a formality.
    ///
    /// Deliberately conservative on the node half: deciding that one node
    /// contains another needs the tree, and refusing a mint that a chain walk
    /// might have allowed only ever costs the caller a second, narrower
    /// request. So an unscoped restriction covers any scope, and a scoped one
    /// covers only the identical scope.
    func covers(_ other: CredentialRestriction) -> Bool {
        guard other.actions.allSatisfy({ coversPattern($0) }) else { return false }
        guard let node else { return true }
        return node == other.node
    }

    /// Whether this restriction's patterns cover everything `pattern` names.
    /// An open-ended pattern (`service:*`, `read`) is covered only by `*` or by
    /// itself: enumerating today's members would silently stop covering the
    /// ones shipped next.
    private func coversPattern(_ pattern: String) -> Bool {
        if actions.contains(GuardrailActions.wildcard) { return true }
        if pattern == GuardrailActions.wildcard { return false }
        if pattern == Self.readPattern { return actions.contains(Self.readPattern) }
        if pattern.hasSuffix(":*") { return actions.contains(pattern) }
        return permits(action: pattern)
    }
}

// MARK: - Wire shape

/// A restriction as a client states it, on credential creation or device
/// approval.
///
/// `role` is sugar for the role's action list, and it is **expanded at write
/// time** rather than stored as a reference: a credential must not widen
/// because somebody later edited the role it was minted from. What the caller
/// approved is what the credential keeps.
struct CredentialRestrictionPayload: Content, Equatable {
    /// A role whose actions the credential is limited to. Mutually exclusive
    /// with `actions`.
    var role: UUID?
    /// Action patterns (`vm:read`, `vm:*`, `*`). Mutually exclusive with
    /// `role`.
    var actions: [String]?
    /// The subtree the credential may act in. Both fields or neither.
    var nodeType: String?
    var nodeID: UUID?

    init(role: UUID? = nil, actions: [String]? = nil, nodeType: String? = nil, nodeID: UUID? = nil) {
        self.role = role
        self.actions = actions
        self.nodeType = nodeType
        self.nodeID = nodeID
    }

    /// The stored restriction as a client sees it back.
    init(_ restriction: CredentialRestriction) {
        self.role = nil
        self.actions = restriction.actions
        self.nodeType = restriction.node?.type.rawValue
        self.nodeID = restriction.node?.id
    }
}

extension CredentialRestriction {
    /// Resolve a client-stated restriction into the value to store.
    ///
    /// - Parameter issuer: the restriction of the credential making the
    ///   request. A restricted credential may only mint one it already covers —
    ///   otherwise narrowing would be a formality, since any token could mint
    ///   an unrestricted successor.
    static func resolve(
        _ payload: CredentialRestrictionPayload,
        issuedUnder issuer: CredentialRestriction,
        on db: any Database
    ) async throws -> CredentialRestriction {
        guard payload.role == nil || payload.actions == nil else {
            throw Abort(
                .badRequest,
                reason: "A credential restriction names either a role or an action list, not both")
        }

        let actions: [String]
        if let roleID = payload.role {
            guard let role = try await IAMRoleDefinition.find(roleID, on: db) else {
                throw Abort(.badRequest, reason: "Unknown role '\(roleID)' in credential restriction")
            }
            guard !role.actions.isEmpty else {
                throw Abort(
                    .badRequest,
                    reason: "Role '\(role.name)' grants no actions, so a credential restricted to it could do nothing")
            }
            actions = role.actions
        } else {
            actions = payload.actions ?? []
        }

        let restriction = try validated(actions: actions, nodeType: payload.nodeType, nodeID: payload.nodeID)
        guard issuer.covers(restriction) else {
            throw Abort(
                .forbidden,
                reason: "This credential is restricted and cannot issue one with broader access than its own")
        }
        return restriction
    }
}

// MARK: - The three credential rows that store one

/// A credential row carrying a restriction: `APIKey`, `CLISession`,
/// `DeviceAuthorization`. The columns are nullable and the legacy `scopes`
/// column is still there, so one place decides which of the two a row means.
protocol CredentialRestrictionStoring: AnyObject {
    var scopes: [String] { get }
    var restrictionActions: [String]? { get set }
    var restrictionNodeType: String? { get set }
    var restrictionNodeID: UUID? { get set }
}

extension CredentialRestrictionStoring {
    /// What this credential may do. Rows written before STR-115 have no
    /// restriction columns and resolve through the legacy scope shim.
    var restriction: CredentialRestriction {
        CredentialRestriction(
            storedActions: restrictionActions, nodeType: restrictionNodeType, nodeID: restrictionNodeID)
            ?? CredentialRestriction(legacyScopes: scopes)
    }

    /// Store `restriction`, or clear the columns (falling back to the legacy
    /// scopes) when nil.
    func store(restriction: CredentialRestriction?) {
        restrictionActions = restriction?.actions
        restrictionNodeType = restriction?.node?.type.rawValue
        restrictionNodeID = restriction?.node?.id
    }
}

// MARK: - Which credential a request arrived on

/// The credential a request authenticated with, for decision-log attribution.
/// Session-cookie and SVID requests have none.
struct CredentialReference: Equatable, Sendable {
    enum Kind: String, Sendable {
        case apiKey = "api_key"
        case cliSession = "cli_session"
    }

    let kind: Kind
    let id: UUID?
}
