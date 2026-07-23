import Fluent
import Foundation
import Vapor

/// Reads, writes, and evaluates tier-2 guardrails (issue #479).
///
/// Two responsibilities that belong together because they must not drift:
///
/// - **The write path** is where "forbid-only" and the fixed vocabulary are
///   enforced. Every rejection here is a `400` — a malformed ceiling is a bad
///   request, the same way illegal parentage is (docs/architecture/iam.md,
///   tier 0).
/// - **The evaluation path** answers "which ceilings forbid this?" by
///   collecting every guardrail along the resource's ancestry chain. They
///   intersect: the answer is a *list*, and any non-empty list is a denial.
///
/// Shipped ahead of the evaluator (#480/#482) as the store and the semantics,
/// so the Cedar integration and the symcc write-time check (#484) build on
/// something already tested; since cutover the evaluator enforces these
/// ceilings on every request.
enum GuardrailStore {

    /// The node types a guardrail may attach to.
    ///
    /// Containers only. A ceiling exists to cover everything beneath it, and a
    /// leaf resource has nothing beneath it — a "ceiling" there would be an
    /// ordinary per-resource rule wearing tier 2's clothes, and it would let
    /// someone place a rule the resource's own admins cannot see coming from
    /// above.
    static let attachableNodeTypes: Set<IAMNodeType> = [.organization, .organizationalUnit, .project]

    // MARK: - Write path

    /// Reject anything that is not a forbid.
    ///
    /// The API takes an `effect` so a client sending `permit` gets told what is
    /// wrong, instead of the field being ignored and the caller believing a
    /// grant was created. Omitting it means `forbid`, since that is the only
    /// thing a guardrail can be.
    static func validateEffect(_ effect: String?) throws {
        guard let effect else { return }
        guard effect.lowercased() == GuardrailEffect.forbid.rawValue else {
            throw GuardrailError.permitRejected(effect)
        }
    }

    /// The Cedar `forbid` a matcher-built guardrail compiles to, resolving the
    /// attach node's organization for an external-principal ceiling (the one
    /// input the assembler cannot derive on its own).
    ///
    /// This is the single generation path since #610 — the write path stores
    /// its result, the boot backfill fills a null column with it, and the
    /// controller's DTO renders it — so what is stored, shown, and enforced
    /// cannot drift. Nil for a row the assembler skips (an unknown node type, or
    /// an external ceiling whose attach node resolves to no organization): the
    /// same rows the compiled set leaves out.
    static func generateCedarText(for guardrail: Guardrail, on db: any Database) async throws -> String? {
        guard let id = guardrail.id, let node = guardrail.node else { return nil }
        var organizationIDsByGuardrail: [UUID: UUID] = [:]
        if guardrail.principalMatchKind == GuardrailPrincipalMatchKind.externalToOrganization.rawValue {
            let chain = try await IAMResourceTree.ancestors(of: node, on: db)
            if let organization = chain.first(where: { $0.type == .organization }) {
                organizationIDsByGuardrail[id] = organization.id
            }
        }
        let compiled = CedarPolicyAssembler.guardrailPolicyText(
            [guardrail], organizationIDsByGuardrail: organizationIDsByGuardrail)
        return compiled.policies.first?.text
    }

    /// Create a matcher-built guardrail, validating the whole shape first and
    /// storing the Cedar forbid it assembles to.
    ///
    /// The id is allocated up front because the assembled forbid embeds it
    /// (`@id("guardrail-<id>")`); generating the text before the first save
    /// keeps the stored column populated in one round trip.
    ///
    /// The caller is responsible for bumping the policy-set version in the
    /// same transaction — see `GuardrailController`.
    static func create(
        name: String,
        description: String?,
        effect: String?,
        node: IAMNode,
        actions: [String],
        principalMatch: GuardrailPrincipalMatch,
        resourceMatch: GuardrailResourceMatch,
        enabled: Bool = true,
        createdBy: UUID?,
        on db: any Database
    ) async throws -> Guardrail {
        try validateEffect(effect)
        guard attachableNodeTypes.contains(node.type) else {
            throw GuardrailError.unattachableNode(node.type.rawValue)
        }
        let canonicalActions = try GuardrailActions.canonicalize(actions)
        try validateNotSelfLocking(
            actions: canonicalActions, principalMatch: principalMatch, resourceMatch: resourceMatch)

        let guardrail = Guardrail(
            id: UUID(),
            name: name,
            description: description,
            nodeType: node.type,
            nodeID: node.id,
            actions: canonicalActions,
            principalMatch: principalMatch,
            resourceMatch: resourceMatch,
            authored: false,
            enabled: enabled,
            createdBy: createdBy
        )
        guardrail.cedarText = try await generateCedarText(for: guardrail, on: db)
        do {
            try await guardrail.create(on: db)
        } catch let error as any DatabaseError where error.isConstraintFailure {
            throw GuardrailError.duplicateName(name)
        }
        return guardrail
    }

    /// Create a guardrail from a hand-authored Cedar forbid (#610), held to the
    /// guardrail shape by `GuardrailText`.
    ///
    /// The matcher columns are inert placeholders on an authored row — the
    /// stored `cedar_text` is the whole story, and `authored` tells every reader
    /// (the cache, the write-time check, who-can) to trust it rather than the
    /// matchers.
    static func createAuthored(
        name: String,
        description: String?,
        node: IAMNode,
        cedarText: String,
        enabled: Bool = true,
        createdBy: UUID?,
        engine: any CedarEngine,
        on db: any Database
    ) async throws -> Guardrail {
        guard attachableNodeTypes.contains(node.type) else {
            throw GuardrailError.unattachableNode(node.type.rawValue)
        }
        let id = UUID()
        let prepared = try await GuardrailText.prepare(
            cedarText: cedarText, guardrailID: id, attachNode: node, engine: engine, on: db)

        let guardrail = Guardrail(
            id: id,
            name: name,
            description: description,
            nodeType: node.type,
            nodeID: node.id,
            actions: [GuardrailActions.wildcard],
            principalMatch: .any,
            resourceMatch: .any,
            cedarText: prepared.cedarText,
            authored: true,
            enabled: enabled,
            createdBy: createdBy
        )
        do {
            try await guardrail.create(on: db)
        } catch let error as any DatabaseError where error.isConstraintFailure {
            throw GuardrailError.duplicateName(name)
        }
        return guardrail
    }

    /// The action that removes a guardrail. A ceiling covering this one is a
    /// ceiling that can outlaw its own removal.
    static let policyWriteAction = "iam:setPolicy"

    /// Refuse the ceilings nobody can climb back out of.
    ///
    /// A guardrail that applies to **every** principal on **every** resource
    /// and forbids `iam:setPolicy` denies the one action needed to disable or
    /// delete it, on its own subtree and everything below. `*` is the obvious
    /// spelling, but `iam:*` and a bare `iam:setPolicy` bolt the same door, so
    /// the test is whether the action patterns *match* `iam:setPolicy` rather
    /// than whether they equal the wildcard.
    ///
    /// Conditioned ceilings on `iam:setPolicy` stay legal and are useful
    /// ("contractors may not set policy here"): someone outside the condition
    /// can still undo them. It is only the unconditional form that leaves no
    /// one holding the key.
    private static func validateNotSelfLocking(
        actions: [String],
        principalMatch: GuardrailPrincipalMatch,
        resourceMatch: GuardrailResourceMatch
    ) throws {
        guard principalMatch == .any, resourceMatch == .any else { return }
        guard GuardrailActions.matches(actions, action: policyWriteAction) else { return }
        throw GuardrailError.locksOutPolicyAdministration
    }

    /// Apply a partial update. Only the fields present are touched; the effect
    /// is not updatable, because there is nothing to change it to, and neither
    /// is the attach node — moving a ceiling changes which subtree it covers,
    /// which is a different guardrail, not an edit to this one.
    ///
    /// A guardrail's input mode is fixed at creation: a matcher row is edited
    /// through its matchers (the stored forbid is regenerated), an authored row
    /// through its `cedarText` (re-validated). Sending the other mode's fields
    /// is a `400` rather than a silent no-op — the caller thinks it changed
    /// something.
    static func update(
        _ guardrail: Guardrail,
        description: String?,
        actions: [String]?,
        principalMatch: GuardrailPrincipalMatch?,
        resourceMatch: GuardrailResourceMatch?,
        cedarText: String?,
        enabled: Bool?,
        engine: any CedarEngine,
        on db: any Database
    ) async throws -> Guardrail {
        if let description { guardrail.description = description }
        if let enabled { guardrail.enabled = enabled }

        if guardrail.authored {
            guard actions == nil, principalMatch == nil, resourceMatch == nil else {
                throw GuardrailError.modeMismatch(
                    "This guardrail was authored as Cedar text; edit it through 'cedarText', not the structured matchers."
                )
            }
            if let cedarText {
                guard let node = guardrail.node, let id = guardrail.id else {
                    throw GuardrailError.rejectedByCedar("guardrail row is missing its id or node")
                }
                let prepared = try await GuardrailText.prepare(
                    cedarText: cedarText, guardrailID: id, attachNode: node, engine: engine, on: db)
                guardrail.cedarText = prepared.cedarText
            }
        } else {
            guard cedarText == nil else {
                throw GuardrailError.modeMismatch(
                    "This guardrail is assembled from matchers; edit its matchers, or delete it and create an authored guardrail to write Cedar directly."
                )
            }
            if let actions { guardrail.actions = try GuardrailActions.canonicalize(actions) }
            if let principalMatch {
                guardrail.principalMatchKind = principalMatch.kind.rawValue
                guardrail.principalMatchID = principalMatch.subjectID
            }
            if let resourceMatch {
                guardrail.resourceMatchKind = resourceMatch.kind.rawValue
                guardrail.resourceMatchValue = resourceMatch.value
            }
            try validateNotSelfLocking(
                actions: guardrail.actions,
                principalMatch: try guardrail.principalMatch(),
                resourceMatch: try guardrail.resourceMatch()
            )
            // Regenerate the stored forbid from the (possibly changed) matchers,
            // so the source of truth tracks them.
            guardrail.cedarText = try await generateCedarText(for: guardrail, on: db)
        }

        try await guardrail.save(on: db)
        return guardrail
    }

    // MARK: - Read path

    /// The guardrails attached directly to a node, enabled or not — what an
    /// admin of that node manages.
    static func attached(to node: IAMNode, on db: any Database) async throws -> [Guardrail] {
        try await Guardrail.query(on: db)
            .filter(\.$nodeType == node.type.rawValue)
            .filter(\.$nodeID == node.id)
            .sort(\.$name)
            .all()
    }

    /// Every enabled guardrail in force at `node`: those attached to it and
    /// those attached to anything above it.
    ///
    /// All of them apply. There is no precedence rule to consult and no
    /// "nearest wins" — ceilings intersect, so the effective ceiling is the
    /// conjunction of the whole chain.
    static func effective(at node: IAMNode, on db: any Database) async throws -> [Guardrail] {
        let chain = try await IAMResourceTree.ancestors(of: node, on: db)
        return try await effective(along: chain, on: db)
    }

    /// `effective(at:)` for a chain the caller already walked.
    static func effective(along chain: [IAMNode], on db: any Database) async throws -> [Guardrail] {
        guard !chain.isEmpty else { return [] }
        return try await Guardrail.query(on: db)
            .filter(\.$enabled == true)
            .group(.or) { anyNode in
                for node in chain {
                    anyNode.group(.and) { thisNode in
                        thisNode.filter(\.$nodeType == node.type.rawValue)
                        thisNode.filter(\.$nodeID == node.id)
                    }
                }
            }
            .sort(\.$name)
            .all()
    }

    // MARK: - Evaluation

    /// Every guardrail that forbids `principal` performing `action` on `node`.
    ///
    /// Returns all of them rather than the first: a denial should be able to
    /// name every ceiling in the way, or removing one guardrail looks like it
    /// will unblock a request that the next one still blocks.
    static func forbidding(
        action: String,
        principalType: IAMPrincipalType,
        principalID: UUID,
        node: IAMNode,
        on db: any Database
    ) async throws -> [Guardrail] {
        let chain = try await IAMResourceTree.ancestors(of: node, on: db)
        let candidates = try await effective(along: chain, on: db)
        guard !candidates.isEmpty else { return [] }

        let environment = try await resourceEnvironment(of: node, on: db)
        let organizationID = chain.first(where: { $0.type == .organization })?.id

        var matched: [Guardrail] = []
        for guardrail in candidates {
            // Authored rows (#610) carry placeholder matchers — their forbid is
            // the stored Cedar text, which the structured matchers here cannot
            // stand in for. They are reflected by evaluating the compiled set
            // instead (`CeilingEvaluator`), so skip them rather than match on a
            // meaningless `.any`.
            guard !guardrail.authored else { continue }
            guard GuardrailActions.matches(guardrail.actions, action: action) else { continue }
            guard try matches(try guardrail.resourceMatch(), environment: environment) else { continue }
            guard
                try await matches(
                    try guardrail.principalMatch(),
                    principalType: principalType,
                    principalID: principalID,
                    organizationID: organizationID,
                    on: db
                )
            else { continue }
            matched.append(guardrail)
        }
        return matched
    }

    private static func matches(_ match: GuardrailResourceMatch, environment: String?) throws -> Bool {
        switch match {
        case .any:
            return true
        case .environment(let wanted):
            // A resource with no environment attribute is not in any
            // environment, so an environment ceiling does not reach it.
            return environment == wanted
        }
    }

    /// Whether a guardrail's principal side covers this principal.
    ///
    /// Shared with the write-time ceiling check (#484), which resolves the
    /// principal side here rather than symbolically: group membership and org
    /// membership are facts in the database, and a symbolic solver told
    /// nothing about them would have to assume every principal *might* be in
    /// every group — reporting a violation for grants no ceiling touches. The
    /// symbolic part is what is genuinely open: which resource, which action,
    /// which environment.
    static func principalMatches(
        _ match: GuardrailPrincipalMatch,
        principalType: IAMPrincipalType,
        principalID: UUID,
        organizationID: UUID?,
        on db: any Database
    ) async throws -> Bool {
        try await matches(
            match, principalType: principalType, principalID: principalID,
            organizationID: organizationID, on: db)
    }

    private static func matches(
        _ match: GuardrailPrincipalMatch,
        principalType: IAMPrincipalType,
        principalID: UUID,
        organizationID: UUID?,
        on db: any Database
    ) async throws -> Bool {
        switch match {
        case .any:
            return true

        case .user(let id):
            return principalType == .user && principalID == id

        case .group(let id):
            if principalType == .group { return principalID == id }
            // A ceiling on a group covers its members: the group is how the
            // grant reaches the user, so it has to be how the ceiling does too.
            let memberships = try await UserGroup.query(on: db)
                .filter(\.$user.$id == principalID)
                .filter(\.$group.$id == id)
                .count()
            return memberships > 0

        case .externalToOrganization:
            // Without a resolvable organization there is no "outside" to be
            // on, and guessing would mean forbidding on a truncated tree walk.
            guard let organizationID else { return false }
            switch principalType {
            case .user:
                let memberships = try await UserOrganization.query(on: db)
                    .filter(\.$user.$id == principalID)
                    .filter(\.$organization.$id == organizationID)
                    .count()
                return memberships == 0
            case .group:
                guard let group = try await Group.find(principalID, on: db) else { return false }
                return group.$organization.id != organizationID
            case .serviceAccount, .workload:
                // Machine principals are members of nothing (issue #491), so
                // an external-principal ceiling always covers them — matching
                // the compiled forbid's `is User`-guarded membership test.
                return true
            }
        }
    }

    /// The `environment` attribute of a resource, for resource-side matching.
    ///
    /// Every type that stores one has to be listed, or an environment ceiling
    /// silently stops covering that type — a snapshot of a production sandbox
    /// is as much a production resource as the sandbox. Containers are absent
    /// because they genuinely have no environment: it is an attribute, never a
    /// container.
    ///
    /// Shared with `EntitySliceLoader` (#480), which stamps the same attribute
    /// onto the Cedar entity so the compiled environment ceilings match
    /// exactly what this store's own evaluation matches.
    static func resourceEnvironment(of node: IAMNode, on db: any Database) async throws -> String? {
        switch node.type {
        case .virtualMachine:
            return try await VM.find(node.id, on: db)?.environment
        case .sandbox:
            return try await Sandbox.find(node.id, on: db)?.environment
        case .sandboxSnapshot:
            return try await SandboxSnapshot.find(node.id, on: db)?.environment
        case .organization, .organizationalUnit, .project, .image, .network,
            .floatingIP, .securityGroup, .volume, .volumeSnapshot, .site, .agent, .serviceAccount:
            // Listed exhaustively rather than defaulted: a new resource type
            // carrying an environment should fail to compile here, not quietly
            // fall out of every environment ceiling.
            return nil
        }
    }
}
