import ControlPlanePostgres
import Foundation
import StratoShared
import Vapor

/// The kind of principal a mutation is attributed to.
///
/// Mirrors `IAMPrincipalType` minus `group` (a group never acts) and plus
/// `system` (the control plane acting on its own — today only the sandbox
/// expiry sweep). Deliberately its own enum rather than a reuse: an audit
/// trail has to keep decoding rows written long before the current schema,
/// while `IAMPrincipalType` is free to follow the Cedar schema.
enum MutationActorType: String, Codable, CaseIterable, Sendable {
    case user
    case serviceAccount = "service_account"
    case workload
    case system
}

/// Who performed a mutation.
///
/// The attribution `resource_operations.user_id` used to carry, minus that
/// column's two limitations: it was a non-null *user* id, so it could name
/// neither a machine principal nor the control plane acting on its own, and
/// the latter had to be spelled as a sentinel UUID matching no real user. This
/// names the principal's type alongside its id, and carries no id at all for
/// `.system`.
struct MutationActor: Sendable, Equatable {
    let type: MutationActorType

    /// The principal's row id: a user, a service account, or a workload
    /// registration. Nil for `.system`, which is not a row.
    let id: UUID?

    static func user(_ id: UUID) -> MutationActor { MutationActor(type: .user, id: id) }
    static func serviceAccount(_ id: UUID) -> MutationActor { MutationActor(type: .serviceAccount, id: id) }
    static func workload(_ id: UUID) -> MutationActor { MutationActor(type: .workload, id: id) }

    /// The control plane acting with no principal behind it — the sandbox
    /// expiry sweep (issue #424).
    static let system = MutationActor(type: .system, id: nil)
}

/// Which half of a mutation's life a `ResourceEvent` row records.
///
/// The table is append-only, so a mutation that finishes does not update its
/// request — it appends a second row. Only deletes do this today, and for one
/// reason: every other mutation's outcome is readable off the resource's own
/// `conditions`, while a delete's success is the resource *not being there*,
/// which a client cannot tell from never-existed or not-authorized (STR-147).
enum ResourceEventPhase: String, Codable, CaseIterable, Sendable {
    /// A mutation was accepted. Every row written at mutation time.
    case requested
    /// The mutation reached its goal. Appended by the finalizer reap for a
    /// delete; the resource's `conditions` say it for everything else.
    case completed
    /// The mutation will not reach its goal. Reserved: nothing appends this
    /// yet, because a failed mutation leaves a resource whose `conditions`
    /// carry the reason. It exists so the façade's terminal lookup does not
    /// have to change shape when a delete gains a way to fail permanently.
    case failed
}

/// One append-only record of a resource mutation: who asked for it, what it
/// acted on, which mutation it was, and the generation the owning agent has to
/// reach for it to be converged (ADR 0001, stage 2).
///
/// Rows are appended inside the mutation's own transaction and are never
/// updated and never swept — an audit trail that admits no edits is the point.
/// There is deliberately no retention policy; revisit only if volume demands
/// one.
///
/// Every id column is foreign-key-free for the reason `resource_operations`
/// has none, only more so: the record has to outlive both the resource it
/// describes (after a successful delete it is the last evidence the resource
/// existed) and the principal that mutated it.
///
/// This is the durable home of mutation attribution, and since ADR 0001 stage
/// 11 (STR-152) the only one — `resource_operations.user_id` was the other, and
/// went with its table. Unlike `user_id` this row can name a machine principal,
/// which is what unblocks JWT-SVID mutations (STR-15).
/// Immutable rows may cross task boundaries; writes always append a new row.
struct ResourceEvent: Decodable, Equatable, Sendable {
    let id: UUID?
    let actorType: MutationActorType
    let actorID: UUID?
    let resourceKind: OperationResourceKind
    let resourceID: UUID
    let resourceName: String?
    let mutation: VMOperationKind
    let phase: ResourceEventPhase
    let targetGeneration: Int64?
    let organizationID: UUID?
    let projectID: UUID?
    let createdAt: Date?

    func requireID() throws -> UUID {
        guard let id else {
            throw Abort(.internalServerError, reason: "Resource event has no identifier")
        }
        return id
    }
}

extension ResourceEvent {
    /// Everything about a resource that its mutation event snapshots: where it
    /// sits in the organization hierarchy, what it is called, and where its
    /// desired state has got to.
    ///
    /// Every field is optional because resolution is best-effort. A project
    /// with no organization, or a resource already removed, still deserves an
    /// attribution record — an all-or-nothing context would drop exactly the
    /// events that are hardest to reconstruct later.
    struct Scope: Sendable, Equatable {
        var organizationID: UUID? = nil
        var projectID: UUID? = nil
        var resourceName: String? = nil
        var generation: Int64? = nil
    }

    /// Reads a resource's current scope. Callers recording a mutation must
    /// resolve this *after* applying it: the generation it captures is the one
    /// the mutation just set.
    static func scope(
        of kind: OperationResourceKind, id: UUID, on db: PostgresStoreContext
    ) async throws -> Scope {
        var scope = Scope()
        switch kind {
        case .virtualMachine:
            guard let vm = try await VM.find(id, on: db) else { return scope }
            scope.projectID = vm.projectID
            scope.resourceName = vm.name
            scope.generation = vm.generation
        case .sandbox:
            guard let sandbox = try await Sandbox.find(id, on: db) else { return scope }
            scope.projectID = sandbox.projectID
            scope.resourceName = sandbox.name
            scope.generation = sandbox.generation
        case .volume:
            guard let volume = try await Volume.find(id, on: db) else { return scope }
            scope.projectID = volume.projectID
            scope.resourceName = volume.name
            scope.generation = volume.generation
        case .volumeSnapshot:
            guard let snapshot = try await VolumeSnapshot.find(id, on: db) else { return scope }
            scope.projectID = snapshot.projectID
            scope.resourceName = snapshot.name
            scope.generation = snapshot.generation
        case .vmCheckpoint:
            guard let snapshot = try await VMSnapshot.find(id, on: db) else { return scope }
            scope.projectID = snapshot.projectID
            scope.resourceName = snapshot.name
            scope.generation = snapshot.generation
        case .sandboxSnapshot:
            guard let snapshot = try await SandboxSnapshot.find(id, on: db) else { return scope }
            scope.projectID = snapshot.projectID
            scope.resourceName = snapshot.name
            scope.generation = snapshot.generation
        }
        guard let projectID = scope.projectID,
            let project = try await Project.find(projectID, on: db)
        else { return scope }
        scope.organizationID = try await project.getRootOrganizationId(on: db)
        return scope
    }

    /// The resource's current generation. Nil when its row is gone — there is
    /// no generation to name.
    ///
    /// Separate from `scope` so a caller that resolved the scope *before*
    /// applying a mutation can refresh just this: the generation is the only
    /// part of the scope a mutation moves, and the rest has to be read while
    /// the row is certain to still exist.
    ///
    /// Projected to the one column rather than a `find`: this runs in every
    /// lifecycle mutation's transaction, and `vms` is a wide row to fetch for
    /// a single `Int64`. Only `generation` may be read off the returned model
    /// — no other property was selected.
    static func generation(
        of kind: OperationResourceKind, id: UUID, on db: PostgresStoreContext
    ) async throws -> Int64? {
        switch kind {
        case .virtualMachine:
            return try await VM.find(id, on: db)?.generation
        case .sandbox:
            return try await Sandbox.find(id, on: db)?.generation
        case .volume:
            return try await Volume.find(id, on: db)?.generation
        case .volumeSnapshot:
            return try await VolumeSnapshot.find(id, on: db)?.generation
        case .vmCheckpoint:
            return try await VMSnapshot.find(id, on: db)?.generation
        case .sandboxSnapshot:
            return try await SandboxSnapshot.find(id, on: db)?.generation
        }
    }

    /// Appends the event for one mutation.
    ///
    /// Call this inside the mutation's own transaction, after the mutation has
    /// applied. It throws rather than logging on failure, so a mutation that
    /// cannot be attributed rolls back instead of applying unrecorded — the
    /// whole value of the table is that it is not missing rows.
    ///
    /// `scope` is a parameter because `ResourceMutation.accept` already
    /// resolves one for the operation's webhook delivery context; anyone else
    /// leaves it nil and this resolves its own.
    ///
    /// `phase` defaults to `.requested`, which is what a mutation records. The
    /// terminal counterpart is appended by whoever observes the outcome — for
    /// a delete, `FinalizableResource.reap`.
    @discardableResult
    static func record(
        _ mutation: VMOperationKind,
        resourceKind: OperationResourceKind,
        resourceID: UUID,
        actor: MutationActor,
        phase: ResourceEventPhase = .requested,
        scope: Scope? = nil,
        on db: PostgresStoreContext
    ) async throws -> ResourceEvent {
        let resolved: Scope
        if let scope {
            resolved = scope
        } else {
            resolved = try await Self.scope(of: resourceKind, id: resourceID, on: db)
        }

        guard let sql = db as? PostgresStoreContext else {
            throw Abort(.internalServerError, reason: "Resource events require a SQL database")
        }
        let rows = try await sql.raw(
            """
            INSERT INTO resource_events (
                id, actor_type, actor_id, resource_kind, resource_id,
                resource_name, mutation, phase, target_generation,
                organization_id, project_id, created_at
            ) VALUES (
                \(bind: UUID()), \(bind: actor.type.rawValue), \(bind: actor.id),
                \(bind: resourceKind.rawValue), \(bind: resourceID),
                \(bind: resolved.resourceName), \(bind: mutation.rawValue),
                \(bind: phase.rawValue), \(bind: resolved.generation),
                \(bind: resolved.organizationID), \(bind: resolved.projectID),
                CURRENT_TIMESTAMP
            )
            RETURNING \(unsafeRaw: eventColumns)
            """
        ).all(decoding: ResourceEvent.self)
        guard rows.count == 1, let event = rows.first else {
            throw Abort(.internalServerError, reason: "Resource event insert returned an unexpected row count")
        }
        return event
    }

    /// The newest event of `phase` for a resource, or nil if it has none.
    ///
    /// Two readers: the operations façade, asking "did this delete finish?"
    /// (`.completed`) after the row it names is gone, and the observed-state
    /// applier, asking "which mutation just converged?" (`.requested`) to name
    /// it in the completion webhook.
    static func latest(
        _ phase: ResourceEventPhase,
        resourceKind: OperationResourceKind,
        resourceID: UUID,
        on db: PostgresStoreContext
    ) async throws -> ResourceEvent? {
        try await matching(
            resourceKind: resourceKind,
            resourceID: resourceID,
            phase: phase,
            limit: 1,
            on: db
        ).first
    }

    static func find(_ id: UUID, on db: PostgresStoreContext) async throws -> ResourceEvent? {
        guard let sql = db as? PostgresStoreContext else {
            throw Abort(.internalServerError, reason: "Resource events require a SQL database")
        }
        return try await sql.raw(
            "SELECT \(unsafeRaw: eventColumns) FROM resource_events WHERE id = \(bind: id)"
        ).first(decoding: ResourceEvent.self)
    }

    /// Bound, allowlisted read used by operation history and compatibility
    /// tests while resource mutations still share Fluent transactions.
    static func matching(
        resourceKind: OperationResourceKind? = nil,
        resourceID: UUID? = nil,
        mutation: VMOperationKind? = nil,
        phase: ResourceEventPhase? = nil,
        ascending: Bool = false,
        limit: Int? = nil,
        on db: PostgresStoreContext
    ) async throws -> [ResourceEvent] {
        guard let sql = db as? PostgresStoreContext else {
            throw Abort(.internalServerError, reason: "Resource events require a SQL database")
        }
        var query: PostgresSQLQuery =
            "SELECT \(unsafeRaw: eventColumns) FROM resource_events WHERE TRUE"
        if let resourceKind {
            query += " AND resource_kind = \(bind: resourceKind.rawValue)"
        }
        if let resourceID {
            query += " AND resource_id = \(bind: resourceID)"
        }
        if let mutation {
            query += " AND mutation = \(bind: mutation.rawValue)"
        }
        if let phase {
            query += " AND phase = \(bind: phase.rawValue)"
        }
        query += ascending
            ? " ORDER BY created_at ASC, id ASC"
            : " ORDER BY created_at DESC, id DESC"
        if let limit {
            query += " LIMIT \(bind: limit)"
        }
        return try await sql.raw(query).all(decoding: ResourceEvent.self)
    }

    static func count(
        resourceKind: OperationResourceKind? = nil,
        on db: PostgresStoreContext
    ) async throws -> Int {
        struct CountRow: Decodable { let count: Int }
        guard let sql = db as? PostgresStoreContext else {
            throw Abort(.internalServerError, reason: "Resource events require a SQL database")
        }
        var query: PostgresSQLQuery = "SELECT COUNT(*)::bigint AS count FROM resource_events WHERE TRUE"
        if let resourceKind {
            query += " AND resource_kind = \(bind: resourceKind.rawValue)"
        }
        return try await sql.raw(query).first(decoding: CountRow.self)?.count ?? 0
    }
}

private let eventColumns = """
    id,
    actor_type AS "actorType",
    actor_id AS "actorID",
    resource_kind AS "resourceKind",
    resource_id AS "resourceID",
    resource_name AS "resourceName",
    mutation,
    phase,
    target_generation AS "targetGeneration",
    organization_id AS "organizationID",
    project_id AS "projectID",
    created_at AS "createdAt"
    """
