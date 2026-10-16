import Foundation

import StratoShared

public typealias SandboxAutomaticSuspensionFence = StratoShared.SandboxAutomaticSuspensionFence

public struct SandboxSuspensionGuestFence: Codable, Sendable, Equatable {
    public enum State: String, Codable, Sendable { case preparePending, prepared, releasePending, released }
    public let request: SandboxAutomaticSuspensionFence
    public let identityNonce: String
    public var state: State = .preparePending
    public var guestToken: UUID?

    public init(request: SandboxAutomaticSuspensionFence, identityNonce: String) {
        self.request = request
        self.identityNonce = identityNonce
    }

    public func hasValidShape(for record: SandboxSuspensionRecord) -> Bool {
        request.generation == record.generation && request.generation >= 0 && request.activityRevision >= 0
            && request.guestProtocolVersion == 5 && !identityNonce.isEmpty && record.spec.network == nil
            && (state != .prepared || guestToken != nil)
    }
    public var blocksWorkloadAdmission: Bool { state != .released }
}

public struct SandboxSuspensionFenceContext: Sendable {
    public let sandboxId: UUID
    public let checkpointId: UUID
    public let fence: SandboxSuspensionGuestFence
    public init(record: SandboxSuspensionRecord) throws {
        guard let fence = record.guestFence, fence.hasValidShape(for: record) else {
            throw SandboxSuspensionGuard.GateError.stale
        }
        self.sandboxId = record.sandboxId
        self.checkpointId = record.snapshotId
        self.fence = fence
    }
}

public enum SandboxGuestFenceStatus: Sendable, Equatable {
    case absent, prepared(UUID), released
}

/// Every operation is identity-bound and idempotent by operationId. Prepare
/// atomically verifies complete trusted monitoring/eligibility, closes
/// admission and freezes workloads while retaining control. Unknown or active
/// guest state must refuse prepare; reports alone never authorize freezing.
/// Query must survive guest checkpoint/restore. Release handles lost prepare
/// responses (nil guestToken) by operationId and permanently prevents reuse.
/// validateAdmission checks a durable CP token invalidated by new admissions;
/// a sampled activity revision alone does not implement this contract.
/// Admission validation must not contact the guest: the VMM is paused during
/// the final CP fence check. Implementations must bound transport operations.
public protocol SandboxAutomaticSuspensionTransport: Sendable {
    func prepare(_ context: SandboxSuspensionFenceContext) async throws -> UUID
    func query(_ context: SandboxSuspensionFenceContext) async throws -> SandboxGuestFenceStatus
    func validateAdmission(_ context: SandboxSuspensionFenceContext) async throws
    func release(_ context: SandboxSuspensionFenceContext) async throws
}

/// Persistence happens before every side effect. A transport failure retains
/// the pending journal; a new host instance can recover using the same store.
public struct SandboxAutomaticSuspensionLifecycle: Sendable {
    public let store: SandboxSuspensionStore
    public let transport: any SandboxAutomaticSuspensionTransport
    public init(store: SandboxSuspensionStore, transport: any SandboxAutomaticSuspensionTransport) {
        self.store = store
        self.transport = transport
    }

    public func prepare(_ input: SandboxSuspensionRecord) async throws -> SandboxSuspensionRecord {
        var record = input
        let context = try SandboxSuspensionFenceContext(record: record)
        guard context.fence.state == .preparePending || context.fence.state == .prepared else {
            throw SandboxSuspensionGuard.GateError.stale
        }
        try store.save(record)
        try Task.checkCancellation()
        try await transport.validateAdmission(context)
        let status = try await transport.query(context)
        let token: UUID
        switch status {
        case .absent:
            guard context.fence.state == .preparePending else { throw SandboxSuspensionGuard.GateError.stale }
            token = try await transport.prepare(context)
        case .prepared(let existing): token = existing
        case .released: throw SandboxSuspensionGuard.GateError.stale
        }
        if let expected = record.guestFence?.guestToken, expected != token {
            throw SandboxSuspensionGuard.GateError.stale
        }
        guard try await transport.query(context) == .prepared(token) else {
            throw SandboxSuspensionGuard.GateError.stale
        }
        record.guestFence?.guestToken = token
        record.guestFence?.state = .prepared
        try store.save(record)
        return record
    }

    public func validateDestruction(_ record: SandboxSuspensionRecord) async throws {
        let context = try SandboxSuspensionFenceContext(record: record)
        guard context.fence.state == .prepared, context.fence.guestToken != nil else {
            throw SandboxSuspensionGuard.GateError.stale
        }
        // The VMM is paused here; this is exclusively a durable CP check.
        // Guest prepare/query completed before snapshot pause.
        try await transport.validateAdmission(context)
    }

    /// Caller proves the original survived rollback or verifies restored guest
    /// identity before releasing. This method never authorizes VMM destruction.
    public func release(_ input: SandboxSuspensionRecord, restoredCopy: Bool = false) async throws
        -> SandboxSuspensionRecord
    {
        var record = input
        guard let fence = record.guestFence else { return record }
        if fence.state == .released && !restoredCopy { return record }
        record.guestFence?.state = .releasePending
        try store.save(record)
        let context = try SandboxSuspensionFenceContext(record: record)
        try await transport.release(context)
        guard try await transport.query(context) == .released else {
            throw SandboxSuspensionGuard.GateError.stale
        }
        record.guestFence?.state = .released
        try store.save(record)
        return record
    }
}
