import Foundation
import StratoShared

#if os(Linux)
import Glibc
#else
import Darwin
#endif

/// Agent-local STR-312 admission contract. Policy and guest-operation admission
/// use the same guard; no caller may independently decide to destroy a VMM.
public struct SandboxSuspensionGuard: Sendable {
    public struct Ticket: Sendable, Equatable {
        public let generation: Int64
        public let activityEpoch: UInt64
        fileprivate let nonce: UUID
    }

    public enum GateError: ClassifiableError, LocalizedError, Sendable, Equatable {
        case unknownIntent
        case active
        case stale
        case busy

        public var failureClassification: FailureClassification {
            switch self {
            case .busy, .unknownIntent: .waitingOnDependency
            case .active, .stale: .blocked
            }
        }

        public var errorDescription: String? {
            switch self {
            case .unknownIntent: "Waiting for current sandbox intent"
            case .busy: "Waiting for the owned suspension/restore permit"
            case .active: "Sandbox has active user execution; close the session before suspending"
            case .stale: "Sandbox intent, activity or durable recovery evidence changed; refresh before retrying"
            }
        }
    }

    private var generation: Int64?
    private var desiredRunning = true
    private var epoch: UInt64 = 0
    private var activity: Set<UUID> = []
    private var ticket: Ticket?
    private var destructionCommitted = false

    public init() {}

    /// Runtime-local idle evidence includes handshakes reserved before their first await.
    public var activityEpoch: UInt64 { epoch }
    public var pendingActivityCount: Int { activity.count }

    /// Older syncs never undo newer intent. Equal-generation replays are inert.
    public mutating func updateIntent(generation: Int64, desiredRunning: Bool) {
        guard generation >= 0, self.generation.map({ generation > $0 }) ?? true else { return }
        self.generation = generation
        self.desiredRunning = desiredRunning
    }

    /// Register before an exec handshake or command can suspend its caller.
    /// Returns a token that must be retired even when admission fails/cancels.
    public mutating func beginActivity() -> UUID {
        let token = UUID()
        activity.insert(token)
        epoch &+= 1
        return token
    }

    public mutating func endActivity(_ token: UUID) { activity.remove(token) }

    public mutating func beginSuspension(generation: Int64, automatic: Bool) throws -> Ticket {
        guard let current = self.generation else { throw GateError.unknownIntent }
        guard ticket == nil else { throw GateError.busy }
        guard current == generation, automatic || !desiredRunning else { throw GateError.stale }
        guard activity.isEmpty else { throw GateError.active }
        let next = Ticket(generation: generation, activityEpoch: epoch, nonce: UUID())
        ticket = next
        destructionCommitted = false
        return next
    }

    /// Synchronous commit point: an activity or generation change before this
    /// point preserves the original guest; changes afterwards require restore.
    public mutating func commitDestruction(_ candidate: Ticket) throws {
        guard ticket == candidate, candidate.generation == generation,
            candidate.activityEpoch == epoch, activity.isEmpty, !destructionCommitted
        else { throw GateError.stale }
        destructionCommitted = true
    }

    public func needsRestore(after candidate: Ticket) -> Bool {
        destructionCommitted
            && (epoch != candidate.activityEpoch || (generation != candidate.generation && desiredRunning))
    }

    /// Bind a paused replacement to the requested intent before any load awaits.
    /// Activity after a committed destruction may require immediate recovery
    /// while the same suspension ticket still owns the guest.
    public func resumeGeneration(expected: Int64? = nil, allowRacedActivity: Bool = false) throws -> Int64 {
        guard let generation else { throw GateError.unknownIntent }
        guard expected == nil || expected == generation else { throw GateError.stale }
        let raced =
            allowRacedActivity && destructionCommitted
            && ticket?.generation == generation && ticket?.activityEpoch != epoch
        guard desiredRunning || raced else { throw GateError.stale }
        return generation
    }

    /// No await between this check, the durable resuming commit and resume RPC.
    public func validateResumeGeneration(_ expected: Int64) throws {
        guard generation == expected else { throw GateError.stale }
    }

    public mutating func finish(_ candidate: Ticket) {
        guard ticket == candidate else { return }
        ticket = nil
        destructionCommitted = false
    }
}

/// Journal phases precede their side effects. A missing VMM with any verified
/// checkpoint phase must recover from that checkpoint, never from the OCI image.
public struct SandboxSuspensionRecord: Codable, Sendable {
    public enum Phase: String, Codable, Sendable, CaseIterable {
        case capturing, verified, destroying, suspended, restoring, resuming, resumed
    }
    public let version: Int
    public let sandboxId: UUID
    public let snapshotId: UUID
    public let generation: Int64
    public let activityEpoch: UInt64
    public var phase: Phase
    public var checkpoint: SandboxCheckpointManifest?
    /// The last verified internally-owned checkpoint remains pinned during a
    /// new capture. User-created snapshots are never eligible for this field.
    public var previousSnapshotId: UUID?
    public let jailUID: UInt32
    public let spec: SandboxSpec
    public var lastRestoreMillis: Int64?
    public var lastRestoreFailure: String?
    public var storageReservationBytes: Int64?
    public var guestFence: SandboxSuspensionGuestFence?

    public init(
        sandboxId: UUID, snapshotId: UUID, generation: Int64, activityEpoch: UInt64,
        jailUID: UInt32, spec: SandboxSpec, previousSnapshotId: UUID? = nil
    ) {
        self.version = 1
        self.sandboxId = sandboxId
        self.snapshotId = snapshotId
        self.generation = generation
        self.activityEpoch = activityEpoch
        self.phase = .capturing
        self.checkpoint = nil
        self.previousSnapshotId = previousSnapshotId
        self.jailUID = jailUID
        self.spec = spec
    }

    public var reservesGuestMemory: Bool { phase != .suspended }
    public var mayReplayCheckpointWithoutGuest: Bool {
        checkpoint != nil && [.verified, .destroying, .suspended, .restoring].contains(phase)
    }
    public var checkpointBytes: Int64 {
        checkpoint?.artifacts.reduce(0) { partial, artifact in
            let (sum, overflow) = partial.addingReportingOverflow(artifact.sizeBytes)
            return overflow || artifact.sizeBytes < 0 ? Int64.max : sum
        } ?? 0
    }
}

/// One record per workload, written by its serialized runtime lane. Failure
/// propagates; callers cannot destroy or release capacity after a failed save.
public struct SandboxSuspensionStore: Sendable {
    private let directory: String
    public init(directory: String) { self.directory = directory }

    public func load(sandboxId: UUID) throws -> SandboxSuspensionRecord? {
        let path = recordPath(sandboxId)
        let fd = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        if fd < 0, errno == ENOENT { return nil }
        guard fd >= 0 else { throw SandboxCheckpointManifest.CheckpointError.ioFailure(errno) }
        defer { _ = close(fd) }
        var metadata = stat()
        guard fstat(fd, &metadata) == 0 else { throw SandboxCheckpointManifest.CheckpointError.ioFailure(errno) }
        guard metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), metadata.st_nlink == 1,
            metadata.st_size > 0, metadata.st_size <= Self.maximumRecordBytes
        else { throw SandboxSuspensionGuard.GateError.stale }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 8192)
        while true {
            let count = read(fd, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { throw SandboxCheckpointManifest.CheckpointError.ioFailure(errno) }
            if count == 0 { break }
            guard count <= Self.maximumRecordBytes - data.count else { throw SandboxSuspensionGuard.GateError.stale }
            data.append(contentsOf: buffer.prefix(count))
        }
        let record = try JSONDecoder().decode(SandboxSuspensionRecord.self, from: data)
        guard record.version == 1, record.sandboxId == sandboxId, record.generation >= 0,
            record.jailUID != 0, record.jailUID != UInt32.max,
            record.guestFence.map({ $0.hasValidShape(for: record) }) ?? true,
            record.phase == .capturing || record.checkpoint != nil,
            record.checkpoint.map({
                $0.hasValidShape && $0.sandboxId == sandboxId.uuidString
                    && $0.snapshotId == record.snapshotId.uuidString
            }) ?? true
        else { throw SandboxSuspensionGuard.GateError.stale }
        return record
    }

    public func save(_ record: SandboxSuspensionRecord) throws {
        let data = try JSONEncoder().encode(record)
        guard data.count <= Self.maximumRecordBytes else { throw SandboxSuspensionGuard.GateError.stale }
        try DurableFileWriter().write(
            data, to: recordPath(record.sandboxId), permissions: 0o600)
    }

    public func remove(sandboxId: UUID) throws {
        let path = recordPath(sandboxId)
        if FileManager.default.fileExists(atPath: path) {
            try FileManager.default.removeItem(atPath: path)
            try DurableFileWriter().synchronizeRemoval(at: path)
        }
    }

    private func recordPath(_ id: UUID) -> String { directory + "/" + id.uuidString + ".json" }
    private static let maximumRecordBytes = 4_194_304
}

/// Agent-wide restore admission. Refusing an excess caller lets the existing
/// reconciler backoff provide a bounded queue. A permit remains owned until
/// restore AND process cleanup finish, even on timeout or cancellation.
public struct SandboxRestoreAdmission: Sendable {
    private let limit: Int
    private var leases: Set<UUID> = []
    public init() { self.limit = 2 }
    public init(limit: Int) throws {
        guard (1...32).contains(limit) else { throw SandboxSuspensionGuard.GateError.active }
        self.limit = limit
    }
    public mutating func acquire() throws -> UUID {
        guard leases.count < limit else { throw SandboxSuspensionGuard.GateError.busy }
        let token = UUID()
        leases.insert(token)
        return token
    }
    /// Recovered durable owners remain admitted even if the configured limit shrank.
    public mutating func recover(_ tokens: Set<UUID>) { leases.formUnion(tokens) }
    public mutating func release(_ token: UUID) { leases.remove(token) }
    public var activeCount: Int { leases.count }
}
