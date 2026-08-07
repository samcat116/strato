import Fluent
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
/// Unlike `resource_operations.user_id` — a non-null *user* id, which is
/// exactly what keeps machine principals off the mutation endpoints (issue
/// #495) — this names the principal's type alongside its id, and carries no id
/// at all for the system actor.
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

extension MutationActor {
    /// The actor behind an operation attributed only by `user_id`, which is
    /// every mutation today: the sweep's sentinel is the system actor rather
    /// than a user that does not exist, and everything else is a real user
    /// because the mutation endpoints still refuse machine principals
    /// (`requireActingUser`). STR-15 replaces this derivation with an actor
    /// threaded from the request principal.
    init(operationUserID id: UUID) {
        self = id == ResourceOperation.systemUserID ? .system : .user(id)
    }
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
/// This is the durable home of the attribution that lives on
/// `resource_operations.user_id` today. Mutations dual-write both while the
/// operations table is retired (ADR 0001, stage 11), and unlike `user_id` this
/// row can name a machine principal — which is what unblocks JWT-SVID
/// mutations (STR-15).
final class ResourceEvent: Model, @unchecked Sendable {
    static let schema = "resource_events"

    @ID(key: .id)
    var id: UUID?

    @Enum(key: "actor_type")
    var actorType: MutationActorType

    @OptionalField(key: "actor_id")
    var actorID: UUID?

    @Enum(key: "resource_kind")
    var resourceKind: OperationResourceKind

    @Field(key: "resource_id")
    var resourceID: UUID

    /// The resource's name when it was mutated, so a delete stays readable
    /// after the row it names is gone.
    @OptionalField(key: "resource_name")
    var resourceName: String?

    @Enum(key: "mutation")
    var mutation: VMOperationKind

    /// Whether this row records the request or its outcome (STR-147). Rows
    /// written before the column existed are `requested`, which is what every
    /// one of them was.
    @Enum(key: "phase")
    var phase: ResourceEventPhase

    /// The resource's generation once the mutation applied — the generation an
    /// agent's observed report has to reach before this mutation counts as
    /// converged. Nil when the resource could not be read back (it has no
    /// generation to name), and, for the mutations that do not bump one
    /// (a VM reboot is an action, not a state), simply the generation the
    /// mutation was issued against.
    @OptionalField(key: "target_generation")
    var targetGeneration: Int64?

    @OptionalField(key: "organization_id")
    var organizationID: UUID?

    @OptionalField(key: "project_id")
    var projectID: UUID?

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    init() {}
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
        of kind: OperationResourceKind, id: UUID, on db: any Database
    ) async throws -> Scope {
        var scope = Scope()
        switch kind {
        case .virtualMachine:
            guard let vm = try await VM.find(id, on: db) else { return scope }
            scope.projectID = vm.$project.id
            scope.resourceName = vm.name
            scope.generation = vm.generation
        case .sandbox:
            guard let sandbox = try await Sandbox.find(id, on: db) else { return scope }
            scope.projectID = sandbox.$project.id
            scope.resourceName = sandbox.name
            scope.generation = sandbox.generation
        case .volume:
            guard let volume = try await Volume.find(id, on: db) else { return scope }
            scope.projectID = volume.$project.id
            scope.resourceName = volume.name
            scope.generation = volume.generation
        case .volumeSnapshot:
            guard let snapshot = try await VolumeSnapshot.find(id, on: db) else { return scope }
            scope.projectID = snapshot.$project.id
            scope.resourceName = snapshot.name
            scope.generation = snapshot.generation
        case .vmCheckpoint:
            guard let snapshot = try await VMSnapshot.find(id, on: db) else { return scope }
            scope.projectID = snapshot.$project.id
            scope.resourceName = snapshot.name
            scope.generation = snapshot.generation
        case .sandboxSnapshot:
            guard let snapshot = try await SandboxSnapshot.find(id, on: db) else { return scope }
            scope.projectID = snapshot.$project.id
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
        of kind: OperationResourceKind, id: UUID, on db: any Database
    ) async throws -> Int64? {
        switch kind {
        case .virtualMachine:
            return try await VM.query(on: db)
                .filter(\.$id == id)
                .field(\.$generation)
                .first()?.generation
        case .sandbox:
            return try await Sandbox.query(on: db)
                .filter(\.$id == id)
                .field(\.$generation)
                .first()?.generation
        case .volume:
            return try await Volume.query(on: db)
                .filter(\.$id == id)
                .field(\.$generation)
                .first()?.generation
        case .volumeSnapshot:
            return try await VolumeSnapshot.query(on: db)
                .filter(\.$id == id)
                .field(\.$generation)
                .first()?.generation
        case .vmCheckpoint:
            return try await VMSnapshot.query(on: db)
                .filter(\.$id == id)
                .field(\.$generation)
                .first()?.generation
        case .sandboxSnapshot:
            return try await SandboxSnapshot.query(on: db)
                .filter(\.$id == id)
                .field(\.$generation)
                .first()?.generation
        }
    }

    /// Appends the event for one mutation.
    ///
    /// Call this inside the mutation's own transaction, after the mutation has
    /// applied. It throws rather than logging on failure, so a mutation that
    /// cannot be attributed rolls back instead of applying unrecorded — the
    /// whole value of the table is that it is not missing rows.
    ///
    /// `scope` is a parameter because `ResourceOperation.begin` already
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
        on db: any Database
    ) async throws -> ResourceEvent {
        let resolved: Scope
        if let scope {
            resolved = scope
        } else {
            resolved = try await Self.scope(of: resourceKind, id: resourceID, on: db)
        }

        let event = ResourceEvent()
        event.actorType = actor.type
        event.actorID = actor.id
        event.resourceKind = resourceKind
        event.resourceID = resourceID
        event.resourceName = resolved.resourceName
        event.mutation = mutation
        event.phase = phase
        event.targetGeneration = resolved.generation
        event.organizationID = resolved.organizationID
        event.projectID = resolved.projectID
        try await event.save(on: db)
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
        on db: any Database
    ) async throws -> ResourceEvent? {
        try await ResourceEvent.query(on: db)
            .filter(\.$resourceKind == resourceKind)
            .filter(\.$resourceID == resourceID)
            .filter(\.$phase == phase)
            .sort(\.$createdAt, .descending)
            .first()
    }
}
