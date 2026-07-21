import Fluent
import Foundation
import Vapor

// IAM phase 7 (issue #484): the write-time ceiling check.
//
// Before accepting a tier-3 binding, ask whether the grant it creates can
// reach anything a tier-2 guardrail forbids. Eval-time enforcement stays —
// attributes change after a binding exists — but a denial three days later
// names no cause, and this is where the cause is still in front of the person
// who created it (docs/architecture/iam.md, "The write-time ceiling check").
//
// The analysis runs only here, on binding and guardrail writes: rare, and
// latency-tolerant in a way the request path is not.

/// A binding about to be written, as the check sees it.
struct ProposedBinding: Sendable {
    let principalType: IAMPrincipalType
    let principalID: UUID
    let role: IAMRole
    let node: IAMNode
}

/// A ceiling the proposed grant would breach.
///
/// Renders as the `403` the design specifies: which guardrail, who set it, and
/// why this grant runs into it. Naming all three is the entire difference
/// between this and the eval-time denial.
struct GuardrailViolation: Error, AbortError, Sendable {
    /// `folder/engineering/no-prod-for-contractors` — the attach node and the
    /// guardrail's name, so the reader knows where to go to change it.
    let guardrail: String
    /// `alice@acme (org admin)`, when the author is still resolvable.
    let setBy: String?
    /// What the grant does that the ceiling forbids, in the vocabulary the
    /// ceiling was written in.
    let explanation: String
    /// A concrete request the grant would allow and the ceiling would forbid,
    /// as the solver found it. Diagnostic rather than prose — it is what
    /// distinguishes "the analysis says so" from "the analysis says so, here."
    let counterexample: String?

    var status: HTTPResponseStatus { .forbidden }

    var reason: String {
        var lines = ["GuardrailViolation", "  guardrail: \(guardrail)"]
        if let setBy { lines.append("  set_by:    \(setBy)") }
        lines.append("  reason:    \(explanation)")
        return lines.joined(separator: "\n")
    }
}

/// Raised when the check itself could not run.
///
/// A `503`, not a `403`: the write is not being refused on its merits, it is
/// being refused because the ceiling could not be checked. Failing closed is
/// the deliberate posture — a deployment whose solver has gone missing stops
/// accepting the writes this check guards rather than accepting them
/// unchecked.
struct GuardrailCheckUnavailable: Error, AbortError {
    let detail: String

    var status: HTTPResponseStatus { .serviceUnavailable }
    var reason: String {
        """
        The write-time guardrail check could not run, so this policy write cannot be accepted: \(detail). \
        Existing access is unaffected; guardrails are still enforced on every request.
        """
    }
}

enum GuardrailWriteCheck {

    // MARK: - Binding writes

    /// Throw if `binding` would grant past a ceiling in force at its node.
    ///
    /// Call inside the request handler, *before* opening the transaction that
    /// writes the binding: the analysis spawns solver processes, and holding a
    /// database transaction open across that is a cost with no benefit — a
    /// concurrent guardrail write is caught by eval-time enforcement, which
    /// never went away.
    static func requireNoViolation(_ binding: ProposedBinding, req: Request) async throws {
        let found = try await violations(
            for: binding,
            analyzer: req.application.guardrailAnalyzer,
            on: req.db,
            logger: req.logger
        )
        guard let first = found.first else { return }
        req.logger.notice(
            "Refused a role binding that breaches a guardrail",
            metadata: [
                "guardrail": .string(first.guardrail),
                "role": .string(binding.role.rawValue),
                "node": .string("\(binding.node.type.rawValue)/\(binding.node.id)"),
            ])
        throw first
    }

    /// Every ceiling `binding` would breach.
    ///
    /// All of them, not the first: removing one guardrail must not look like
    /// it will unblock a grant the next one still stops — the same rule
    /// `GuardrailStore.forbidding` follows at evaluation time.
    static func violations(
        for binding: ProposedBinding,
        analyzer: any GuardrailAnalyzer,
        on db: any Database,
        logger: Logger
    ) async throws -> [GuardrailViolation] {
        let chain = try await IAMResourceTree.ancestors(of: binding.node, on: db)
        let candidates = try await GuardrailStore.effective(along: chain, on: db)
        guard !candidates.isEmpty else { return [] }
        let organizationID = chain.first(where: { $0.type == .organization })?.id

        var violations: [GuardrailViolation] = []
        for guardrail in candidates {
            guard
                try await applies(
                    guardrail, to: binding, organizationID: organizationID, on: db)
            else { continue }
            guard
                let overlap = try await overlap(
                    between: binding, and: guardrail, analyzer: analyzer, logger: logger)
            else { continue }
            violations.append(
                try await describe(guardrail, binding: binding, counterexample: overlap, on: db))
        }
        return violations
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
        by guardrail: Guardrail,
        analyzer: any GuardrailAnalyzer,
        on db: any Database,
        logger: Logger
    ) async throws -> [ShadowedBinding] {
        guard guardrail.enabled, let node = guardrail.node else { return [] }
        let organizationID = try await IAMResourceTree.ancestors(of: node, on: db)
            .first(where: { $0.type == .organization })?.id

        // Bindings beneath the attach node, found by walking each binding's
        // chain rather than by a subtree query: the tree has no closure table,
        // and a binding on a node whose chain does not reach here is simply
        // not covered.
        var shadowed: [ShadowedBinding] = []
        for candidate in try await RoleBinding.query(on: db).active().all() {
            guard let role = IAMRole(rawValue: candidate.role),
                let nodeType = IAMNodeType(rawValue: candidate.nodeType),
                let principalType = IAMPrincipalType(rawValue: candidate.principalType)
            else { continue }
            let bindingNode = IAMNode(type: nodeType, id: candidate.nodeID)
            let chain = try await IAMResourceTree.ancestors(of: bindingNode, on: db)
            guard chain.contains(node) else { continue }

            let binding = ProposedBinding(
                principalType: principalType,
                principalID: candidate.principalID,
                role: role,
                node: bindingNode
            )
            guard try await applies(guardrail, to: binding, organizationID: organizationID, on: db)
            else { continue }
            guard
                try await overlap(
                    between: binding, and: guardrail, analyzer: analyzer, logger: logger) != nil
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

    /// A binding a guardrail write has just narrowed.
    struct ShadowedBinding: Content, Sendable {
        let principalType: IAMPrincipalType
        let principalID: UUID
        let role: IAMRole
        let node: IAMNode
    }

    // MARK: - The principal side, resolved concretely

    /// Whether `guardrail` reaches the principal `binding` grants to.
    ///
    /// Resolved from the database rather than symbolically. Group and org
    /// membership are facts; a solver told nothing about them would assume
    /// every principal might be in every group and report a violation for
    /// grants no ceiling touches. What stays symbolic is what is genuinely
    /// open at write time — which resource beneath the node, which action in
    /// the role, which environment.
    private static func applies(
        _ guardrail: Guardrail,
        to binding: ProposedBinding,
        organizationID: UUID?,
        on db: any Database
    ) async throws -> Bool {
        let match: GuardrailPrincipalMatch
        do {
            match = try guardrail.principalMatch()
        } catch {
            // An unreadable row matches nobody, exactly as it does in
            // `GuardrailStore` and in the compiled policy set. The cache
            // already logs these loudly on every rebuild.
            return false
        }

        if binding.principalType == .user {
            return try await GuardrailStore.principalMatches(
                match,
                principalType: .user,
                principalID: binding.principalID,
                organizationID: organizationID,
                on: db
            )
        }

        // A group binding reaches the group's members, so the ceiling reaches
        // this grant if it covers the group itself or anyone in it.
        switch match {
        case .any:
            return true
        case .group(let ceilingGroupID):
            if ceilingGroupID == binding.principalID { return true }
            return try await sharesMember(binding.principalID, ceilingGroupID, on: db)
        case .user(let userID):
            let memberships = try await UserGroup.query(on: db)
                .filter(\.$user.$id == userID)
                .filter(\.$group.$id == binding.principalID)
                .count()
            return memberships > 0
        case .externalToOrganization:
            guard let organizationID else { return false }
            return try await hasMemberOutside(
                organizationID, of: binding.principalID, on: db)
        }
    }

    private static func sharesMember(_ a: UUID, _ b: UUID, on db: any Database) async throws -> Bool {
        let aMembers = try await UserGroup.query(on: db).filter(\.$group.$id == a).all()
            .map(\.$user.id)
        guard !aMembers.isEmpty else { return false }
        let shared = try await UserGroup.query(on: db)
            .filter(\.$group.$id == b)
            .filter(\.$user.$id ~~ aMembers)
            .count()
        return shared > 0
    }

    private static func hasMemberOutside(
        _ organizationID: UUID, of groupID: UUID, on db: any Database
    ) async throws -> Bool {
        let members = try await UserGroup.query(on: db).filter(\.$group.$id == groupID).all()
            .map(\.$user.id)
        guard !members.isEmpty else { return false }
        let inside = try await UserOrganization.query(on: db)
            .filter(\.$organization.$id == organizationID)
            .filter(\.$user.$id ~~ members)
            .count()
        return inside < members.count
    }

    // MARK: - The symbolic side

    /// Ask the solver whether the grant and the ceiling can meet, and on what.
    ///
    /// Returns the counterexample when they can, `nil` when they provably
    /// cannot. A `nil` here is a proof, not an absence of evidence.
    private static func overlap(
        between binding: ProposedBinding,
        and guardrail: Guardrail,
        analyzer: any GuardrailAnalyzer,
        logger: Logger
    ) async throws -> String? {
        guard let node = guardrail.node else { return nil }
        let resourceMatch: GuardrailResourceMatch
        do {
            resourceMatch = try guardrail.resourceMatch()
        } catch {
            return nil
        }

        // The action side is decided here, over the finite registry: a role's
        // action set and a ceiling's patterns are both enumerable, so asking a
        // solver would be paying for an answer we already have.
        let roleActions = IAMRoleRegistry.actions(for: binding.role)
        let overlapping = roleActions.filter { GuardrailActions.matches(guardrail.actions, action: $0) }
        guard !overlapping.isEmpty else { return nil }

        // What is left genuinely needs the solver: can a resource exist that
        // sits under *both* the binding's node and the ceiling's attach node,
        // and satisfies the ceiling's resource conditions?
        //
        // That question does not depend on which of the overlapping actions is
        // asked about — only on the resource type, since `appliesTo` is what
        // ties an action to a type. So one query per reachable resource type,
        // with any overlapping action as its representative. The enumeration
        // is complete, not sampled: no ceiling is skipped for cost.
        let reachable = Set(CedarSchemaBuilder.descendantTypes(of: binding.node.type.cedarEntityType))
        var representatives: [CedarEntityType: String] = [:]
        for action in overlapping.sorted() {
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
        // registry keeps the check off the database and deterministic.
        let schemaText = CedarSchemaBuilder.schemaText(roles: RoleDescriptor.seededDefaults())
        let grant = grantPolicy(binding)
        let ceiling = ceilingPolicy(guardrail, node: node, resourceMatch: resourceMatch)

        for (resourceType, action) in representatives.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            let environment = CedarRequestEnvironment(
                principalType: .user, action: action, resourceType: resourceType)
            let analysis: GuardrailAnalysis
            do {
                analysis = try await analyzer.disjoint(
                    schemaText: schemaText, [grant], [ceiling], in: environment)
            } catch let error as GuardrailAnalyzerError {
                logger.error(
                    "Write-time guardrail analysis failed",
                    metadata: [
                        "guardrail": .string(guardrail.name),
                        "action": .string(action),
                        "resource_type": .string(resourceType.rawValue),
                        "error": .string("\(error)"),
                    ])
                throw GuardrailCheckUnavailable(detail: "\(error)")
            }
            if !analysis.holds {
                return analysis.counterexample ?? "\(action) on \(resourceType.rawValue)"
            }
        }
        return nil
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
    /// The action side is the role's expanded action list, matching how a role
    /// row's own permit is written (`RoleDescriptor.canonicalPermitText`):
    /// roles are flat, so there is no schema action group to name (issue #604).
    private static func grantPolicy(_ binding: ProposedBinding) -> CedarPolicySource {
        let actionList = IAMRoleRegistry.actions(for: binding.role).sorted()
            .map { "Action::\(CedarText.stringLiteral($0))" }
            .joined(separator: ", ")
        return CedarPolicySource(
            id: "proposed-binding",
            text: """
                @id("proposed-binding")
                permit (
                    principal,
                    action in [\(actionList)],
                    resource in \(binding.node.cedarUID.cedarLiteral)
                );
                """
        )
    }

    /// The guardrail as a `permit`, so "can the grant reach what the ceiling
    /// forbids" becomes "can one request be allowed by both".
    ///
    /// Flipping the effect is sound because disjointness is asked of the two
    /// *scopes*: a `forbid` and a `permit` with the same head match the same
    /// requests. The action and resource clauses come from the same builders
    /// the compiled forbid uses, so the two renderings cannot drift.
    private static func ceilingPolicy(
        _ guardrail: Guardrail, node: IAMNode, resourceMatch: GuardrailResourceMatch
    ) -> CedarPolicySource {
        var text = """
            @id("ceiling")
            permit (
                principal,
                \(CedarPolicyAssembler.actionClause(for: guardrail.actions)),
                resource in \(node.cedarUID.cedarLiteral)
            )
            """
        if let condition = CedarPolicyAssembler.environmentCondition(for: resourceMatch) {
            text += "\nwhen { \(condition) }"
        }
        text += ";"
        return CedarPolicySource(id: "ceiling", text: text)
    }

    // MARK: - Rendering

    /// Turn a breach into the response body the design specifies.
    private static func describe(
        _ guardrail: Guardrail,
        binding: ProposedBinding,
        counterexample: String?,
        on db: any Database
    ) async throws -> GuardrailViolation {
        let node = guardrail.node
        let path: String
        if let node, let name = try await nodeName(node, on: db) {
            path = "\(node.type.rawValue)/\(name)/\(guardrail.name)"
        } else {
            path = guardrail.name
        }

        var setBy: String?
        if let createdBy = guardrail.createdBy, let author = try await User.find(createdBy, on: db) {
            // The authority is derivable rather than stored: writing a
            // guardrail requires admin on its attach node, so the node type
            // names the role that must have been held.
            let authority = node.map { "\($0.type.rawValue) admin" } ?? "admin"
            setBy = "\(author.email) (\(authority))"
        }

        return GuardrailViolation(
            guardrail: path,
            setBy: setBy,
            explanation: reasonText(guardrail, binding: binding),
            counterexample: counterexample
        )
    }

    /// The prose half of the answer, written in the vocabulary the ceiling was
    /// authored in — the reader has to be able to match it against the
    /// guardrail they can see in the UI.
    private static func reasonText(_ guardrail: Guardrail, binding: ProposedBinding) -> String {
        var reason = "grants \(binding.role.rawValue) on \(binding.node.type.rawValue) resources"
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
        let actions = guardrail.actions.joined(separator: ", ")
        reason += "; the ceiling forbids \(actions) here"
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
}
