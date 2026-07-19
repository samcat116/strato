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
/// The Swift↔Cedar binding (samcat116/swift-cedar, wrapping the cedar-policy
/// crate via UniFFI) cannot be a package dependency yet: its binary artifact
/// is unpublished and its packaging is Apple-only, while the control plane
/// builds and deploys on Linux. Everything the evaluator needs — schema,
/// policy text, entity slices, invalidation — is produced and cached behind
/// this protocol, so #481 (shadow evaluation) swaps the real engine in
/// without touching assembly or invalidation.
protocol CedarEngine: Sendable {
    /// Parse and validate the schema and policy set into an evaluatable
    /// artifact. Throwing keeps the cache on its previous set.
    func compile(schemaText: String, policyText: String) throws -> any CedarCompiledPolicySet
}

/// An opaque compiled artifact — with the real engine, parsed `Schema` +
/// `PolicySet` handles ready for `isAuthorized`.
protocol CedarCompiledPolicySet: Sendable {}

/// The placeholder engine: holds the assembled text without parsing it.
/// Schema/policy correctness is covered by the structural tests and the
/// registry-driven generation until the real engine validates on boot.
struct TextOnlyCedarEngine: CedarEngine {
    struct Artifact: CedarCompiledPolicySet {
        let schemaText: String
        let policyText: String
    }

    func compile(schemaText: String, policyText: String) throws -> any CedarCompiledPolicySet {
        Artifact(schemaText: schemaText, policyText: policyText)
    }
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
        let guardrailCount: Int
        let skippedGuardrails: [CedarPolicyAssembler.SkippedGuardrail]
        let artifact: any CedarCompiledPolicySet
        let builtAt: Date
    }

    private let engine: any CedarEngine
    private let logger: Logger
    private(set) var current: Built?

    init(engine: any CedarEngine = TextOnlyCedarEngine(), logger: Logger) {
        self.engine = engine
        self.logger = logger
    }

    /// Rebuild for `version`. On failure the previous set stays: a stale
    /// policy set converges on the next nudge or periodic re-read, whereas an
    /// empty one would deny everything (or, with guardrails missing, allow
    /// what a ceiling forbids).
    func rebuild(version: Int, on db: any Database) async {
        do {
            let guardrails = try await Guardrail.query(on: db)
                .filter(\.$enabled == true)
                .all()

            // Resolve the attach-node org for the external-principal
            // guardrails — "external" means external to it. Sound to embed in
            // compiled text: an attach node cannot move to another org, and
            // guardrail writes bump the version.
            var organizationIDsByGuardrail: [UUID: UUID] = [:]
            for guardrail in guardrails
            where guardrail.principalMatchKind == GuardrailPrincipalMatchKind.externalToOrganization.rawValue {
                guard let id = guardrail.id, let node = guardrail.node else { continue }
                let chain = try await IAMResourceTree.ancestors(of: node, on: db)
                if let organization = chain.first(where: { $0.type == .organization }) {
                    organizationIDsByGuardrail[id] = organization.id
                }
            }

            let schemaText = CedarSchemaBuilder.schemaText()
            let staticText = CedarPolicyAssembler.staticPolicyText()
            let compiledGuardrails = CedarPolicyAssembler.guardrailPolicyText(
                guardrails, organizationIDsByGuardrail: organizationIDsByGuardrail)

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

            let policyText =
                compiledGuardrails.policyText.isEmpty
                ? staticText
                : staticText + "\n" + compiledGuardrails.policyText
            let artifact = try engine.compile(schemaText: schemaText, policyText: policyText)

            current = Built(
                version: version,
                schemaText: schemaText,
                policyText: policyText,
                guardrailCount: compiledGuardrails.compiledGuardrailIDs.count,
                skippedGuardrails: compiledGuardrails.skipped,
                artifact: artifact,
                builtAt: Date()
            )
            logger.info(
                "Compiled Cedar policy set",
                metadata: [
                    "version": .stringConvertible(version),
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

    /// Build once if nothing is cached yet — the fresh-database boot path,
    /// where the version is still 0 and no change event will ever fire.
    func rebuildIfNeeded(on db: any Database) async {
        guard current == nil else { return }
        let version = (try? await PolicySetVersionService.current(on: db)) ?? 0
        await rebuild(version: version, on: db)
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
    /// already lands here.
    func startCedarPolicySetCache() async {
        await policySetVersion.onVersionChange { [self] version in
            await cedarPolicySet.rebuild(version: version, on: db)
        }
    }
}
