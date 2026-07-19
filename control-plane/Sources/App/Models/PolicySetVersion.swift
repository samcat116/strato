import Fluent
import Foundation
import Vapor

/// One entry in the policy-set version log (docs/architecture/iam.md).
///
/// The *policy set* is everything the evaluator compiles: the platform policy
/// (tier 1), the guardrails (tier 2), and the role/action registry that tier-3
/// bindings are written against. Every change to any of those bumps the
/// version. Role **bindings** deliberately do not: they are read per-request
/// from Postgres, so a grant or revoke is effective on the next request on
/// every replica with nothing to invalidate.
///
/// The version does two jobs:
///
/// - **Cache invalidation.** Each replica compiles the policy set once and
///   holds it in memory; the version is what tells a replica its copy is
///   stale (#480 hangs the compiled set off `PolicySetVersionCache`).
/// - **Decision-log provenance.** Every decision records the version that
///   produced it (#481), so a verdict can be replayed against the exact policy
///   set in force at the time rather than whatever is current when someone
///   comes to investigate.
///
/// This is an append-only log, not a mutable counter: `reason` and
/// `changed_by` make "why did the policy set change at 03:14?" answerable, and
/// a monotonic `version` column that only ever gets new rows can't be walked
/// backwards by a botched write.
final class PolicySetVersion: Model, @unchecked Sendable {
    static let schema = "iam_policy_set_versions"

    @ID(key: .id)
    var id: UUID?

    /// Monotonic, gapless-by-construction, unique. Allocated as `max + 1`
    /// under the uniqueness constraint, so two replicas bumping concurrently
    /// produce two distinct versions rather than one lost update.
    @Field(key: "version")
    var version: Int

    /// What changed, in prose: `guardrail created: no-prod-for-contractors`.
    @Field(key: "reason")
    var reason: String

    /// The user behind the change; nil for system-driven bumps (the boot-time
    /// role-registry sync).
    @OptionalField(key: "changed_by")
    var changedBy: UUID?

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    init() {}

    init(id: UUID? = nil, version: Int, reason: String, changedBy: UUID? = nil) {
        self.id = id
        self.version = version
        self.reason = reason
        self.changedBy = changedBy
    }
}

extension PolicySetVersion: Content {}
