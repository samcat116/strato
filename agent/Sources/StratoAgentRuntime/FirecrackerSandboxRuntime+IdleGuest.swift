import Foundation
import StratoAgentCore
import StratoShared

#if os(Linux)
import SwiftFirecracker
extension FirecrackerSandboxRuntime {
    func exchangeIdleFence(_ context: SandboxSuspensionFenceContext, request: SandboxIdleGuestRequest) async throws
        -> SandboxIdleGuestResponse
    {
        let id = context.sandboxId.uuidString
        guard let managed = sandboxes[id], managed.spec.network == nil,
            managed.guestControlProtocolVersion == SandboxGuestControlProtocol.idlePolicyVersion,
            managed.identityNonce == context.fence.identityNonce
        else { throw SandboxSuspensionGuard.GateError.stale }
        return try await exchangeIdleGuest(
            request, sandboxId: id, nonce: context.fence.identityNonce, udsPath: managed.vsockUdsPath)
    }
    func exchangeIdleGuest(_ request: SandboxIdleGuestRequest, sandboxId: String, nonce: String, udsPath: String)
        async throws -> SandboxIdleGuestResponse
    {
        let connection = try await VsockConnection.connect(
            udsPath: udsPath,
            port: SandboxConfigDrive.defaultVsockPort, timeout: 5, logger: logger)
        do {
            var bytes = try JSONEncoder().encode(request)
            bytes.append(0x0a)
            try await connection.write(bytes)
            guard let line = try await Self.nextControlLine(on: connection, timeout: 5), line.utf8.count <= 1_048_576
            else {
                throw SandboxSuspensionGuard.GateError.stale
            }
            let response = try JSONDecoder().decode(SandboxIdleGuestResponse.self, from: Data(line.utf8))
            guard response.matches(sandboxId: sandboxId, nonce: nonce), response.type != .error else {
                throw SandboxSuspensionGuard.GateError.stale
            }
            await connection.close()
            return response
        } catch {
            await connection.close()
            throw error
        }
    }
}
#endif

#if os(Linux)
extension FirecrackerSandboxRuntime {
    func noteSandboxIdleControlPlane(_ desired: DesiredSandboxState) async {
        let id = desired.sandboxId.uuidString
        if let old = idleControlPlane[id], old.generation > desired.generation { return }
        // CP revisions fence destruction. Echoing a guest-derived CP revision
        // into the guest activity epoch would create a perpetual feedback loop.
        idleControlPlane[id] = desired
    }
    func sampleSandboxIdleActivity(sandboxId id: String) async -> SandboxIdleActivityReport? {
        guard let managed = sandboxes[id], !checkpointing.contains(id), !suspending.contains(id),
            let desired = idleControlPlane[id]
        else { return nil }
        guard idleSampling.insert(id).inserted else { return nil }
        defer { idleSampling.remove(id) }
        let initialSampler = idleSamplers[id] ?? SandboxIdleSampler()
        idleSamplers[id] = initialSampler
        let residencyEpoch = initialSampler.residencyEpoch
        let connectionEpoch = idleConnectionEpoch
        let probe = UUID()
        var guest: SandboxGuestIdleActivity?
        if managed.guestControlProtocolVersion == SandboxGuestControlProtocol.idlePolicyVersion,
            managed.spec.network == nil
        {
            let response = try? await exchangeIdleGuest(
                SandboxIdleGuestRequest(type: .activity, probeId: probe),
                sandboxId: id, nonce: managed.identityNonce, udsPath: managed.vsockUdsPath)
            if response?.type == .activity, response?.activity?.probeId == probe,
                response?.activity?.sandboxId == id, response?.activity?.nonce == managed.identityNonce
            {
                guest = response?.activity
            }
        }
        guard idleConnectionEpoch == connectionEpoch, sandboxes[id]?.identityNonce == managed.identityNonce,
            idleSamplers[id]?.residencyEpoch == residencyEpoch,
            idleControlPlane[id]?.generation == desired.generation,
            !checkpointing.contains(id), !suspending.contains(id)
        else { return nil }
        var sampler = idleSamplers[id] ?? initialSampler
        let sample = sampler.sample(guest)
        idleSamplers[id] = sampler
        let sessions = execSessions.filter { $0.value.sandboxId == id }.keys.compactMap(UUID.init(uuidString:))
        let localPending = suspensionGuards[id]?.pendingActivityCount ?? 0
        let known = sample.known && desired.idleControlPlaneRevision != nil && desired.idlePendingCommandCount != nil
        let now = Date()
        let lastActive = sample.known ? (idleActivityObservations[id]?.lastActiveAt ?? now) : now
        let residentSince = idleResidentSince[id] ?? now
        idleResidentSince[id] = residentSince
        observeIdleActivity(
            sandboxId: id,
            observation: SandboxIdleActivityObservation(
                observedAt: now, lastActiveAt: lastActive,
                residentSince: residentSince,
                activeUserStreams: 0, pendingUserCommands: desired.idlePendingCommandCount,
                guestAndNetworkActivityKnown: known))
        return SandboxIdleActivityReport(
            agentIncarnation: idleActivityIncarnation, connectionEpoch: connectionEpoch,
            residencyEpoch: sampler.residencyEpoch, sequence: sample.sequence, generation: desired.generation,
            activityEpoch: suspensionGuards[id]?.activityEpoch ?? 0, evidenceAgeMilliseconds: 0,
            residentForMilliseconds: sample.residentMilliseconds, guest: guest,
            activeExecSessionIds: sessions,
            pendingCommandCount: desired.idlePendingCommandCount.map { $0 + localPending },
            snapshotOrRestoreInProgress: false,
            idleFenceSupported: managed.guestControlProtocolVersion == SandboxGuestControlProtocol.idlePolicyVersion
                && managed.spec.network == nil && automaticSuspensionTransport != nil,
            hostQuietMilliseconds: known
                ? min(
                    sample.quietMilliseconds,
                    UInt64(min(86_400, max(0, now.timeIntervalSince(idleLastActivity[id] ?? now))) * 1000)) : nil,
            policy: idlePolicy, hostPendingCommandCount: localPending,
            controlPlaneActivityRevision: desired.idleControlPlaneRevision)
    }
}
#endif
