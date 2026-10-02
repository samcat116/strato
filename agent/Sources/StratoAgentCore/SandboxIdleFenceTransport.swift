import Foundation
import StratoShared

/// Wire v5 adapter for STR-312's persisted lifecycle. CP validation is a
/// separate closure and never contacts a paused guest.
public struct SandboxIdleFenceTransport: SandboxAutomaticSuspensionTransport {
    public typealias Exchange =
        @Sendable (SandboxSuspensionFenceContext, SandboxIdleGuestRequest) async throws -> SandboxIdleGuestResponse
    let exchange: Exchange
    let validate: @Sendable (SandboxSuspensionFenceContext) async throws -> Void
    let minimumQuietMilliseconds: UInt64
    public init(
        minimumQuietMilliseconds: UInt64, exchange: @escaping Exchange,
        validate: @escaping @Sendable (SandboxSuspensionFenceContext) async throws -> Void
    ) {
        self.minimumQuietMilliseconds = minimumQuietMilliseconds
        self.exchange = exchange
        self.validate = validate
    }
    public func prepare(_ context: SandboxSuspensionFenceContext) async throws -> UUID {
        let probe = UUID()
        let response = try await exchange(context, SandboxIdleGuestRequest(type: .activity, probeId: probe))
        guard response.matches(sandboxId: context.sandboxId.uuidString, nonce: context.fence.identityNonce),
            response.type == .activity, let activity = response.activity,
            activity.probeId == probe, activity.nonce == context.fence.identityNonce,
            activity.sandboxId == context.sandboxId.uuidString,
            activity.hasCompleteQuiescentCoverage,
            activity.quietForMilliseconds.map({ $0 >= minimumQuietMilliseconds }) == true
        else { throw SandboxSuspensionGuard.GateError.stale }
        let fence = context.fence.request
        let prepared = try await exchange(
            context,
            SandboxIdleGuestRequest(
                type: .prepare,
                operationId: fence.operationId, admissionToken: fence.admissionToken,
                expectedActivityEpoch: activity.activityEpoch, minimumQuietMilliseconds: minimumQuietMilliseconds))
        guard try status(prepared, context: context) == .prepared(fence.admissionToken) else {
            throw SandboxSuspensionGuard.GateError.stale
        }
        return fence.admissionToken
    }
    public func query(_ context: SandboxSuspensionFenceContext) async throws -> SandboxGuestFenceStatus {
        let request = context.fence.request
        return try status(
            await exchange(
                context,
                SandboxIdleGuestRequest(
                    type: .query,
                    operationId: request.operationId, admissionToken: request.admissionToken)), context: context)
    }
    public func validateAdmission(_ context: SandboxSuspensionFenceContext) async throws {
        try await validate(context)
    }
    public func release(_ context: SandboxSuspensionFenceContext) async throws {
        let request = context.fence.request
        let response = try await exchange(
            context,
            SandboxIdleGuestRequest(
                type: .release,
                operationId: request.operationId, admissionToken: request.admissionToken))
        guard try status(response, context: context) == .released else { throw SandboxSuspensionGuard.GateError.stale }
    }
    func status(_ response: SandboxIdleGuestResponse, context: SandboxSuspensionFenceContext) throws
        -> SandboxGuestFenceStatus
    {
        let request = context.fence.request
        guard response.matches(sandboxId: context.sandboxId.uuidString, nonce: context.fence.identityNonce),
            response.type == .fence, response.operationId == request.operationId,
            response.admissionToken == request.admissionToken, let state = response.state
        else { throw SandboxSuspensionGuard.GateError.stale }
        switch state {
        case .absent: return .absent
        case .prepared: return .prepared(request.admissionToken)
        case .released: return .released
        }
    }
}
