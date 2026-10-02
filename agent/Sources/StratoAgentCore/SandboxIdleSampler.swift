import Foundation
import StratoShared

/// A monotonic host window. A guest's reported quiet duration cannot backdate
/// the first observation; replay and source changes start unknown.
public struct SandboxIdleSampler: Sendable {
    public let residencyEpoch = UUID()
    private let residentSince: ContinuousClock.Instant
    private var quietSince: ContinuousClock.Instant
    private var previous: SandboxGuestIdleActivity?
    private var sequence: UInt64 = 0
    private var highestGuestSequence: UInt64 = 0
    private struct GuestIdentity: Equatable, Sendable {
        let monitor: UUID
        let sandbox: String
        let nonce: String
    }
    private var highestGuestIdentity: GuestIdentity?
    public init(at now: ContinuousClock.Instant = .now) { residentSince = now; quietSince = now }
    public mutating func noteActivity(at now: ContinuousClock.Instant = .now) { quietSince = now }

    public mutating func sample(_ guest: SandboxGuestIdleActivity?, at now: ContinuousClock.Instant = .now) -> (
        quietMilliseconds: UInt64, residentMilliseconds: UInt64, sequence: UInt64, known: Bool
    ) {
        sequence = sequence == UInt64(Int64.max) ? sequence : sequence + 1
        let identity = guest.map {
            GuestIdentity(monitor: $0.monitorIncarnation, sandbox: $0.sandboxId, nonce: $0.nonce)
        }
        let replay =
            guest.map { identity == highestGuestIdentity && $0.sampleSequence <= highestGuestSequence } ?? false
        if let guest, guest.isBounded, !replay {
            if identity != highestGuestIdentity { highestGuestSequence = 0 }
            highestGuestIdentity = identity
            highestGuestSequence = max(highestGuestSequence, guest.sampleSequence)
        }
        let ordered =
            !replay
            && guest.flatMap { current in
                previous.map { old in
                    current.monitorIncarnation == old.monitorIncarnation && current.sampleSequence > old.sampleSequence
                        && current.activityEpoch >= old.activityEpoch && current.nonce == old.nonce
                        && current.sandboxId == old.sandboxId
                        && current.workloadCpuMicroseconds == old.workloadCpuMicroseconds
                        && current.workloadReadBytes == old.workloadReadBytes
                        && current.workloadWriteBytes == old.workloadWriteBytes
                        && current.activityEpoch == old.activityEpoch
                }
            } == true
        let known = ordered && guest?.hasCompleteQuiescentCoverage == true && sequence < UInt64(Int64.max)
        if !known { quietSince = now }
        previous = replay ? nil : guest
        func milliseconds(_ start: ContinuousClock.Instant) -> UInt64 {
            let d = start.duration(to: now).components
            guard d.seconds >= 0, d.seconds <= 86_400 else { return d.seconds < 0 ? 0 : 86_400_000 }
            return UInt64(d.seconds) * 1000 + UInt64(max(0, d.attoseconds) / 1_000_000_000_000_000)
        }
        return (
            min(milliseconds(quietSince), guest?.quietForMilliseconds ?? 0), milliseconds(residentSince), sequence,
            known
        )
    }
}
