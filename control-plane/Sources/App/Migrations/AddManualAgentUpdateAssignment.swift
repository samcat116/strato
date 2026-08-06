import Fluent

/// ADR 0001 stage 6 (STR-145): the operator's "update now" stops dispatching an
/// imperative `agent_update` and assigns the same declarative field the fleet
/// rollout uses. Two columns are what the manual path needs beyond the rollout's
/// existing bookkeeping:
///
/// - `update_assignment_source` — who assigned `update_desired_version`. The
///   sweep owns rollout assignments and resets one whose version the deployment
///   target has moved past; a manual assignment names an operator's chosen
///   version (possibly a one-off build) and must survive that reset.
/// - `update_artifact_override` — the explicit `artifactUrl`/`sha256` a system
///   admin may supply for air-gapped or one-off builds. Release-path artifacts
///   are deliberately *not* stored: sync assembly re-resolves them every time so
///   a long-assigned update never carries a stale (possibly presigned) link.
///   An override has no release to re-resolve from, so it is pinned here.
///
///   Read that last point the right way round: this column can hold a
///   **credential at rest**. An artifact URL's query string or userinfo is often
///   the only way to authenticate a private mirror, which is why every other
///   path redacts it (`DesiredAgentUpdate.redactURL`) — and none of that
///   redaction reaches a database column, a backup, or a read replica. The
///   mitigation is lifetime, not secrecy: the value exists only while an
///   assignment does, and convergence, cancellation, withdrawal, and terminal
///   failure all drop it. Storing a stripped URL plus a separate credential
///   reference would bound it further; that is a follow-up, not this column.
struct AddManualAgentUpdateAssignment: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("agents")
            .field("update_assignment_source", .string)
            .update()
        try await database.schema("agents")
            .field("update_artifact_override", .json)
            .update()
    }

    func revert(on database: Database) async throws {
        try await database.schema("agents")
            .deleteField("update_assignment_source")
            .update()
        try await database.schema("agents")
            .deleteField("update_artifact_override")
            .update()
    }
}
