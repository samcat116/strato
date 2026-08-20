import ControlPlanePostgres
import Fluent
import Foundation
import Vapor

/// Reads, writes, and evaluates tier-2 guardrails (issue #479).
///
/// - **The write path** is where "forbid-only" and the fixed vocabulary are
///   enforced. Every rejection here is a `400` — a malformed ceiling is a bad
///   request, the same way illegal parentage is (docs/architecture/iam.md,
///   tier 0).
/// - **The evaluation path** answers "which ceilings forbid this?" by
///   collecting every guardrail along the resource's ancestry chain. They
///   intersect: the answer is a *list*, and any non-empty list is a denial.
///
/// What a single guardrail row *means* — its Cedar forbid, and whether it
/// covers a given principal/action/resource — is not decided here: every
/// consumer projects the row through `GuardrailRendering`, so the store's
/// answers, the compiled set, and the write-time check cannot drift. This
/// store owns the row lifecycle and the tree-walking orchestration around
/// those projections.
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
    ) async throws -> IAMGuardrailSnapshot {
        try validateEffect(effect)
        guard attachableNodeTypes.contains(node.type) else {
            throw GuardrailError.unattachableNode(node.type.rawValue)
        }
        let canonicalActions = try GuardrailActions.canonicalize(actions)
        try validateNotSelfLocking(
            actions: canonicalActions, principalMatch: principalMatch, resourceMatch: resourceMatch)

        let provisional = IAMGuardrailSnapshot(
            id: UUID(),
            name: name,
            description: description,
            nodeType: node.type.rawValue,
            nodeID: node.id,
            effect: GuardrailEffect.forbid.rawValue,
            actions: canonicalActions,
            principalMatchKind: principalMatch.kind.rawValue,
            principalMatchID: principalMatch.subjectID,
            resourceMatchKind: resourceMatch.kind.rawValue,
            resourceMatchValue: resourceMatch.value,
            enabled: enabled,
            createdBy: createdBy,
            cedarText: nil,
            authored: false
        )
        let guardrail = IAMGuardrailSnapshot(
            id: provisional.id,
            name: provisional.name,
            description: provisional.description,
            nodeType: provisional.nodeType,
            nodeID: provisional.nodeID,
            effect: provisional.effect,
            actions: provisional.actions,
            principalMatchKind: provisional.principalMatchKind,
            principalMatchID: provisional.principalMatchID,
            resourceMatchKind: provisional.resourceMatchKind,
            resourceMatchValue: provisional.resourceMatchValue,
            enabled: provisional.enabled,
            createdBy: provisional.createdBy,
            cedarText: try await GuardrailRendering.cedarText(for: provisional, on: db),
            authored: provisional.authored
        )
        do {
            return try await LegacyGuardrailStore.insert(guardrail, on: db)
        } catch let error as any DatabaseError where error.isConstraintFailure {
            throw GuardrailError.duplicateName(name)
        }
    }

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
        using iam: IAMPersistence,
        in transaction: IAMPolicySetTransaction,
    ) async throws -> IAMGuardrailSnapshot {
        try validateEffect(effect)
        guard attachableNodeTypes.contains(node.type) else {
            throw GuardrailError.unattachableNode(node.type.rawValue)
        }
        let canonicalActions = try GuardrailActions.canonicalize(actions)
        try validateNotSelfLocking(
            actions: canonicalActions,
            principalMatch: principalMatch,
            resourceMatch: resourceMatch
        )

        let provisional = IAMGuardrailSnapshot(
            id: UUID(),
            name: name,
            description: description,
            nodeType: node.type.rawValue,
            nodeID: node.id,
            effect: GuardrailEffect.forbid.rawValue,
            actions: canonicalActions,
            principalMatchKind: principalMatch.kind.rawValue,
            principalMatchID: principalMatch.subjectID,
            resourceMatchKind: resourceMatch.kind.rawValue,
            resourceMatchValue: resourceMatch.value,
            enabled: enabled,
            createdBy: createdBy,
            cedarText: nil,
            authored: false
        )
        let rendered = try await GuardrailRendering.cedarText(for: provisional, using: iam)
        let guardrail = IAMGuardrailSnapshot(
            id: provisional.id,
            name: provisional.name,
            description: provisional.description,
            nodeType: provisional.nodeType,
            nodeID: provisional.nodeID,
            effect: provisional.effect,
            actions: provisional.actions,
            principalMatchKind: provisional.principalMatchKind,
            principalMatchID: provisional.principalMatchID,
            resourceMatchKind: provisional.resourceMatchKind,
            resourceMatchValue: provisional.resourceMatchValue,
            enabled: provisional.enabled,
            createdBy: provisional.createdBy,
            cedarText: rendered,
            authored: provisional.authored
        )
        do {
            return try await transaction.createGuardrail(guardrail)
        } catch IAMPersistenceError.duplicateGuardrailName {
            throw GuardrailError.duplicateName(name)
        }
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
    ) async throws -> IAMGuardrailSnapshot {
        guard attachableNodeTypes.contains(node.type) else {
            throw GuardrailError.unattachableNode(node.type.rawValue)
        }
        let id = UUID()
        let prepared = try await GuardrailText.prepare(
            cedarText: cedarText, guardrailID: id, attachNode: node, engine: engine, on: db)

        let guardrail = IAMGuardrailSnapshot(
            id: id,
            name: name,
            description: description,
            nodeType: node.type.rawValue,
            nodeID: node.id,
            effect: GuardrailEffect.forbid.rawValue,
            actions: [GuardrailActions.wildcard],
            principalMatchKind: GuardrailPrincipalMatchKind.any.rawValue,
            principalMatchID: nil,
            resourceMatchKind: GuardrailResourceMatchKind.any.rawValue,
            resourceMatchValue: nil,
            enabled: enabled,
            createdBy: createdBy,
            cedarText: prepared.cedarText,
            authored: true
        )
        do {
            return try await LegacyGuardrailStore.insert(guardrail, on: db)
        } catch let error as any DatabaseError where error.isConstraintFailure {
            throw GuardrailError.duplicateName(name)
        }
    }

    static func createAuthored(
        name: String,
        description: String?,
        node: IAMNode,
        cedarText: String,
        enabled: Bool = true,
        createdBy: UUID?,
        engine: any CedarEngine,
        using iam: IAMPersistence,
        in transaction: IAMPolicySetTransaction
    ) async throws -> IAMGuardrailSnapshot {
        guard attachableNodeTypes.contains(node.type) else {
            throw GuardrailError.unattachableNode(node.type.rawValue)
        }
        let id = UUID()
        let prepared = try await GuardrailText.prepare(
            cedarText: cedarText,
            guardrailID: id,
            attachNode: node,
            engine: engine,
            using: iam
        )
        let guardrail = IAMGuardrailSnapshot(
            id: id,
            name: name,
            description: description,
            nodeType: node.type.rawValue,
            nodeID: node.id,
            effect: GuardrailEffect.forbid.rawValue,
            actions: [GuardrailActions.wildcard],
            principalMatchKind: GuardrailPrincipalMatchKind.any.rawValue,
            principalMatchID: nil,
            resourceMatchKind: GuardrailResourceMatchKind.any.rawValue,
            resourceMatchValue: nil,
            enabled: enabled,
            createdBy: createdBy,
            cedarText: prepared.cedarText,
            authored: true
        )
        do {
            return try await transaction.createGuardrail(guardrail)
        } catch IAMPersistenceError.duplicateGuardrailName {
            throw GuardrailError.duplicateName(name)
        }
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
        guard GuardrailRendering.patternsCover(actions, action: policyWriteAction) else { return }
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
        _ guardrail: IAMGuardrailSnapshot,
        description: String?,
        actions: [String]?,
        principalMatch: GuardrailPrincipalMatch?,
        resourceMatch: GuardrailResourceMatch?,
        cedarText: String?,
        enabled: Bool?,
        engine: any CedarEngine,
        on db: any Database
    ) async throws -> IAMGuardrailSnapshot {
        var updatedDescription = guardrail.description
        var updatedActions = guardrail.actions
        var updatedPrincipal = try guardrail.principalMatch()
        var updatedResource = try guardrail.resourceMatch()
        var updatedCedarText = guardrail.cedarText

        if let description { updatedDescription = description }

        if guardrail.authored {
            guard actions == nil, principalMatch == nil, resourceMatch == nil else {
                throw GuardrailError.modeMismatch(
                    "This guardrail was authored as Cedar text; edit it through 'cedarText', not the structured matchers."
                )
            }
            if let cedarText {
                guard let node = guardrail.node else {
                    throw GuardrailError.rejectedByCedar("guardrail row names an unknown node type")
                }
                let prepared = try await GuardrailText.prepare(
                    cedarText: cedarText,
                    guardrailID: guardrail.id,
                    attachNode: node,
                    engine: engine,
                    on: db
                )
                updatedCedarText = prepared.cedarText
            }
        } else {
            guard cedarText == nil else {
                throw GuardrailError.modeMismatch(
                    "This guardrail is assembled from matchers; edit its matchers, or delete it and create an authored guardrail to write Cedar directly."
                )
            }
            if let actions { updatedActions = try GuardrailActions.canonicalize(actions) }
            if let principalMatch { updatedPrincipal = principalMatch }
            if let resourceMatch { updatedResource = resourceMatch }
            try validateNotSelfLocking(
                actions: updatedActions,
                principalMatch: updatedPrincipal,
                resourceMatch: updatedResource
            )
        }

        var replacement = IAMGuardrailSnapshot(
            id: guardrail.id,
            name: guardrail.name,
            description: updatedDescription,
            nodeType: guardrail.nodeType,
            nodeID: guardrail.nodeID,
            effect: guardrail.effect,
            actions: updatedActions,
            principalMatchKind: updatedPrincipal.kind.rawValue,
            principalMatchID: updatedPrincipal.subjectID,
            resourceMatchKind: updatedResource.kind.rawValue,
            resourceMatchValue: updatedResource.value,
            enabled: enabled ?? guardrail.enabled,
            createdBy: guardrail.createdBy,
            createdAt: guardrail.createdAt,
            updatedAt: guardrail.updatedAt,
            cedarText: updatedCedarText,
            authored: guardrail.authored
        )
        if !replacement.authored {
            let rendered = try await GuardrailRendering.cedarText(for: replacement, on: db)
            replacement = IAMGuardrailSnapshot(
                id: replacement.id,
                name: replacement.name,
                description: replacement.description,
                nodeType: replacement.nodeType,
                nodeID: replacement.nodeID,
                effect: replacement.effect,
                actions: replacement.actions,
                principalMatchKind: replacement.principalMatchKind,
                principalMatchID: replacement.principalMatchID,
                resourceMatchKind: replacement.resourceMatchKind,
                resourceMatchValue: replacement.resourceMatchValue,
                enabled: replacement.enabled,
                createdBy: replacement.createdBy,
                createdAt: replacement.createdAt,
                updatedAt: replacement.updatedAt,
                cedarText: rendered,
                authored: replacement.authored
            )
        }
        do {
            guard let saved = try await LegacyGuardrailStore.replace(replacement, on: db) else {
                throw Abort(.notFound, reason: "Guardrail not found")
            }
            return saved
        } catch let error as any DatabaseError where error.isConstraintFailure {
            throw GuardrailError.duplicateName(guardrail.name)
        }
    }

    static func update(
        _ guardrail: IAMGuardrailSnapshot,
        description: String?,
        actions: [String]?,
        principalMatch: GuardrailPrincipalMatch?,
        resourceMatch: GuardrailResourceMatch?,
        cedarText: String?,
        enabled: Bool?,
        engine: any CedarEngine,
        using iam: IAMPersistence,
        in transaction: IAMPolicySetTransaction
    ) async throws -> IAMGuardrailSnapshot {
        var updatedDescription = guardrail.description
        var updatedActions = guardrail.actions
        var updatedPrincipal = try guardrail.principalMatch()
        var updatedResource = try guardrail.resourceMatch()
        var updatedCedarText = guardrail.cedarText

        if let description { updatedDescription = description }
        if guardrail.authored {
            guard actions == nil, principalMatch == nil, resourceMatch == nil else {
                throw GuardrailError.modeMismatch(
                    "This guardrail was authored as Cedar text; edit it through 'cedarText', not the structured matchers."
                )
            }
            if let cedarText {
                guard let node = guardrail.node else {
                    throw GuardrailError.rejectedByCedar("guardrail row names an unknown node type")
                }
                updatedCedarText = try await GuardrailText.prepare(
                    cedarText: cedarText,
                    guardrailID: guardrail.id,
                    attachNode: node,
                    engine: engine,
                    using: iam
                ).cedarText
            }
        } else {
            guard cedarText == nil else {
                throw GuardrailError.modeMismatch(
                    "This guardrail is assembled from matchers; edit its matchers, or delete it and create an authored guardrail to write Cedar directly."
                )
            }
            if let actions { updatedActions = try GuardrailActions.canonicalize(actions) }
            if let principalMatch { updatedPrincipal = principalMatch }
            if let resourceMatch { updatedResource = resourceMatch }
            try validateNotSelfLocking(
                actions: updatedActions,
                principalMatch: updatedPrincipal,
                resourceMatch: updatedResource
            )
        }

        var replacement = IAMGuardrailSnapshot(
            id: guardrail.id,
            name: guardrail.name,
            description: updatedDescription,
            nodeType: guardrail.nodeType,
            nodeID: guardrail.nodeID,
            effect: guardrail.effect,
            actions: updatedActions,
            principalMatchKind: updatedPrincipal.kind.rawValue,
            principalMatchID: updatedPrincipal.subjectID,
            resourceMatchKind: updatedResource.kind.rawValue,
            resourceMatchValue: updatedResource.value,
            enabled: enabled ?? guardrail.enabled,
            createdBy: guardrail.createdBy,
            createdAt: guardrail.createdAt,
            updatedAt: guardrail.updatedAt,
            cedarText: updatedCedarText,
            authored: guardrail.authored
        )
        if !replacement.authored {
            let rendered = try await GuardrailRendering.cedarText(for: replacement, using: iam)
            replacement = IAMGuardrailSnapshot(
                id: replacement.id,
                name: replacement.name,
                description: replacement.description,
                nodeType: replacement.nodeType,
                nodeID: replacement.nodeID,
                effect: replacement.effect,
                actions: replacement.actions,
                principalMatchKind: replacement.principalMatchKind,
                principalMatchID: replacement.principalMatchID,
                resourceMatchKind: replacement.resourceMatchKind,
                resourceMatchValue: replacement.resourceMatchValue,
                enabled: replacement.enabled,
                createdBy: replacement.createdBy,
                createdAt: replacement.createdAt,
                updatedAt: replacement.updatedAt,
                cedarText: rendered,
                authored: replacement.authored
            )
        }
        do {
            guard let saved = try await transaction.replaceGuardrail(replacement) else {
                throw Abort(.notFound, reason: "Guardrail not found")
            }
            return saved
        } catch IAMPersistenceError.duplicateGuardrailName {
            throw GuardrailError.duplicateName(guardrail.name)
        }
    }

    /// Boot-time backfill that populates `iam_guardrails.cedar_text` for rows
    /// written before #610 (IAM guardrails onto authored Cedar): the migration
    /// only adds the column, leaving `cedar_text` NULL on rows that pre-date
    /// it. This regenerates the text from each such row's matchers — the same
    /// rendering the write path stores — so the column becomes dense. Returns
    /// how many rows were populated.
    ///
    /// Idempotent — it only touches NULL rows — and it needs **no** policy-set
    /// version bump: regenerating from unchanged matchers is byte-identical to
    /// what the cache's null-fallback already compiles, so the compiled output
    /// does not change. That equivalence is exactly why the fallback is safe in
    /// the window before this runs, and why the fallback must stay: this
    /// densifies the column, it does not replace the fallback.
    ///
    /// Only matcher-built rows can be NULL here — an authored row always
    /// carries the text it was written with.
    @discardableResult
    static func backfillCedarText(on db: any Database, logger: Logger) async throws -> Int {
        let rows = try await LegacyGuardrailStore.missingCedarText(on: db)
        guard !rows.isEmpty else { return 0 }

        var filled = 0
        for row in rows {
            // A row the rendering skips (an unknown node type, or an external
            // ceiling whose attach node resolves to no organization) stays NULL
            // — the same row the compiled set leaves out either way — rather than
            // being written a text the generator refused to produce.
            guard let text = try await GuardrailRendering.cedarText(for: row, on: db) else { continue }
            if try await LegacyGuardrailStore.setCedarText(
                id: row.id,
                cedarText: text,
                onlyIfMissing: true,
                on: db
            ) {
                filled += 1
            }
        }
        if filled > 0 {
            logger.info(
                "Backfilled guardrail cedar_text from matchers",
                metadata: ["count": .stringConvertible(filled)])
        }
        return filled
    }

    @discardableResult
    static func backfillCedarText(
        using iam: IAMPersistence,
        hierarchyDB: any Database,
        logger: Logger
    ) async throws -> Int {
        let rows = try await iam.guardrailsMissingCedarText()
        guard !rows.isEmpty else { return 0 }

        var filled = 0
        for row in rows {
            guard let text = try await GuardrailRendering.cedarText(for: row, on: hierarchyDB) else {
                continue
            }
            if try await iam.backfillGuardrailCedarText(id: row.id, cedarText: text) {
                filled += 1
            }
        }
        if filled > 0 {
            logger.info(
                "Backfilled guardrail cedar_text from matchers",
                metadata: ["count": .stringConvertible(filled)])
        }
        return filled
    }

    // MARK: - Read path

    /// The guardrails attached directly to a node, enabled or not — what an
    /// admin of that node manages.
    static func attached(
        to node: IAMNode,
        on db: any Database
    ) async throws -> [IAMGuardrailSnapshot] {
        try await LegacyGuardrailStore.attached(to: node, on: db)
    }

    static func attached(
        to node: IAMNode,
        using iam: IAMPersistence
    ) async throws -> [IAMGuardrailSnapshot] {
        try await iam.guardrails(
            attachedTo: IAMNodeReference(type: node.type.rawValue, id: node.id)
        )
    }

    /// Every enabled guardrail in force at `node`: those attached to it and
    /// those attached to anything above it.
    ///
    /// All of them apply. There is no precedence rule to consult and no
    /// "nearest wins" — ceilings intersect, so the effective ceiling is the
    /// conjunction of the whole chain.
    static func effective(
        at node: IAMNode,
        on db: any Database
    ) async throws -> [IAMGuardrailSnapshot] {
        let chain = try await IAMResourceTree.ancestors(of: node, on: db)
        return try await effective(along: chain, on: db)
    }

    /// `effective(at:)` for a chain the caller already walked.
    static func effective(
        along chain: [IAMNode],
        on db: any Database
    ) async throws -> [IAMGuardrailSnapshot] {
        try await LegacyGuardrailStore.enabled(along: chain, on: db)
    }

    static func effective(
        along chain: [IAMNode],
        using iam: IAMPersistence
    ) async throws -> [IAMGuardrailSnapshot] {
        try await iam.enabledGuardrails(
            along: chain.map { IAMNodeReference(type: $0.type.rawValue, id: $0.id) }
        )
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
    ) async throws -> [IAMGuardrailSnapshot] {
        let resolution = try await IAMResourceTree.resolve(node, on: db)
        let chain = resolution.chain
        let candidates = try await effective(along: chain, on: db)
        guard !candidates.isEmpty else { return [] }

        // The walk already read the leaf row, so its environment comes back
        // with the chain instead of costing a second read of the same row.
        let environment = resolution.leaf.environment
        let organizationID = chain.first(where: { $0.type == .organization })?.id

        var matched: [IAMGuardrailSnapshot] = []
        for guardrail in candidates {
            // Authored rows (#610) carry placeholder matchers — their forbid is
            // the stored Cedar text, which the structured matchers here cannot
            // stand in for. They are reflected by evaluating the compiled set
            // instead (`IAMDecisionEngine`), so skip them rather than match on
            // a meaningless `.any`.
            guard !guardrail.authored else { continue }
            // A row we cannot parse must not quietly evaluate as "matches
            // nobody" — that would drop a ceiling on the floor — so the parse
            // error propagates and fails the whole check closed.
            let rendering = try GuardrailRendering(guardrail)
            guard rendering.covers(action: action) else { continue }
            guard rendering.covers(environment: environment) else { continue }
            guard
                try await rendering.covers(
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

    static func forbidding(
        action: String,
        principalType: IAMPrincipalType,
        principalID: UUID,
        node: IAMNode,
        using iam: IAMPersistence,
        hierarchyDB: any Database
    ) async throws -> [IAMGuardrailSnapshot] {
        let resolution = try await IAMResourceTree.resolve(node, on: hierarchyDB)
        let chain = resolution.chain
        let candidates = try await effective(along: chain, using: iam)
        guard !candidates.isEmpty else { return [] }

        let environment = resolution.leaf.environment
        let organizationID = chain.first(where: { $0.type == .organization })?.id
        var matched: [IAMGuardrailSnapshot] = []
        for guardrail in candidates {
            guard !guardrail.authored else { continue }
            let rendering = try GuardrailRendering(guardrail)
            guard rendering.covers(action: action) else { continue }
            guard rendering.covers(environment: environment) else { continue }
            guard
                try await rendering.covers(
                    principalType: principalType,
                    principalID: principalID,
                    organizationID: organizationID,
                    on: hierarchyDB
                )
            else { continue }
            matched.append(guardrail)
        }
        return matched
    }

}
