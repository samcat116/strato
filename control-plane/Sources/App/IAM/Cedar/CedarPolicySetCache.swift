import Fluent
import Foundation
import Vapor

// IAM phase 3 (issue #480): the per-replica compiled policy set.
//
// Keyed by the policy-set version (#479) and invalidated exactly the way the
// design prescribes: the `policy-set:version` Valkey broadcast is the fast
// path, the 30s periodic re-read is the backstop, and both arrive here through
// `PolicySetVersionCache.onVersionChange` — this cache adds no invalidation
// machinery of its own. Bindings are read per-request by the entity-slice
// loader, so grant/revoke correctly invalidates nothing.

/// The seam where the Cedar engine plugs in.
///
/// The production engine is `SwiftCedarEngine` (samcat116/swift-cedar,
/// wrapping the cedar-policy crate via UniFFI, with prebuilt binaries for
/// Linux and Apple since v0.1.0). The protocol remains so tests can inject
/// failing or canned engines without touching assembly or invalidation.
protocol CedarEngine: Sendable {
    /// Parse and validate the schema and policy set into an evaluatable
    /// artifact. Throwing keeps the cache on its previous set.
    func compile(schemaText: String, policies: [CedarPolicySource]) throws -> any CedarCompiledPolicySet

    /// Parse and validate a single policy against the schema; nil when it is
    /// good, the reason otherwise. Cedar validation is per-policy, so this is
    /// how the cache pre-screens *stored* policy text (role rows) and drops a
    /// bad row loudly instead of letting it freeze the whole set on its stale
    /// previous build — e.g. a role whose action was removed from the
    /// registry by an upgrade.
    func policyIssue(schemaText: String, policy: CedarPolicySource) -> String?
}

extension CedarEngine {
    /// Engines that cannot screen individually (test fakes) skip nothing; the
    /// full-set compile stays the backstop.
    func policyIssue(schemaText: String, policy: CedarPolicySource) -> String? { nil }
}

/// One evaluated authorization decision from the compiled set.
struct CedarCheckDecision: Equatable, Sendable {
    let allowed: Bool
    /// Ids of the policies that determined the decision — the assembler's
    /// `@id`s (`role-editor`, `guardrail-<id>`, `platform-system-admin`, …),
    /// which is what lets a decision log name what decided.
    let determiningPolicyIDs: [String]
    /// Evaluation errors Cedar encountered. Non-empty does not imply deny;
    /// Cedar skips policies that error.
    let evaluationErrors: [String]

    /// The tier (docs/architecture/iam.md) that produced this decision,
    /// derived from the determining policy ids. A forbid always wins, so any
    /// guardrail in the determining set names tier 2 regardless of what else
    /// matched; an allow names the tier of its permit; a deny nothing decided
    /// is the default deny.
    ///
    /// Authored policies (issue #606) name their own tier, `policy`, on either
    /// side of the decision: an authored forbid that denied, or an authored
    /// permit that allowed. A guardrail forbid still outranks an authored one
    /// in attribution — the guardrail check above runs first — because a
    /// tier-2 ceiling is the stronger statement about why the request failed.
    var tier: String {
        if determiningPolicyIDs.contains(where: { $0.hasPrefix("guardrail-") }) { return "guardrail" }
        if allowed {
            if determiningPolicyIDs.contains(where: { $0.hasPrefix("platform-") || $0 == "org-membership" }) {
                return "platform"
            }
            if determiningPolicyIDs.contains(where: { $0.hasPrefix("policy-") }) { return "policy" }
            if determiningPolicyIDs.contains(where: { $0.hasPrefix("role-") }) { return "grant" }
            return "unknown"
        }
        if determiningPolicyIDs.contains(where: { $0.hasPrefix("policy-") }) { return "policy" }
        return "default-deny"
    }
}

/// A compiled artifact ready to evaluate checks: with the real engine, parsed
/// `Schema` + `PolicySet` handles behind `isAuthorized`.
protocol CedarCompiledPolicySet: Sendable {
    /// Evaluate one check against the compiled set. `context` is the full
    /// request context (the slice's `baseContextValue`); `entitiesJSON` is the
    /// slice's entity store in Cedar's entities JSON format.
    func authorize(
        principal: CedarEntityUID,
        action: String,
        resource: CedarEntityUID,
        context: CedarValue,
        entitiesJSON: String
    ) throws -> CedarCheckDecision
}

/// This replica's compiled Cedar policy set.
actor CedarPolicySetCache {

    struct Built: Sendable {
        /// The policy-set version this build reflects — stamped into decision
        /// logs (#481) so a logged decision names the policy set that made it.
        let version: Int
        let schemaText: String
        /// Static (platform + role) policies followed by the guardrail
        /// forbids.
        let policyText: String
        /// The role-definition rows whose grants fields this build's schema
        /// declares. The entity-slice context must emit exactly these — a
        /// grants field the schema doesn't know fails strict validation for
        /// the whole request — so the authorizer filters through this set.
        let roleIDs: Set<UUID>
        let guardrailCount: Int
        let skippedGuardrails: [GuardrailRendering.SkippedGuardrail]
        /// Role rows whose stored Cedar text failed to parse or validate and
        /// were left out (their grants fields stay declared; the role just
        /// permits nothing). Loud in logs — a role granting nothing is the
        /// safe failure, not a fine one.
        let skippedRolePolicies: [SkippedRolePolicy]
        /// How many enabled authored policies (issue #606) made it into the set.
        let authoredPolicyCount: Int
        /// Authored-policy rows whose stored Cedar text failed to parse or
        /// validate and were left out entirely. Loud in logs — an authored
        /// policy that permits or forbids nothing is the safe failure.
        let skippedAuthoredPolicies: [SkippedAuthoredPolicy]
        let artifact: any CedarCompiledPolicySet
        let builtAt: Date
    }

    /// A role row left out of the compiled set, with the reason.
    struct SkippedRolePolicy: Equatable, Sendable {
        let id: UUID
        let name: String
        let reason: String
    }

    /// An authored-policy row left out of the compiled set, with the reason.
    struct SkippedAuthoredPolicy: Equatable, Sendable {
        let id: UUID
        let name: String
        let reason: String
    }

    private let engine: any CedarEngine
    private let logger: Logger
    private(set) var current: Built?

    init(engine: any CedarEngine = SwiftCedarEngine(), logger: Logger) {
        self.engine = engine
        self.logger = logger
    }

    /// Rebuild only when the cached set is not already at `version` — the
    /// idempotent form the periodic refresh drives, cheap on the every-30s
    /// tick where nothing changed.
    ///
    /// This is also the retry path: `PolicySetVersionCache` advances its
    /// version *before* listeners run, so after a failed rebuild no further
    /// version *change* is coming — the level-triggered refresh hook keeps
    /// calling here until the build lands.
    func reconcile(version: Int, on db: any Database) async {
        guard current?.version != version else { return }
        await rebuild(version: version, on: db)
    }

    /// Rebuild for `version`. On failure the previous set stays: a stale
    /// policy set converges on the next nudge or periodic re-read (via
    /// `reconcile`), whereas an empty one would deny everything (or, with
    /// guardrails missing, allow what a ceiling forbids).
    func rebuild(version: Int, on db: any Database) async {
        do {
            // Every role definition — seeded and user-created. Sorted by id so
            // two replicas building the same version produce identical text.
            let roleRows = try await IAMRoleDefinition.query(on: db).all()
            let roles = roleRows.compactMap(RoleDescriptor.init(row:))
                .sorted { $0.id.uuidString < $1.id.uuidString }

            let guardrails = try await Guardrail.query(on: db)
                .filter(\.$enabled == true)
                .all()

            let schemaText = CedarSchemaBuilder.schemaText(roles: roles)

            // Pre-screen the *stored* role policy text individually. Cedar
            // validation is per-policy, so a row that fails here (a role
            // naming an action an upgrade removed from the registry) can be
            // dropped alone — permitting nothing, its grants fields still
            // declared — instead of failing the full-set compile and pinning
            // every replica to its stale previous build until the row is
            // fixed. Platform policies are code and take no screening; the
            // full-set compile below stays the backstop for both.
            var skippedRolePolicies: [SkippedRolePolicy] = []
            let compilableRoles = roles.map { role -> RoleDescriptor in
                guard !role.cedarText.isEmpty else { return role }
                let source = CedarPolicySource(id: role.policyID, text: role.cedarText)
                guard let issue = engine.policyIssue(schemaText: schemaText, policy: source) else {
                    return role
                }
                skippedRolePolicies.append(SkippedRolePolicy(id: role.id, name: role.name, reason: issue))
                return RoleDescriptor(id: role.id, name: role.name, cedarText: "", actions: role.actions)
            }

            for skipped in skippedRolePolicies {
                logger.error(
                    "Role definition left out of the compiled Cedar policy set; the role grants nothing",
                    metadata: [
                        "role_id": .string(skipped.id.uuidString),
                        "role_name": .string(skipped.name),
                        "reason": .string(skipped.reason),
                    ])
            }

            // Authored policies (issue #606): enabled permit/forbid rows,
            // sorted by id so two replicas building the same version produce
            // identical text.
            let policyRows = try await IAMPolicy.query(on: db)
                .filter(\.$enabled == true)
                .all()
            let authoredPolicies = policyRows.compactMap(PolicyDescriptor.init(row:))
                .sorted { $0.id.uuidString < $1.id.uuidString }

            // Pre-screen each authored policy the way role text is screened:
            // Cedar validates per-policy, so one bad row (a policy naming an
            // action or attribute a later schema no longer declares) can be
            // dropped alone instead of failing the full-set compile and pinning
            // every replica to its stale previous build. Unlike a role, a
            // dropped authored policy leaves nothing behind — it has no schema
            // fields — so it is simply omitted.
            var skippedAuthoredPolicies: [SkippedAuthoredPolicy] = []
            let compilablePolicies = authoredPolicies.filter { policy in
                let source = CedarPolicySource(id: policy.policyID, text: policy.cedarText)
                guard let issue = engine.policyIssue(schemaText: schemaText, policy: source) else {
                    return true
                }
                skippedAuthoredPolicies.append(
                    SkippedAuthoredPolicy(id: policy.id, name: policy.name, reason: issue))
                return false
            }

            for skipped in skippedAuthoredPolicies {
                logger.error(
                    "Authored policy left out of the compiled Cedar policy set",
                    metadata: [
                        "policy_id": .string(skipped.id.uuidString),
                        "policy_name": .string(skipped.name),
                        "reason": .string(skipped.reason),
                    ])
            }

            let staticText = CedarPolicyAssembler.staticPolicyText(roles: compilableRoles)
            let authoredText = CedarPolicyAssembler.authoredPolicyText(compilablePolicies)
            let authoredSources = CedarPolicyAssembler.authoredPolicySources(compilablePolicies)

            // Guardrails compile from their stored `cedar_text` verbatim since
            // #610 — the same treatment authored policies get — so what is
            // stored, shown, and enforced is one string. A row whose text
            // predates the migration (null) falls back to matcher generation.
            let compiledGuardrails = try await buildGuardrailPolicies(
                guardrails, schemaText: schemaText, on: db)

            for skipped in compiledGuardrails.skipped {
                // A skipped guardrail is a ceiling not being enforced by the
                // compiled set. The store's own evaluation gives these rows
                // the same matches-nobody semantics, but that makes it loud,
                // not fine.
                logger.error(
                    "Guardrail left out of the compiled Cedar policy set",
                    metadata: [
                        "guardrail_id": .string(skipped.id?.uuidString ?? "nil"),
                        "guardrail_name": .string(skipped.name),
                        "reason": .string(skipped.reason),
                    ])
            }

            // Order for display: permits first (platform + roles, then
            // authored), forbids last (guardrails). Cedar semantics do not
            // depend on order — a forbid wins wherever it sits — so this is a
            // readability choice for the assembled-set text.
            let policyText = [staticText, authoredText, compiledGuardrails.policyText]
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
            let artifact = try engine.compile(
                schemaText: schemaText,
                policies: CedarPolicyAssembler.staticPolicies(roles: compilableRoles)
                    + authoredSources + compiledGuardrails.policies)

            current = Built(
                version: version,
                schemaText: schemaText,
                policyText: policyText,
                roleIDs: Set(roles.map(\.id)),
                guardrailCount: compiledGuardrails.compiledGuardrailIDs.count,
                skippedGuardrails: compiledGuardrails.skipped,
                skippedRolePolicies: skippedRolePolicies,
                authoredPolicyCount: authoredSources.count,
                skippedAuthoredPolicies: skippedAuthoredPolicies,
                artifact: artifact,
                builtAt: Date()
            )
            logger.info(
                "Compiled Cedar policy set",
                metadata: [
                    "version": .stringConvertible(version),
                    "roles": .stringConvertible(roles.count),
                    "policies": .stringConvertible(authoredSources.count),
                    "guardrails": .stringConvertible(compiledGuardrails.compiledGuardrailIDs.count),
                ])
        } catch {
            logger.error(
                "Failed to rebuild the Cedar policy set; keeping the previous one",
                metadata: [
                    "version": .stringConvertible(version),
                    "error": .string("\(error)"),
                ])
        }
    }

    /// Turn enabled guardrail rows into compiled `forbid` sources (#610).
    ///
    /// The stored `cedar_text` is compiled verbatim — the assembler already ran
    /// at write time, whether from matchers or from hand-authored input. A row
    /// with a null `cedar_text` (written before the migration, or racing the
    /// boot backfill) falls back to regenerating from its matchers, so the set
    /// is never missing a ceiling merely because the column has not been filled
    /// yet.
    ///
    /// Each source is pre-screened individually the same way authored policies
    /// are: Cedar validates per-policy, so a row that went stale against the
    /// live schema is dropped alone (logged loudly — a dropped ceiling is
    /// fail-open) instead of failing the whole-set compile and pinning every
    /// replica to its previous build.
    private func buildGuardrailPolicies(
        _ guardrails: [Guardrail], schemaText: String, on db: any Database
    ) async throws -> GuardrailRendering.RenderedForbids {
        var sources: [CedarPolicySource] = []
        var namesByID: [UUID: String] = [:]
        var skipped: [GuardrailRendering.SkippedGuardrail] = []

        var needGeneration: [Guardrail] = []
        for guardrail in guardrails {
            guard let id = guardrail.id else {
                skipped.append(
                    GuardrailRendering.SkippedGuardrail(id: nil, name: guardrail.name, reason: "row has no id"))
                continue
            }
            namesByID[id] = guardrail.name
            if let text = guardrail.cedarText, !text.isEmpty {
                sources.append(CedarPolicySource(id: GuardrailRendering.policyID(id), text: text))
            } else {
                needGeneration.append(guardrail)
            }
        }

        // Fallback generation for null-text rows.
        if !needGeneration.isEmpty {
            let generated = try await GuardrailRendering.forbids(for: needGeneration, on: db)
            sources += generated.policies
            skipped += generated.skipped
        }

        // Pre-screen every guardrail source, dropping a stale one alone.
        var compiledIDs: [UUID] = []
        var screened: [CedarPolicySource] = []
        for source in sources {
            let id =
                source.id.hasPrefix("guardrail-")
                ? UUID(uuidString: String(source.id.dropFirst("guardrail-".count))) : nil
            if let issue = engine.policyIssue(schemaText: schemaText, policy: source) {
                skipped.append(
                    GuardrailRendering.SkippedGuardrail(
                        id: id, name: id.flatMap { namesByID[$0] } ?? source.id, reason: issue))
                continue
            }
            screened.append(source)
            if let id { compiledIDs.append(id) }
        }

        return GuardrailRendering.RenderedForbids(
            policies: screened, compiledGuardrailIDs: compiledIDs, skipped: skipped)
    }

}

extension Application {
    private struct CedarPolicySetCacheKey: StorageKey, LockKey {
        typealias Value = CedarPolicySetCache
    }

    /// This replica's compiled Cedar policy set.
    var cedarPolicySet: CedarPolicySetCache {
        lazyService(CedarPolicySetCacheKey.self) { CedarPolicySetCache(logger: logger) }
    }

    /// Hang the compiled-set rebuild off the policy-set version watch. Call
    /// *before* `startPolicySetVersionWatch()`, so the watch's initial refresh
    /// already lands here — that first refresh is what builds the boot-time
    /// set, fresh database included.
    ///
    /// Level-triggered on purpose (`onEveryRefresh`, not `onVersionChange`):
    /// the version cache advances before listeners run, so an edge-triggered
    /// listener whose rebuild failed would never be called again until the
    /// next policy write. Reconciling against the cached set's own version on
    /// every tick keeps the steady state to an integer comparison and turns a
    /// failed rebuild into one interval of staleness instead of an unbounded
    /// one.
    func startCedarPolicySetCache() async {
        await policySetVersion.onEveryRefresh { [self] version in
            await cedarPolicySet.reconcile(version: version, on: db)
        }
    }
}
