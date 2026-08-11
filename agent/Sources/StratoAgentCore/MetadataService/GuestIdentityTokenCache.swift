import Foundation
import StratoShared

/// The one privileged operation the guest-facing metadata listener may ask of
/// its parent agent. Keeping it as a closure-sized capability means the child
/// does not receive the agent's SPIFFE key material or control-plane client.
public struct GuestIdentityMinter: Sendable {
    public typealias Operation = @Sendable (UUID, String, Int) async throws -> GuestJWTSVIDResponse

    private let operation: Operation

    public init(_ operation: @escaping Operation) {
        self.operation = operation
    }

    public func mint(vmId: UUID, audience: String, ttlSeconds: Int) async throws -> GuestJWTSVIDResponse {
        try await operation(vmId, audience, ttlSeconds)
    }
}

public enum GuestIdentityMintingError: Error, Sendable, Equatable {
    case unavailable
    case invalidResponse
}

/// Agent-side JWT-SVID cache, keyed by the authority boundary the issue names:
/// one VM and one audience. Entries refresh at half-life, but a failed refresh
/// falls back to the cached bearer credential only while it is still valid.
public actor GuestIdentityTokenCache {
    private struct Key: Hashable, Sendable {
        let vmId: UUID
        let audience: String
    }

    private struct Entry: Sendable {
        let response: GuestJWTSVIDResponse
        let refreshAfter: Date
        let policy: IdentityPolicy
    }

    private struct Pending: Sendable {
        let id: UUID
        let policy: IdentityPolicy
        let task: Task<GuestJWTSVIDResponse, Error>
    }

    private var entries: [Key: Entry] = [:]
    private var inFlight: [Key: Pending] = [:]
    private let currentDate: @Sendable () -> Date

    public init() {
        self.currentDate = { Date() }
    }

    init(currentDate: @escaping @Sendable () -> Date) {
        self.currentDate = currentDate
    }

    public func token(
        vmId: UUID,
        audience: String,
        policy: IdentityPolicy,
        now: Date,
        minter: GuestIdentityMinter
    ) async throws -> GuestJWTSVIDResponse {
        let key = Key(vmId: vmId, audience: audience)
        let cached = entries[key]
        if let cached, cached.policy == policy, now < cached.refreshAfter {
            return cached.response
        }

        let ttl = min(900, max(1, min(300, policy.ttlSeconds ?? 300)))
        let pending: Pending
        let task: Task<GuestJWTSVIDResponse, Error>
        if let existing = inFlight[key], existing.policy == policy {
            pending = existing
            task = existing.task
        } else {
            inFlight[key]?.task.cancel()
            // The endpoint exposes no TTL input. Five minutes is therefore the
            // requested default, reduced by a stricter policy if one exists;
            // the hard 15-minute ceiling remains defense in depth.
            task = Task {
                try await minter.mint(vmId: vmId, audience: audience, ttlSeconds: ttl)
            }
            pending = Pending(id: UUID(), policy: policy, task: task)
            inFlight[key] = pending
        }

        do {
            let response = try await task.value
            let completedAt = max(now, currentDate())
            if inFlight[key]?.id == pending.id { inFlight.removeValue(forKey: key) }
            guard !task.isCancelled else { throw CancellationError() }
            let issuedAt = min(response.issuedAt ?? completedAt, completedAt)
            guard response.spiffeId == policy.spiffeId,
                response.audiences == [audience],
                response.expiresAt > completedAt,
                response.expiresAt.timeIntervalSince(issuedAt) <= TimeInterval(ttl)
            else {
                throw GuestIdentityMintingError.invalidResponse
            }
            let refreshAfter = issuedAt.addingTimeInterval(response.expiresAt.timeIntervalSince(issuedAt) / 2)
            entries[key] = Entry(response: response, refreshAfter: refreshAfter, policy: policy)
            return response
        } catch {
            let completedAt = max(now, currentDate())
            if inFlight[key]?.id == pending.id { inFlight.removeValue(forKey: key) }
            if let cached, cached.policy == policy, completedAt < cached.response.expiresAt {
                return cached.response
            }
            throw error
        }
    }

    /// Drop credentials and work that no longer match the authoritative policy.
    public func retain(policies: [UUID: IdentityPolicy]) {
        entries = entries.filter { key, entry in
            policies[key.vmId] == entry.policy && entry.policy.audiences.contains(key.audience)
        }
        for (key, pending) in inFlight
        where policies[key.vmId] != pending.policy || !pending.policy.audiences.contains(key.audience) {
            pending.task.cancel()
            inFlight.removeValue(forKey: key)
        }
    }
}
