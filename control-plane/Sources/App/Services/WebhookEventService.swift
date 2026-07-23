import Fluent
import Foundation
import StratoShared
import Vapor

/// The typed event catalog for user-managed webhooks (issue #559).
///
/// Raw values are the wire-stable `type` field of delivered payloads and the
/// values stored in a subscription's event-type selection — renaming one is a
/// breaking API change. Growing the catalog is one new case plus an emit call
/// at the semantic moment.
enum WebhookEventType: String, Codable, CaseIterable, Sendable {
    /// An async resource operation (VM or sandbox create/start/stop/delete/
    /// reboot/…) reached `succeeded`.
    case operationCompleted = "operation.completed"
    /// An async resource operation reached `failed`.
    case operationFailed = "operation.failed"
    /// A VM's observed status changed (agent reports, drift, loss).
    case vmStateChanged = "vm.state_changed"
    case agentConnected = "agent.connected"
    case agentDisconnected = "agent.disconnected"
    /// A quota pool crossed a warning (80%) or exhaustion (100%) threshold
    /// while admitting a workload.
    case quotaThresholdExceeded = "quota.threshold_exceeded"
    /// Manual "send test event" deliveries. Not subscribable: it is enqueued
    /// directly for the target subscription, bypassing its type selection.
    case webhookTest = "webhook.test"

    /// The types a subscription may select — everything except the test event.
    static var subscribable: [WebhookEventType] {
        allCases.filter { $0 != .webhookTest }
    }
}

/// One semantic platform event, before fan-out. `encodedPayload()` freezes it
/// into the JSON body that every matching subscription's delivery will POST.
struct WebhookEvent: Sendable {
    struct Resource: Codable, Sendable {
        let kind: String
        let id: UUID
        let name: String?
    }

    let id: UUID
    let type: WebhookEventType
    let timestamp: Date
    let organizationID: UUID
    let projectID: UUID?
    let resource: Resource?
    let data: [String: CodableValue]

    init(
        type: WebhookEventType,
        organizationID: UUID,
        projectID: UUID? = nil,
        resource: Resource? = nil,
        data: [String: CodableValue] = [:]
    ) {
        self.id = UUID()
        self.type = type
        self.timestamp = Date()
        self.organizationID = organizationID
        self.projectID = projectID
        self.resource = resource
        self.data = data
    }

    /// Wire shape of a delivered event. Field names are API surface.
    private struct Payload: Codable {
        let id: UUID
        let type: String
        let timestamp: Date
        let organizationId: UUID
        let projectId: UUID?
        let resource: Resource?
        let data: [String: CodableValue]
    }

    func encodedPayload() throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let payload = Payload(
            id: id, type: type.rawValue, timestamp: timestamp,
            organizationId: organizationID, projectId: projectID,
            resource: resource, data: data)
        let data = try encoder.encode(payload)
        guard let string = String(data: data, encoding: .utf8) else {
            throw Abort(.internalServerError, reason: "Webhook payload is not valid UTF-8")
        }
        return string
    }
}

/// A quota's reservation counters before an admission mutated them, so
/// threshold crossings compare pre- vs post-admission usage.
struct QuotaUsageSnapshot: Sendable {
    let vcpus: Int
    let memory: Int64
    let storage: Int64
    let vms: Int
    let sandboxes: Int

    init(of quota: ResourceQuota) {
        self.vcpus = quota.reservedVCPUs
        self.memory = quota.reservedMemory
        self.storage = quota.reservedStorage
        self.vms = quota.vmCount
        self.sandboxes = quota.sandboxCount
    }
}

/// Enqueues webhook events into the `webhook_deliveries` outbox.
///
/// `enqueue` is the transactional entry point: called on the same `Database`
/// handle as the state change that produced the event, the delivery rows
/// commit (or roll back) atomically with it. `emit` is the fire-and-forget
/// variant for call sites outside any transaction, where a webhook bookkeeping
/// failure must never break the main path.
enum WebhookEvents {
    /// Fan the event out to every matching active subscription. Throws on
    /// database errors so transactional callers stay atomic.
    static func enqueue(_ event: WebhookEvent, on db: Database) async throws {
        let subscriptions = try await WebhookSubscription.query(on: db)
            .filter(\.$organization.$id == event.organizationID)
            .filter(\.$isActive == true)
            .all()

        let matching = subscriptions.filter { subscription in
            guard subscription.subscribes(to: event.type) else { return false }
            // A project-scoped subscription only receives events that carry
            // its project; org-wide events (agent presence) stay org-level.
            if let scopedProject = subscription.$project.id {
                return event.projectID == scopedProject
            }
            return true
        }
        guard !matching.isEmpty else { return }

        let payload = try event.encodedPayload()
        for subscription in matching {
            let delivery = WebhookDelivery(
                subscriptionID: try subscription.requireID(),
                eventID: event.id,
                eventType: event.type,
                payload: payload)
            try await delivery.save(on: db)
        }
    }

    /// Non-throwing wrapper for call sites outside a transaction.
    static func emit(_ event: WebhookEvent, on db: Database, logger: Logger) async {
        do {
            try await enqueue(event, on: db)
        } catch {
            logger.error(
                "Failed to enqueue webhook event",
                metadata: [
                    "eventType": .string(event.type.rawValue),
                    "organizationId": .string(event.organizationID.uuidString),
                    "error": .string("\(error)"),
                ])
        }
    }

    // MARK: - Operation completion (the chokepoint sources)

    /// Enqueue `operation.completed`/`operation.failed` for a just-completed
    /// operation. Called from `ResourceOperation.completeIfPending` — the one
    /// funnel every completion path (agent report, post-202 task, stuck sweep)
    /// goes through — so individual sources need no wiring.
    ///
    /// Context (org/project/name) comes from the operation row itself, where
    /// `begin` captured it — the resource may already be gone by completion
    /// time (a successful delete removes the row first). Operations without
    /// stamped context (pre-migration rows, direct-construction sites) fall
    /// back to resolving from the live resource; only when both are missing
    /// is there genuinely no organization to deliver to, and the event is
    /// skipped.
    static func enqueueOperationCompletion(
        for operation: ResourceOperation, on db: Database
    ) async throws {
        var context: (organizationID: UUID, projectID: UUID?, resourceName: String?)?
        if let organizationID = operation.organizationID {
            context = (organizationID, operation.projectID, operation.resourceName)
        } else {
            context = try await resourceContext(
                kind: operation.resourceKind, id: operation.resourceID, on: db)
        }
        guard let context else { return }

        var data: [String: CodableValue] = [
            "operationId": .string(operation.id?.uuidString ?? ""),
            "operationKind": .string(operation.kind.rawValue),
            "status": .string(operation.status.rawValue),
        ]
        if let error = operation.error {
            data["error"] = .string(error)
        }

        let event = WebhookEvent(
            type: operation.status == .succeeded ? .operationCompleted : .operationFailed,
            organizationID: context.organizationID,
            projectID: context.projectID,
            resource: WebhookEvent.Resource(
                kind: operation.resourceKind.rawValue, id: operation.resourceID,
                name: context.resourceName),
            data: data)
        try await enqueue(event, on: db)
    }

    /// Resolves the owning organization/project and display name for an
    /// operation's resource. Nil when the resource row no longer exists.
    /// Internal so `ResourceOperation.begin` can stamp the same context onto
    /// the operation row while the resource still exists.
    static func resourceContext(
        kind: OperationResourceKind, id: UUID, on db: Database
    ) async throws -> (organizationID: UUID, projectID: UUID?, resourceName: String?)? {
        let projectID: UUID?
        let name: String?
        switch kind {
        case .virtualMachine:
            guard let vm = try await VM.find(id, on: db) else { return nil }
            projectID = vm.$project.id
            name = vm.name
        case .sandbox:
            guard let sandbox = try await Sandbox.find(id, on: db) else { return nil }
            projectID = sandbox.$project.id
            name = sandbox.name
        }
        guard let projectID,
            let project = try await Project.find(projectID, on: db),
            let organizationID = try await project.getRootOrganizationId(on: db)
        else { return nil }
        return (organizationID, projectID, name)
    }

    // MARK: - VM state changes

    /// Enqueue `vm.state_changed` for an observed status transition.
    /// Fire-and-forget: observed-state bookkeeping must not fail on webhook
    /// machinery.
    static func emitVMStateChanged(
        vm: VM, previous: VMStatus, current: VMStatus, on db: Database, logger: Logger
    ) async {
        guard let vmID = vm.id else { return }
        guard let project = try? await Project.find(vm.$project.id, on: db),
            let organizationID = try? await project.getRootOrganizationId(on: db)
        else { return }

        let event = WebhookEvent(
            type: .vmStateChanged,
            organizationID: organizationID,
            projectID: vm.$project.id,
            resource: WebhookEvent.Resource(
                kind: OperationResourceKind.virtualMachine.rawValue, id: vmID, name: vm.name),
            data: [
                "previousStatus": .string(previous.rawValue),
                "newStatus": .string(current.rawValue),
            ])
        await emit(event, on: db, logger: logger)
    }

    // MARK: - Quota thresholds

    /// Warning and exhaustion levels, in percent of a quota pool.
    static let quotaThresholds: [Int] = [100, 80]

    /// Enqueue `quota.threshold_exceeded` for every pool of `quota` that the
    /// current admission pushed across a threshold the baseline was still
    /// under. Called inside the admission transaction (after the reservation
    /// was applied to the model), so the events commit with the reservation.
    static func enqueueQuotaThresholds(
        quota: ResourceQuota,
        baseline: QuotaUsageSnapshot,
        project: Project,
        on db: Database
    ) async throws {
        guard quota.isEnabled, let quotaID = quota.id else { return }
        guard let organizationID = try await project.getRootOrganizationId(on: db) else { return }

        let pools: [(pool: String, before: Int64, after: Int64, limit: Int64)] = [
            ("vcpus", Int64(baseline.vcpus), Int64(quota.reservedVCPUs), Int64(quota.maxVCPUs)),
            ("memory", baseline.memory, quota.reservedMemory, quota.maxMemory),
            ("storage", baseline.storage, quota.reservedStorage, quota.maxStorage),
            ("vms", Int64(baseline.vms), Int64(quota.vmCount), Int64(quota.maxVMs)),
            ("sandboxes", Int64(baseline.sandboxes), Int64(quota.sandboxCount), Int64(quota.maxSandboxes)),
        ]

        for entry in pools {
            guard entry.limit > 0 else { continue }
            let beforePercent = Double(entry.before) / Double(entry.limit) * 100
            let afterPercent = Double(entry.after) / Double(entry.limit) * 100
            guard
                let crossed = Self.quotaThresholds.first(where: { threshold in
                    beforePercent < Double(threshold) && afterPercent >= Double(threshold)
                })
            else { continue }

            let event = WebhookEvent(
                type: .quotaThresholdExceeded,
                organizationID: organizationID,
                projectID: project.id,
                resource: WebhookEvent.Resource(kind: "resource_quota", id: quotaID, name: quota.name),
                data: [
                    "pool": .string(entry.pool),
                    "threshold": .int(crossed),
                    "percentUsed": .double((afterPercent * 10).rounded() / 10),
                    "reserved": .int(Int(entry.after)),
                    "limit": .int(Int(entry.limit)),
                ])
            try await enqueue(event, on: db)
        }
    }

    // MARK: - Agent presence

    /// Enqueue `agent.connected`/`agent.disconnected`. Agents without an
    /// organization scope have no tenant to notify and are skipped.
    static func emitAgentPresence(
        agent: Agent, connected: Bool, reason: String, on db: Database, logger: Logger
    ) async {
        guard let agentID = agent.id,
            let organizationID = try? await agent.rootOrganizationID(on: db)
        else { return }

        let event = WebhookEvent(
            type: connected ? .agentConnected : .agentDisconnected,
            organizationID: organizationID,
            resource: WebhookEvent.Resource(kind: "agent", id: agentID, name: agent.name),
            data: ["reason": .string(reason)])
        await emit(event, on: db, logger: logger)
    }
}
