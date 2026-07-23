import Fluent
import Foundation
import Vapor

/// The one rendering of a matcher-built guardrail row.
///
/// A `Guardrail` row is consumed three ways, and enforcement is only correct
/// while the three agree:
///
/// - **The compiled Cedar `forbid`** (`forbid(organizationID:)`) — what the
///   policy-set cache compiles and the evaluator enforces on every request.
/// - **The solver-facing `permit`** (`permit()`) — the write-time ceiling
///   check (#484) re-emits the guardrail as a permit to ask whether a proposed
///   grant can reach anything it forbids.
/// - **The structural match** (`covers(...)`) — "does this ceiling cover this
///   action / resource / principal", answered directly against the database,
///   for the surfaces Cedar cannot evaluate: group principals (no group
///   request environment exists) and the write-time principal side (group and
///   org membership are database facts a solver would otherwise have to guess).
///
/// These used to be three renderings in three files — `CedarPolicyAssembler`,
/// `GuardrailWriteCheck`, `GuardrailStore` — agreeing only because they shared
/// two clause builders and a stack of cross-referencing comments. Here they
/// are projections of one representation: the row is parsed once, every
/// projection reads the same parsed value, and each side of the row (action,
/// resource, principal) keeps its Cedar spelling and its structural spelling
/// side by side where a change to one cannot miss the other.
///
/// Authored guardrails (#610) are deliberately outside this type: their stored
/// `cedar_text` *is* their rendering, the matcher columns are inert
/// placeholders, and every consumer branches on `Guardrail.authored` before
/// coming here.
///
/// One divergence between the consumers is theirs, not this module's: what to
/// do with a row that fails to parse. `GuardrailStore.forbidding` propagates
/// the error (fail closed — a ceiling we cannot read must not quietly stop
/// forbidding), while the policy-set cache and the write-time check treat the
/// row as matching nobody, loudly logged, because throwing there would pin the
/// whole policy set (or every binding write) to one corrupt row. Both choices
/// are visible at the `init` call sites.
struct GuardrailRendering: Sendable {
    let id: UUID
    let name: String
    /// The attach node — the subtree the ceiling covers.
    let node: IAMNode
    /// Canonicalized action patterns (`GuardrailActions.canonicalize`).
    let actions: [String]
    let principalMatch: GuardrailPrincipalMatch
    let resourceMatch: GuardrailResourceMatch

    /// A row (or projection) this module refuses to render, with the reason
    /// the skip is logged under.
    struct Unrenderable: Error, Sendable {
        let reason: String
    }

    /// Parse a matcher-built row into the one representation.
    ///
    /// Throws `Unrenderable` for a row with no id or an unknown node type, and
    /// the row's own `GuardrailError` for unreadable match columns — the same
    /// error the API's write path would raise, so a caller that propagates it
    /// (`GuardrailStore.forbidding`) reports the row exactly as the store
    /// would.
    init(_ row: Guardrail) throws {
        guard let id = row.id else {
            throw Unrenderable(reason: "row has no id")
        }
        guard let node = row.node else {
            throw Unrenderable(reason: "unknown node type '\(row.nodeType)'")
        }
        self.id = id
        self.name = row.name
        self.node = node
        self.actions = row.actions
        self.principalMatch = try row.principalMatch()
        self.resourceMatch = try row.resourceMatch()
    }

    /// The compiled-set id every rendering of a guardrail row travels under —
    /// `guardrail-<row uuid>`, embedded as `@id` in the forbid, used verbatim
    /// for stored authored text, and matched by prefix wherever a decision's
    /// determining policies are attributed back to a ceiling
    /// (`CedarCheckDecision.tier`, `IAMDecisionEngine.Decision.denyingCeilingIDs`).
    static func policyID(_ guardrailID: UUID) -> String {
        "guardrail-\(guardrailID.uuidString.lowercased())"
    }

    var policyID: String { Self.policyID(id) }

    // MARK: - The action side

    /// Whether a pattern set covers `action` — the structural spelling of the
    /// action side.
    ///
    /// Must agree with `actionClause` below: a `service:*` pattern matches by
    /// prefix here and compiles to the schema's per-service action group
    /// there, and the two coincide because `CedarSchemaBuilder` files an
    /// action into its service group by the same `service:` prefix. An action
    /// shipped after the ceiling was written is covered by both spellings for
    /// the same reason.
    static func patternsCover(_ patterns: [String], action: String) -> Bool {
        patterns.contains { pattern in
            if pattern == GuardrailActions.wildcard { return true }
            guard pattern.hasSuffix(":*") else { return pattern == action }
            return action.hasPrefix(String(pattern.dropLast(1)))
        }
    }

    func covers(action: String) -> Bool {
        Self.patternsCover(actions, action: action)
    }

    /// The `action` scope of the Cedar renderings — the compiled spelling of
    /// the action side. See `patternsCover` for the agreement it must hold.
    private var actionClause: String {
        if actions.contains(GuardrailActions.wildcard) { return "action" }
        let refs = actions.map { pattern -> String in
            if pattern.hasSuffix(":*") {
                let service = String(pattern.dropLast(2))
                return "Action::\(CedarText.stringLiteral(CedarSchemaBuilder.serviceGroupName(service)))"
            }
            return "Action::\(CedarText.stringLiteral(pattern))"
        }
        return "action in [\(refs.joined(separator: ", "))]"
    }

    // MARK: - The resource side

    /// Whether the resource side covers a resource carrying `environment` —
    /// the structural spelling. A resource with no environment attribute is
    /// not in any environment, so an environment ceiling does not reach it.
    func covers(environment: String?) -> Bool {
        switch resourceMatch {
        case .any:
            return true
        case .environment(let wanted):
            return environment == wanted
        }
    }

    /// The `when` condition of the Cedar renderings, if the resource side
    /// constrains anything — the compiled spelling of `covers(environment:)`.
    ///
    /// Matches the resource being acted on, never its ancestry: environment is
    /// an attribute, not a container. The `has` guard is the compiled form of
    /// the structural rule that an unenvironmented resource falls outside the
    /// ceiling.
    private var environmentCondition: String? {
        switch resourceMatch {
        case .any:
            return nil
        case .environment(let environment):
            return "resource has environment && resource.environment == \(CedarText.stringLiteral(environment))"
        }
    }

    // MARK: - The principal side

    /// Whether the principal side covers this principal, resolved against the
    /// database — the structural spelling.
    ///
    /// This is the spelling the write-time ceiling check (#484) uses too,
    /// rather than asking the solver: group and org membership are facts in
    /// the database, and a symbolic solver told nothing about them would have
    /// to assume every principal *might* be in every group — reporting a
    /// violation for grants no ceiling touches. The symbolic part of that
    /// check is what is genuinely open: which resource, which action, which
    /// environment.
    ///
    /// Must agree with the compiled principal spelling in
    /// `forbid(organizationID:)`; the machine-principal case is where the
    /// agreement is easiest to lose (see `externalToOrganization` below).
    static func covers(
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

    func covers(
        principalType: IAMPrincipalType, principalID: UUID, organizationID: UUID?, on db: any Database
    ) async throws -> Bool {
        try await Self.covers(
            principalMatch, principalType: principalType, principalID: principalID,
            organizationID: organizationID, on: db)
    }

    // MARK: - The compiled Cedar forbid

    /// The Cedar `forbid` this guardrail compiles to — what the policy-set
    /// cache enforces, what the write path stores in `cedar_text`, and what
    /// the UI displays.
    ///
    /// Structurally forbid-only: this projection can emit nothing else, which
    /// is the compiler-side leg of the tier-2 invariant. The policy id is
    /// `guardrail-<row id>`, so a denial can name the exact ceiling in the
    /// way.
    ///
    /// `organizationID` is the resolved organization of the attach node — the
    /// one input the rendering cannot derive without a tree walk. It is only
    /// consulted for an `external_to_organization` ceiling; passing nil for
    /// one throws `Unrenderable`, because "external" is defined against the
    /// attach node's org and with no resolvable org the ceiling matches
    /// nobody — in the compiled set exactly as in `covers`. Embedding the org
    /// id in the compiled text is sound because attach nodes cannot move to
    /// another org without a delete/recreate, which bumps the policy-set
    /// version.
    func forbid(organizationID: UUID?) throws -> CedarPolicySource {
        var conditions: [String] = []

        let principalClause: String
        switch principalMatch {
        case .any:
            principalClause = "principal"
        case .user(let userID):
            principalClause = "principal == \(CedarEntityUID(type: .user, id: userID).cedarLiteral)"
        case .group(let groupID):
            // `in`, not `==`: the group is how a grant reaches a user, so
            // it must be how the ceiling does too. The principal's group
            // parent edges make this cover the members.
            principalClause = "principal in \(CedarEntityUID(type: .group, id: groupID).cedarLiteral)"
        case .externalToOrganization:
            guard let organizationID else {
                throw Unrenderable(
                    reason:
                        "attach node resolves to no organization; an external-principal ceiling has nothing to be external to"
                )
            }
            principalClause = "principal"
            let orgLiteral = CedarEntityUID(type: .organization, id: organizationID).cedarLiteral
            // The `is User` guard keeps strict validation happy in the
            // workload-principal environments (they have no `memberOfOrgs`),
            // and makes the semantics explicit: a machine principal is a
            // member of nothing, so an external-principal ceiling always
            // covers it — the compiled spelling of the structural rule in
            // `covers`.
            conditions.append("!(principal is User && principal.memberOfOrgs.contains(\(orgLiteral)))")
        }

        if let environmentCondition {
            conditions.append(environmentCondition)
        }

        var policy = """
            @id("\(policyID)")
            forbid (\(principalClause), \(actionClause), resource in \(node.cedarUID.cedarLiteral))
            """
        if !conditions.isEmpty {
            policy += "\nwhen { \(conditions.joined(separator: " && ")) }"
        }
        policy += ";"
        return CedarPolicySource(id: policyID, text: policy)
    }

    // MARK: - The solver-facing permit

    /// The guardrail as a `permit`, so the write-time check can ask "can one
    /// request be allowed by both this and a proposed grant" — disjointness is
    /// the solver's question, and a `forbid` and a `permit` with the same head
    /// match the same requests, so flipping the effect is sound.
    ///
    /// The action and resource sides are the same clauses the forbid carries,
    /// read from the same representation. The principal side is deliberately
    /// open (`principal`, no condition): whether the ceiling covers the
    /// principal was already settled against the database (`covers`), and
    /// restating it symbolically would only let the solver invent memberships
    /// nobody has — which is also why this projection needs no organization
    /// id.
    func permit() -> CedarPolicySource {
        var text = """
            @id("ceiling")
            permit (
                principal,
                \(actionClause),
                resource in \(node.cedarUID.cedarLiteral)
            )
            """
        if let environmentCondition {
            text += "\nwhen { \(environmentCondition) }"
        }
        text += ";"
        return CedarPolicySource(id: "ceiling", text: text)
    }

    // MARK: - Batch forbid rendering

    /// A guardrail left out of a rendered forbid set, with the reason.
    /// Skipping gives the row the same matches-nobody semantics an
    /// unresolvable row has everywhere, but it is still a ceiling not being
    /// enforced, so the policy-set cache logs every one loudly.
    struct SkippedGuardrail: Equatable, Sendable {
        let id: UUID?
        let name: String
        let reason: String
    }

    struct RenderedForbids: Sendable {
        let policies: [CedarPolicySource]
        let compiledGuardrailIDs: [UUID]
        let skipped: [SkippedGuardrail]

        /// The joined policy text, for display and tests.
        var policyText: String {
            policies.isEmpty ? "" : policies.map(\.text).joined(separator: "\n\n") + "\n"
        }
    }

    /// Render rows into `forbid` policies, collecting skips instead of
    /// throwing — the shape the policy-set cache needs, where one corrupt row
    /// must not pin every replica to its stale previous build.
    ///
    /// `organizationIDsByGuardrail` carries the resolved organization of each
    /// `external_to_organization` guardrail's attach node; use
    /// `forbids(for:on:)` to have the tree walked here. Sorted by id for a
    /// deterministic set — rebuilds on two replicas must produce identical
    /// text for the same version.
    static func forbids(
        for rows: [Guardrail],
        organizationIDsByGuardrail: [UUID: UUID]
    ) -> RenderedForbids {
        var policies: [CedarPolicySource] = []
        var compiled: [UUID] = []
        var skipped: [SkippedGuardrail] = []

        let ordered = rows.sorted {
            ($0.id?.uuidString ?? "") < ($1.id?.uuidString ?? "")
        }

        for row in ordered {
            let rendering: GuardrailRendering
            do {
                rendering = try GuardrailRendering(row)
            } catch let failure as Unrenderable {
                skipped.append(SkippedGuardrail(id: row.id, name: row.name, reason: failure.reason))
                continue
            } catch {
                skipped.append(
                    SkippedGuardrail(id: row.id, name: row.name, reason: "unreadable match: \(error)"))
                continue
            }
            do {
                policies.append(
                    try rendering.forbid(organizationID: organizationIDsByGuardrail[rendering.id]))
                compiled.append(rendering.id)
            } catch let failure as Unrenderable {
                skipped.append(
                    SkippedGuardrail(id: rendering.id, name: rendering.name, reason: failure.reason))
            } catch {
                skipped.append(
                    SkippedGuardrail(id: rendering.id, name: rendering.name, reason: "\(error)"))
            }
        }

        return RenderedForbids(policies: policies, compiledGuardrailIDs: compiled, skipped: skipped)
    }

    /// `forbids(for:organizationIDsByGuardrail:)`, resolving each
    /// external-principal ceiling's attach-node organization from the tree
    /// first — the one database read the forbid projection needs.
    static func forbids(for rows: [Guardrail], on db: any Database) async throws -> RenderedForbids {
        var organizationIDsByGuardrail: [UUID: UUID] = [:]
        for row in rows
        where row.principalMatchKind == GuardrailPrincipalMatchKind.externalToOrganization.rawValue {
            guard let id = row.id, let node = row.node else { continue }
            let chain = try await IAMResourceTree.ancestors(of: node, on: db)
            if let organization = chain.first(where: { $0.type == .organization }) {
                organizationIDsByGuardrail[id] = organization.id
            }
        }
        return forbids(for: rows, organizationIDsByGuardrail: organizationIDsByGuardrail)
    }

    /// The Cedar `forbid` one matcher-built row compiles to, or nil for a row
    /// the batch renderer skips (an unknown node type, or an external ceiling
    /// whose attach node resolves to no organization) — the same rows the
    /// compiled set leaves out.
    ///
    /// This is the single generation path since #610: the write path stores
    /// its result (`GuardrailStore`), the boot backfill fills a null column
    /// with it, the cache's null-text fallback regenerates it, and the
    /// controller's DTO renders it — so what is stored, shown, and enforced
    /// cannot drift.
    static func cedarText(for row: Guardrail, on db: any Database) async throws -> String? {
        try await forbids(for: [row], on: db).policies.first?.text
    }
}
