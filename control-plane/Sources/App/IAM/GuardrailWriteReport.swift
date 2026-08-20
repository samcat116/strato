import ControlPlanePostgres
import Fluent
import Foundation
import Vapor

// IAM phase 7 (issue #484): the write-time ceiling report.
//
// On a tier-3 binding write, ask which tier-2 ceilings narrow the grant it
// creates, and say so in the response. Eval-time enforcement is what makes the
// ceiling bite — a denial three days later names no cause, and this is where
// the cause is still in front of the person who created it
// (docs/architecture/iam.md, "The write-time ceiling report").
//
// **It reports; it does not refuse** (STR-110, issue #864). It used to refuse,
// and the two rules disagreed: the evaluator subtracts the ceilinged actions
// and leaves the rest of the grant working, while the write-time check refused
// the whole binding over a single overlap. Since the seeded roles are broad action
// groups, one `forbid vm:stop` on an organization made `operator`, `editor`
// and `admin` ungrantable everywhere beneath it — an identical binding was
// legal to hold and illegal to create. Ceilings only subtract, at both ends.
//
// The analysis runs only here, on binding and guardrail writes: rare, and
// latency-tolerant in a way the request path is not.

/// A binding about to be written, as the report sees it.
///
/// The report works over the role's action set, not the role's identity, so a
/// custom role reaches it the same way a seeded one does (issue #608): the
/// `IAMRole` initializer expands the registry, and the general initializer
/// takes an action set and a label directly.
struct ProposedBinding: Sendable {
    let principalType: IAMPrincipalType
    let principalID: UUID
    /// The full expanded action set the role grants — the overlap analysis's
    /// input.
    let roleActions: Set<String>
    /// A human-readable name for the role, for logs and the explanation.
    let roleLabel: String
    let node: IAMNode

    /// A seeded role: actions from the registry, label from the role name.
    init(principalType: IAMPrincipalType, principalID: UUID, role: IAMRole, node: IAMNode) {
        self.init(
            principalType: principalType,
            principalID: principalID,
            roleActions: IAMRoleRegistry.actions(for: role),
            roleLabel: role.rawValue,
            node: node
        )
    }

    /// Any role, seeded or custom: its action set and a display label supplied
    /// directly.
    init(
        principalType: IAMPrincipalType,
        principalID: UUID,
        roleActions: Set<String>,
        roleLabel: String,
        node: IAMNode
    ) {
        self.principalType = principalType
        self.principalID = principalID
        self.roleActions = roleActions
        self.roleLabel = roleLabel
        self.node = node
    }
}

/// What a grant write returns: the ceilings in force that narrow it.
///
/// Empty `ceilings` is the normal case, and means the grant is unconstrained
/// where it was written. A non-empty list is not a failure — the binding exists
/// and confers everything the listed ceilings do not take back.
struct GrantWriteResponse: Content {
    let ceilings: [GuardrailWriteReport.GrantCeiling]
    /// Why the analysis could not run, when it could not.
    ///
    /// Without this, an empty `ceilings` says both "nothing narrows this grant"
    /// and "nobody looked", and only a server log tells them apart — while the
    /// person who can act on the difference is the one holding the response.
    /// The grant lands either way: ceilings are enforced at evaluation, and
    /// this report has never been what enforces them.
    let analysisUnavailable: String?

    /// Nothing to analyze — the write created no binding.
    static let noBinding = GrantWriteResponse(ceilings: [], analysisUnavailable: nil)
}

/// Raised when the analysis ran out of wall clock.
///
/// Not an `AbortError`: nothing is refused over it, and by the time it is
/// thrown the write has already committed. It reaches the caller, which names
/// it in `analysisUnavailable` — an expired report must not read as an
/// all-clear.
struct GuardrailAnalysisExpired: Error, CustomStringConvertible {
    let budget: Duration
    let guardrail: String

    var description: String {
        "the ceiling analysis exceeded its \(budget) budget at guardrail '\(guardrail)'"
    }
}

enum GuardrailWriteReport {

    /// Wall clock the whole report gets, across every candidate ceiling.
    ///
    /// The analysis is one solver invocation per reachable resource type per
    /// candidate ceiling, and ceilings inherit, so a deep node with several
    /// above it can stack invocations onto a response whose write already
    /// committed and no longer depends on them. Bounding it trades a rare
    /// explanation for a bounded response; the budget is checked between
    /// invocations, so the worst case is this plus one `SymCCGuardrailAnalyzer`
    /// timeout.
    static let analysisBudget: Duration = .seconds(15)

    // MARK: - Binding writes

    /// A ceiling that narrows a grant just written — the write-time half of
    /// the `ceilinged` mark `who-can` shows on an existing one.
    struct GrantCeiling: Content, Sendable {
        /// `folder/engineering/no-prod-for-contractors` — the attach node and
        /// the guardrail's name, so the reader knows where to go to change it.
        let guardrail: String
        /// `alice@acme (organization admin)`, when the author is still
        /// resolvable.
        let setBy: String?
        /// What the grant does that the ceiling forbids, in the vocabulary the
        /// ceiling was written in.
        let explanation: String
        /// The actions this ceiling takes back out of the role — the whole
        /// point of reporting rather than refusing: one action of thirty-four,
        /// not the grant.
        let ceilingedActions: [String]
        /// A concrete request the grant allows and the ceiling forbids, as the
        /// solver found it. Diagnostic rather than prose — it is what
        /// distinguishes "the analysis says so" from "the analysis says so,
        /// here."
        let counterexample: String?
    }

    /// The response body for a grant that has just been written: the ceilings
    /// that narrow it, or why nobody could say.
    ///
    /// Call from the request handler *after* the transaction that writes the
    /// binding: the analysis spawns solver processes, holding a database
    /// transaction open across that is a cost with no benefit, and nothing
    /// here can change whether the write happens.
    ///
    /// Best-effort by design. Eval-time enforcement is exact and always in
    /// force, so an absent, failing, or too-slow solver costs an explanation,
    /// never a grant — the same posture the shadow report takes on a guardrail
    /// write, and the opposite of the `503` this path returned while it still
    /// refused writes. What is *not* best-effort is saying which happened:
    /// a failure is named in `analysisUnavailable` rather than rendered as an
    /// all-clear.
    static func report(for binding: ProposedBinding, req: Request) async -> GrantWriteResponse {
        let found: [GrantCeiling]
        do {
            found = try await ceilings(
                narrowing: binding,
                analyzer: req.application.guardrailAnalyzer,
                on: req.db,
                logger: req.logger
            )
        } catch {
            req.logger.error(
                "Could not report the ceilings narrowing a role binding",
                metadata: [
                    "role": .string(binding.roleLabel),
                    "node": .string("\(binding.node.type.rawValue)/\(binding.node.id)"),
                    "error": .string("\(error)"),
                ])
            return GrantWriteResponse(ceilings: [], analysisUnavailable: "\(error)")
        }
        for ceiling in found {
            req.logger.notice(
                "Granted a role binding a guardrail narrows",
                metadata: [
                    "guardrail": .string(ceiling.guardrail),
                    "role": .string(binding.roleLabel),
                    "node": .string("\(binding.node.type.rawValue)/\(binding.node.id)"),
                    "ceilinged_actions": .string(ceiling.ceilingedActions.joined(separator: ", ")),
                ])
        }
        return GrantWriteResponse(ceilings: found, analysisUnavailable: nil)
    }

    static func report(
        for binding: ProposedBinding,
        using iam: IAMPersistence,
        groups: GroupsPersistence,
        hierarchy: HierarchyPersistence,
        projects: ProjectsPersistence,
        users: UserDirectoryPersistence,
        req: Request
    ) async -> GrantWriteResponse {
        let found: [GrantCeiling]
        do {
            found = try await ceilings(
                narrowing: binding,
                analyzer: req.application.guardrailAnalyzer,
                using: iam,
                groups: groups,
                hierarchy: hierarchy,
                projects: projects,
                users: users,
                logger: req.logger
            )
        } catch {
            req.logger.error(
                "Could not report the ceilings narrowing a role binding",
                metadata: [
                    "role": .string(binding.roleLabel),
                    "node": .string("\(binding.node.type.rawValue)/\(binding.node.id)"),
                    "error": .string("\(error)"),
                ]
            )
            return GrantWriteResponse(ceilings: [], analysisUnavailable: "\(error)")
        }
        for ceiling in found {
            req.logger.notice(
                "Granted a role binding a guardrail narrows",
                metadata: [
                    "guardrail": .string(ceiling.guardrail),
                    "role": .string(binding.roleLabel),
                    "node": .string("\(binding.node.type.rawValue)/\(binding.node.id)"),
                    "ceilinged_actions": .string(ceiling.ceilingedActions.joined(separator: ", ")),
                ]
            )
        }
        return GrantWriteResponse(ceilings: found, analysisUnavailable: nil)
    }

    /// Every ceiling that narrows `binding`.
    ///
    /// All of them, not the first: removing one guardrail must not look like
    /// it will free a grant the next one still narrows — the same rule
    /// `GuardrailStore.forbidding` follows at evaluation time.
    static func ceilings(
        narrowing binding: ProposedBinding,
        analyzer: any GuardrailAnalyzer,
        on db: any Database,
        logger: Logger
    ) async throws -> [GrantCeiling] {
        let deadline = ContinuousClock.now + analysisBudget
        let chain = try await IAMResourceTree.ancestors(of: binding.node, on: db)
        // Matcher-built ceilings only. An authored ceiling's principal side is
        // free-form Cedar this report cannot resolve against the database — the
        // exactness that keeps the matcher path from inventing memberships the
        // solver was never told about (see `applies`). Rather than name a
        // ceiling on a symbolic guess, authored ceilings rely on eval-time
        // enforcement, which is exact and always in force. The trade-off is an
        // authored ceiling gives no *write-time* explanation; the eval-time
        // denial still names it (#610).
        let candidates = try await GuardrailStore.effective(along: chain, on: db)
            .filter { !$0.authored }
        guard !candidates.isEmpty else { return [] }
        let organizationID = chain.first(where: { $0.type == .organization })?.id

        var ceilings: [GrantCeiling] = []
        for guardrail in candidates {
            // An unrenderable row narrows nothing here: it matches nobody in
            // the compiled set either, and the cache logs it loudly on every
            // rebuild. (`GuardrailStore.forbidding` makes the opposite,
            // fail-closed choice — see `GuardrailRendering` for why each
            // surface chooses.)
            guard let rendering = try? GuardrailRendering(guardrail) else { continue }
            guard
                try await applies(
                    rendering, to: binding, organizationID: organizationID, on: db)
            else { continue }
            guard
                let overlap = try await overlap(
                    between: binding, and: rendering, analyzer: analyzer,
                    deadline: deadline, logger: logger)
            else { continue }
            ceilings.append(
                try await describe(guardrail, binding: binding, overlap: overlap, on: db))
        }
        return ceilings
    }

    static func ceilings(
        narrowing binding: ProposedBinding,
        analyzer: any GuardrailAnalyzer,
        using iam: IAMPersistence,
        groups: GroupsPersistence,
        hierarchy: HierarchyPersistence,
        projects: ProjectsPersistence,
        users: UserDirectoryPersistence,
        logger: Logger
    ) async throws -> [GrantCeiling] {
        let deadline = ContinuousClock.now + analysisBudget
        let chain = try await IAMResourceTree.ancestors(of: binding.node, using: iam)
        let candidates = try await GuardrailStore.effective(along: chain, using: iam)
            .filter { !$0.authored }
        guard !candidates.isEmpty else { return [] }
        let organizationID = chain.first(where: { $0.type == .organization })?.id

        var ceilings: [GrantCeiling] = []
        for guardrail in candidates {
            guard let rendering = try? GuardrailRendering(guardrail) else { continue }
            guard
                try await applies(
                    rendering,
                    to: binding,
                    organizationID: organizationID,
                    using: iam,
                    groups: groups
                )
            else { continue }
            guard
                let overlap = try await overlap(
                    between: binding,
                    and: rendering,
                    analyzer: analyzer,
                    deadline: deadline,
                    logger: logger
                )
            else { continue }
            ceilings.append(
                try await describe(
                    guardrail,
                    binding: binding,
                    overlap: overlap,
                    hierarchy: hierarchy,
                    projects: projects,
                    users: users
                )
            )
        }
        return ceilings
    }

    // MARK: - Guardrail writes

    /// The active bindings a newly written guardrail now shadows.
    ///
    /// Guardrail writes are *not* refused over these: subtracting from
    /// existing grants is precisely a ceiling's job, and a ceiling that could
    /// not be imposed until every grant beneath it was cleaned up first would
    /// be unusable during the incident it was written for. They are reported
    /// so the author sees what they just took away, and audited so it is on
    /// the record.
    static func shadowedBindings(
        by guardrail: IAMGuardrailSnapshot,
        analyzer: any GuardrailAnalyzer,
        on db: any Database,
        logger: Logger
    ) async throws -> [ShadowedBinding] {
        let deadline = ContinuousClock.now + analysisBudget
        guard guardrail.enabled, !guardrail.authored,
            let rendering = try? GuardrailRendering(guardrail)
        else { return [] }
        let organizationID = try await IAMResourceTree.ancestors(of: rendering.node, on: db)
            .first(where: { $0.type == .organization })?.id

        var shadowed: [ShadowedBinding] = []
        for candidate in try await LegacyRoleBindingStore.bindings(activeAt: Date(), on: db) {
            guard let role = IAMRole(seededID: candidate.roleID),
                let nodeType = IAMNodeType(rawValue: candidate.nodeType),
                let principalType = IAMPrincipalType(rawValue: candidate.principalType)
            else { continue }
            let bindingNode = IAMNode(type: nodeType, id: candidate.nodeID)
            let chain = try await IAMResourceTree.ancestors(of: bindingNode, on: db)
            guard chain.contains(rendering.node) else { continue }

            let binding = ProposedBinding(
                principalType: principalType,
                principalID: candidate.principalID,
                role: role,
                node: bindingNode
            )
            guard try await applies(rendering, to: binding, organizationID: organizationID, on: db)
            else { continue }
            guard
                try await overlap(
                    between: binding,
                    and: rendering,
                    analyzer: analyzer,
                    deadline: deadline,
                    logger: logger
                ) != nil
            else { continue }
            shadowed.append(
                ShadowedBinding(
                    principalType: principalType,
                    principalID: candidate.principalID,
                    role: role,
                    node: bindingNode
                ))
        }
        return shadowed
    }

    static func shadowedBindings(
        by guardrail: IAMGuardrailSnapshot,
        analyzer: any GuardrailAnalyzer,
        using iam: IAMPersistence,
        groups: GroupsPersistence,
        hierarchy: HierarchyPersistence,
        projects: ProjectsPersistence,
        users: UserDirectoryPersistence,
        logger: Logger
    ) async throws -> [ShadowedBinding] {
        let deadline = ContinuousClock.now + analysisBudget
        guard guardrail.enabled, !guardrail.authored,
            let rendering = try? GuardrailRendering(guardrail)
        else { return [] }
        let organizationID = try await IAMResourceTree.ancestors(
            of: rendering.node,
            using: iam
        ).first(where: { $0.type == .organization })?.id

        let candidates = try await iam.allActiveBindings()
        let typed = candidates.compactMap { candidate -> (IAMRoleBindingSnapshot, IAMNode)? in
            guard IAMRole(seededID: candidate.roleID) != nil,
                let nodeType = IAMNodeType(rawValue: candidate.nodeType),
                IAMPrincipalType(rawValue: candidate.principalType) != nil
            else { return nil }
            return (candidate, IAMNode(type: nodeType, id: candidate.nodeID))
        }
        let resolutions = try await IAMResourceTree.resolve(typed.map { $0.1 }, using: iam)

        var shadowed: [ShadowedBinding] = []
        for (candidate, bindingNode) in typed {
            guard let role = IAMRole(seededID: candidate.roleID),
                let principalType = IAMPrincipalType(rawValue: candidate.principalType),
                resolutions[bindingNode]?.chain.contains(rendering.node) == true
            else { continue }
            let binding = ProposedBinding(
                principalType: principalType,
                principalID: candidate.principalID,
                role: role,
                node: bindingNode
            )
            guard
                try await applies(
                    rendering,
                    to: binding,
                    organizationID: organizationID,
                    using: iam,
                    groups: groups
                )
            else { continue }
            guard
                try await overlap(
                    between: binding,
                    and: rendering,
                    analyzer: analyzer,
                    deadline: deadline,
                    logger: logger
                ) != nil
            else { continue }
            shadowed.append(
                ShadowedBinding(
                    principalType: principalType,
                    principalID: candidate.principalID,
                    role: role,
                    node: bindingNode
                )
            )
        }
        return shadowed
    }

    /// A binding a guardrail write has just narrowed.
    struct ShadowedBinding: Content, Sendable {
        let principalType: IAMPrincipalType
        let principalID: UUID
        let role: IAMRole
        let node: IAMNode
    }

    // MARK: - The principal side, resolved concretely

    /// Whether the ceiling reaches the principal `binding` grants to.
    ///
    /// Resolved from the database rather than symbolically — the rendering's
    /// structural principal projection. Group and org membership are facts; a
    /// solver told nothing about them would assume every principal might be in
    /// every group and report a violation for grants no ceiling touches. What
    /// stays symbolic is what is genuinely open at write time — which resource
    /// beneath the node, which action in the role, which environment.
    ///
    /// The group-binding cases are this report's own question, wider than the
    /// rendering's "does this principal match": a group binding reaches the
    /// group's members, so the ceiling reaches the grant if it covers the
    /// group itself *or anyone in it*.
    private static func applies(
        _ rendering: GuardrailRendering,
        to binding: ProposedBinding,
        organizationID: UUID?,
        using iam: IAMPersistence,
        groups: GroupsPersistence
    ) async throws -> Bool {
        switch binding.principalType {
        case .user:
            return try await rendering.covers(
                principalType: .user,
                principalID: binding.principalID,
                organizationID: organizationID,
                using: iam,
                groups: groups
            )
        case .group:
            switch rendering.principalMatch {
            case .any:
                return true
            case .group(let ceilingGroupID):
                if ceilingGroupID == binding.principalID { return true }
                return try await groups.groupsShareMember(binding.principalID, ceilingGroupID)
            case .user(let userID):
                return try await groups.hasMember(userID: userID, groupID: binding.principalID)
            case .externalToOrganization:
                guard let organizationID else { return false }
                return try await groups.hasMemberOutsideOrganization(
                    groupID: binding.principalID,
                    organizationID: organizationID
                )
            }
        case .serviceAccount, .workload:
            switch rendering.principalMatch {
            case .any, .externalToOrganization:
                return true
            case .user, .group:
                return false
            }
        }
    }

    private static func applies(
        _ rendering: GuardrailRendering,
        to binding: ProposedBinding,
        organizationID: UUID?,
        on db: any Database
    ) async throws -> Bool {
        switch binding.principalType {
        case .user:
            return try await rendering.covers(
                principalType: .user,
                principalID: binding.principalID,
                organizationID: organizationID,
                on: db
            )

        case .group:
            switch rendering.principalMatch {
            case .any:
                return true
            case .group(let ceilingGroupID):
                if ceilingGroupID == binding.principalID { return true }
                return try await sharesMember(binding.principalID, ceilingGroupID, on: db)
            case .user(let userID):
                return try await LegacyGroupSQLBridge.hasMember(
                    userID: userID, groupID: binding.principalID, on: db)
            case .externalToOrganization:
                guard let organizationID else { return false }
                return try await hasMemberOutside(
                    organizationID, of: binding.principalID, on: db)
            }

        case .serviceAccount, .workload:
            // A machine principal is in no group and a member of no org — so
            // a user- or group-scoped ceiling never reaches it, and an
            // external-principal ceiling always does (matching the compiled
            // forbid, whose membership test is `is User`-guarded).
            switch rendering.principalMatch {
            case .any, .externalToOrganization:
                return true
            case .user, .group:
                return false
            }
        }
    }

    private static func sharesMember(_ a: UUID, _ b: UUID, on db: any Database) async throws -> Bool {
        try await LegacyGroupSQLBridge.groupsShareMember(a, b, on: db)
    }

    private static func hasMemberOutside(
        _ organizationID: UUID, of groupID: UUID, on db: any Database
    ) async throws -> Bool {
        try await LegacyGroupSQLBridge.hasMemberOutsideOrganization(
            groupID: groupID, organizationID: organizationID, on: db)
    }

    // MARK: - The symbolic side

    /// What a ceiling takes out of a grant.
    private struct Overlap {
        /// The role's actions this ceiling subtracts — covered by its action
        /// scope *and* able to reach a resource type it can match. Everything
        /// else in the role still stands.
        let actions: [String]
        /// A concrete request the grant allows and the ceiling forbids.
        let counterexample: String
    }

    /// Ask the solver whether the grant and the ceiling can meet, and on what.
    ///
    /// Returns the overlap when they can, `nil` when they provably cannot. A
    /// `nil` here is a proof, not an absence of evidence.
    private static func overlap(
        between binding: ProposedBinding,
        and rendering: GuardrailRendering,
        analyzer: any GuardrailAnalyzer,
        deadline: ContinuousClock.Instant,
        logger: Logger
    ) async throws -> Overlap? {
        // The action side is decided here, over the finite registry: a role's
        // action set and a ceiling's patterns are both enumerable, so asking a
        // solver would be paying for an answer we already have.
        let overlapping = binding.roleActions.filter { rendering.covers(action: $0) }.sorted()
        guard !overlapping.isEmpty else { return nil }

        // What is left genuinely needs the solver: can a resource exist that
        // sits under *both* the binding's node and the ceiling's attach node,
        // and satisfies the ceiling's resource conditions?
        //
        // That question does not depend on which of the overlapping actions is
        // asked about — only on the resource type, since `appliesTo` is what
        // ties an action to a type. So one query per reachable resource type,
        // with any overlapping action as its representative. The enumeration
        // is complete, not sampled: no ceiling is skipped for cost, and no
        // type is skipped either — see the accumulation below.
        let reachable = Set(CedarSchemaBuilder.descendantTypes(of: binding.node.type.cedarEntityType))
        var representatives: [CedarEntityType: String] = [:]
        for action in overlapping {
            for type in CedarSchemaBuilder.resourceTypes(for: action)
            where reachable.contains(type) && representatives[type] == nil {
                representatives[type] = action
            }
        }
        guard !representatives.isEmpty else { return nil }

        // The seeded descriptors, not the database's rows: the only thing the
        // roles list contributes to the schema is one `Grants` field pair per
        // role, and neither policy rendered below reads `context.grants` — the
        // grant is written as the permit it amounts to. Building from the
        // registry keeps the analysis off the database and deterministic.
        let schemaText = CedarSchemaBuilder.schemaText(roles: RoleDescriptor.seededDefaults())
        // The ceiling as the permit it scopes to — the rendering's
        // solver-facing projection, carrying the same action and resource
        // clauses as the compiled forbid by construction.
        let ceiling = rendering.permit()

        // The environment's principal type mirrors the binding's: a group
        // grant is exercised by its member users, and machine principals form
        // their own request environments.
        let principalType: CedarEntityType
        switch binding.principalType {
        case .user, .group: principalType = .user
        case .serviceAccount: principalType = .serviceAccount
        case .workload: principalType = .workload
        }
        // Every reachable type is asked about, rather than stopping at the
        // first one that comes back non-disjoint: the answers decide *which
        // actions are reported*, and an action whose reachable types are all
        // provably disjoint is not one this ceiling takes back. Stopping early
        // would attribute the first hit's verdict to actions nobody asked
        // about — the same over-broad claim this report exists to stop making,
        // moved from the status code into the body.
        var narrowedTypes: Set<CedarEntityType> = []
        var counterexample: String?
        for (resourceType, action) in representatives.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            // Checked between queries, so the worst case is the budget plus one
            // solver timeout — bounded, which unbounded stacking of solver
            // calls onto an already-committed write is not.
            guard ContinuousClock.now < deadline else {
                throw GuardrailAnalysisExpired(budget: analysisBudget, guardrail: rendering.name)
            }
            let environment = CedarRequestEnvironment(
                principalType: principalType, action: action, resourceType: resourceType)
            let grant = grantPolicy(binding, action: action)
            let analysis: GuardrailAnalysis
            do {
                analysis = try await analyzer.disjoint(
                    schemaText: schemaText, [grant], [ceiling], in: environment)
            } catch let error as GuardrailAnalyzerError {
                logger.error(
                    "Write-time guardrail analysis failed",
                    metadata: [
                        "guardrail": .string(rendering.name),
                        "action": .string(action),
                        "resource_type": .string(resourceType.rawValue),
                        "error": .string("\(error)"),
                    ])
                throw error
            }
            if !analysis.holds {
                narrowedTypes.insert(resourceType)
                // The first one found, in the sorted enumeration, so the
                // reported counterexample is deterministic.
                counterexample =
                    counterexample ?? analysis.counterexample ?? "\(action) on \(resourceType.rawValue)"
            }
        }
        guard let counterexample else { return nil }
        return Overlap(
            actions: overlapping.filter { action in
                CedarSchemaBuilder.resourceTypes(for: action).contains(where: narrowedTypes.contains)
            },
            counterexample: counterexample
        )
    }

    /// The proposed binding as the policy it amounts to.
    ///
    /// Bindings are not policies in the compiled set — they arrive as
    /// `context.grants` and the static role policies test membership in them
    /// (`CedarPolicyAssembler`). To ask what one *reaches*, it has to be
    /// written as the permit it is equivalent to.
    ///
    /// The principal scope is left open on purpose: whether this ceiling
    /// covers this principal was already settled against the database, and
    /// restating it symbolically would only let the solver invent memberships
    /// nobody has.
    ///
    /// The action side names the one action the environment fixes, rather than
    /// the role's whole expanded list. Roles are flat since issue #604, so
    /// there is no schema action group to stand in for the list — and a
    /// literal list would carry actions that do not apply to the environment's
    /// resource type, which strict validation rejects. Restricting to the
    /// asked-about action loses nothing: the environment already pins it, and
    /// the caller enumerates one environment per overlapping action.
    private static func grantPolicy(_ binding: ProposedBinding, action: String) -> CedarPolicySource {
        CedarPolicySource(
            id: "proposed-binding",
            text: """
                @id("proposed-binding")
                permit (
                    principal,
                    action == Action::\(CedarText.stringLiteral(action)),
                    resource in \(binding.node.cedarUID.cedarLiteral)
                );
                """
        )
    }

    // MARK: - Rendering

    /// Turn a narrowed grant into the response body the design specifies.
    private static func describe(
        _ guardrail: IAMGuardrailSnapshot,
        binding: ProposedBinding,
        overlap: Overlap,
        on db: any Database
    ) async throws -> GrantCeiling {
        let node = guardrail.node
        let path: String
        if let node, let name = try await nodeName(node, on: db) {
            path = "\(node.type.rawValue)/\(name)/\(guardrail.name)"
        } else {
            path = guardrail.name
        }

        var setBy: String?
        if let createdBy = guardrail.createdBy, let author = try await User.find(createdBy, on: db) {
            let authority = node.map { "\($0.type.rawValue) admin" } ?? "admin"
            setBy = "\(author.email) (\(authority))"
        }

        return GrantCeiling(
            guardrail: path,
            setBy: setBy,
            explanation: reasonText(guardrail, binding: binding),
            ceilingedActions: overlap.actions,
            counterexample: overlap.counterexample
        )
    }

    private static func describe(
        _ guardrail: IAMGuardrailSnapshot,
        binding: ProposedBinding,
        overlap: Overlap,
        hierarchy: HierarchyPersistence,
        projects: ProjectsPersistence,
        users: UserDirectoryPersistence
    ) async throws -> GrantCeiling {
        let node = guardrail.node
        let path: String
        if let node, let name = try await nodeName(
            node,
            hierarchy: hierarchy,
            projects: projects
        ) {
            path = "\(node.type.rawValue)/\(name)/\(guardrail.name)"
        } else {
            path = guardrail.name
        }

        var setBy: String?
        if let createdBy = guardrail.createdBy, let author = try await users.user(id: createdBy) {
            let authority = node.map { "\($0.type.rawValue) admin" } ?? "admin"
            setBy = "\(author.email) (\(authority))"
        }

        return GrantCeiling(
            guardrail: path,
            setBy: setBy,
            explanation: reasonText(guardrail, binding: binding),
            ceilingedActions: overlap.actions,
            counterexample: overlap.counterexample
        )
    }

    /// The prose half of the answer, written in the vocabulary the ceiling was
    /// authored in — the reader has to be able to match it against the
    /// guardrail they can see in the UI.
    private static func reasonText(
        _ guardrail: IAMGuardrailSnapshot,
        binding: ProposedBinding
    ) -> String {
        var reason = "grants \(binding.roleLabel) on \(binding.node.type.rawValue) resources"
        if let match = try? guardrail.resourceMatch(), case .environment(let environment) = match {
            reason += " tagged \"\(environment)\""
        }
        switch try? guardrail.principalMatch() {
        case .group(let id):
            reason += " to principals in group \(id)"
        case .user(let id):
            reason += " to user \(id)"
        case .externalToOrganization:
            reason += " to principals outside the organization"
        case .any, .none:
            reason += " to a principal the ceiling covers"
        }
        reason += "; the ceiling forbids \(guardrail.actions.joined(separator: ", ")) here"
        return reason
    }

    private static func nodeName(_ node: IAMNode, on db: any Database) async throws -> String? {
        switch node.type {
        case .organization:
            return try await Organization.find(node.id, on: db)?.name
        case .organizationalUnit:
            return try await OrganizationalUnit.find(node.id, on: db)?.name
        case .project:
            return try await Project.find(node.id, on: db)?.name
        default:
            // Guardrails only attach to containers (`GuardrailStore`), so
            // nothing else should reach here; the id alone still identifies it.
            return nil
        }
    }

    private static func nodeName(
        _ node: IAMNode,
        hierarchy: HierarchyPersistence,
        projects: ProjectsPersistence
    ) async throws -> String? {
        switch node.type {
        case .organization:
            return try await hierarchy.organization(id: node.id)?.name
        case .organizationalUnit:
            return try await hierarchy.organizationalUnit(id: node.id)?.organizationalUnit.name
        case .project:
            return try await projects.project(id: node.id)?.name
        default:
            return nil
        }
    }
}
