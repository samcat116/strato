import Foundation
import StratoShared

/// What a persisted sandbox jail uid reservation did, or why it was refused.
public enum SandboxJailUIDReservation: Sendable, Equatable {
    /// The uid is now recorded as this sandbox's.
    case reserved
    /// This sandbox already held exactly this uid; nothing changed.
    case unchanged
    /// Another sandbox also claims this uid. The allocator keeps the uid
    /// unavailable for every claimant, but exposes it as usable to none of
    /// them until the conflict is resolved.
    case conflict(holder: String)
    /// Refused: uid 0 is root and `UInt32.max` is POSIX `uid_t(-1)`; neither
    /// can identify a jailer process.
    case notAssignable
}

/// A manifest claim the allocator would not honor, for the caller to report.
public struct SandboxJailUIDClaimRefusal: Sendable, Equatable {
    public let sandboxId: String
    public let uid: UInt32
    /// Always ``SandboxJailUIDReservation/conflict(holder:)`` or
    /// ``SandboxJailUIDReservation/notAssignable``.
    public let reason: SandboxJailUIDReservation
}

/// A uid taken for an in-flight sandbox create, and whether rolling that
/// create back should give it up.
///
/// A re-create may lease a uid the sandbox already owns in the manifest. Such
/// a lease must survive a failed re-create; only a uid newly taken by this
/// lease is rolled back.
public struct SandboxJailUIDLease: Sendable, Equatable {
    public let uid: UInt32
    let sandboxId: String
    let isNew: Bool
    /// A conflicting manifest claim displaced by this fresh lease. Rollback
    /// restores it because the durable entry still names it until the caller
    /// successfully commits the replacement uid.
    let previousUID: UInt32?
}

/// Allocates unique host uid/gid identities for sandbox jailer processes.
///
/// The allocation range is configured per host, but persisted assignments are
/// authoritative even when they sit outside the currently configured range.
/// That lets a host change its range without making an existing jail
/// unadoptable. New allocations use only the current range.
///
/// Allocation walks forward from a cursor rather than always choosing the
/// lowest free uid. A released uid is therefore not immediately handed to the
/// next sandbox while teardown may still be removing files it owned.
public struct SandboxJailUIDAllocator: Sendable {
    public enum AllocationError: Error, LocalizedError, Equatable, CustomStringConvertible {
        /// Every uid in the configured allocation range is held.
        case exhausted(inUse: Int)

        public var description: String {
            switch self {
            case .exhausted(let inUse):
                return "the sandbox jail uid range is exhausted (\(inUse) in use)"
            }
        }

        public var errorDescription: String? { description }
    }

    private let first: UInt32
    private let last: UInt32

    /// Every manifest claimant is retained, including duplicate claims. A
    /// duplicate uid stays poisoned if one claimant is deleted while another
    /// may still have a live jail under it.
    private var bySandbox: [String: UInt32] = [:]
    private var byUID: [UInt32: Set<String>] = [:]
    /// Where the next allocation scan starts.
    private var cursor: UInt32

    /// Creates an allocator for `[uidBase, uidBase + uidCount)`.
    ///
    /// Invalid ranges are programmer/configuration errors. Validate external
    /// configuration before constructing the allocator; these preconditions
    /// ensure arithmetic can never silently wrap into system identities.
    public init(
        uidBase: UInt32,
        uidCount: UInt32 = SandboxJailerConfig.uidCount
    ) {
        precondition(uidBase > 0, "sandbox jail uid base must be nonzero")
        precondition(uidCount > 0, "sandbox jail uid count must be nonzero")
        let last = UInt64(uidBase) + UInt64(uidCount) - 1
        precondition(
            last < UInt64(UInt32.max),
            "sandbox jail uid range must not include uid_t(-1)")
        self.init(first: uidBase, last: UInt32(last))
    }

    /// Narrow ranges make exhaustion and wraparound practical to test.
    init(first: UInt32, last: UInt32) {
        precondition(first > 0 && first <= last && last < UInt32.max)
        self.first = first
        self.last = last
        self.cursor = first
    }

    private var capacity: UInt64 { UInt64(last - first) + 1 }

    private func isInAllocationRange(_ uid: UInt32) -> Bool {
        uid >= first && uid <= last
    }

    private var inRangeCount: Int {
        byUID.keys.lazy.filter(isInAllocationRange).count
    }

    /// Number of persisted and newly allocated identities held, including
    /// legacy assignments outside the current allocation range.
    public var count: Int { byUID.count }

    /// The usable uid assigned to `sandboxId`.
    ///
    /// Nil for an unknown sandbox and for every side of a duplicate manifest
    /// claim. A caller must never construct a new jail from a conflicted
    /// lookup; legacy adoption/teardown instead receives the manifest's
    /// recorded uid explicitly without making it allocatable.
    public func uid(for sandboxId: String) -> UInt32? {
        guard let uid = bySandbox[sandboxId], byUID[uid]?.count == 1 else { return nil }
        return uid
    }

    /// A deterministic claimant for diagnostics, or nil when the uid is free.
    public func holder(of uid: UInt32) -> String? { byUID[uid]?.sorted().first }

    /// Whether this sandbox is the only durable claimant of `uid`. Teardown
    /// uses this to decide when an empty host-process inventory is required
    /// before the identity can become allocatable. A legacy duplicate cannot
    /// satisfy that proof while its peer is legitimately still running, but
    /// its UID remains poisoned until the final claimant is removed.
    public func isExclusive(_ uid: UInt32, to sandboxId: String) -> Bool {
        byUID[uid] == Set([sandboxId])
    }

    /// Records a uid this sandbox already has in the durable manifest.
    ///
    /// Every concrete, non-root persisted uid is accepted, even outside the
    /// current allocation range. Zero (root) and `UInt32.max` (`uid_t(-1)`)
    /// are refused. A range change must not rewrite the identity of a surviving
    /// jail. Only an in-range reservation advances the allocation cursor,
    /// because new allocations can never land outside that range.
    @discardableResult
    public mutating func reserve(
        _ uid: UInt32,
        for sandboxId: String
    ) -> SandboxJailUIDReservation {
        guard uid != 0 && uid != UInt32.max else { return .notAssignable }
        if let claimants = byUID[uid], claimants.contains(sandboxId) {
            if let other = claimants.sorted().first(where: { $0 != sandboxId }) {
                return .conflict(holder: other)
            }
            return .unchanged
        }
        let holder = byUID[uid]?.sorted().first
        removeClaim(for: sandboxId)
        bySandbox[sandboxId] = uid
        byUID[uid, default: []].insert(sandboxId)
        if let holder {
            return .conflict(holder: holder)
        }
        if isInAllocationRange(uid), uid >= cursor {
            cursor = next(after: uid)
        }
        return .reserved
    }

    /// Reclaims every recorded sandbox jail uid from both readable and
    /// quarantined manifest entries.
    ///
    /// Quarantined claims are included regardless of their decoded workload
    /// kind: the entry may still describe a running jail, and reserving a
    /// salvaged uid is safer than handing it to a new sandbox. Claims are
    /// processed by id so duplicate winners and refusal order are stable across
    /// restarts.
    public mutating func reserveAll(
        entries: [String: VMManifestEntry],
        quarantined: [String: QuarantinedManifestEntry]
    ) -> [SandboxJailUIDClaimRefusal] {
        let claims =
            entries.compactMap { id, entry in
                guard entry.kind == .sandbox else { return nil }
                return entry.jailUID.map { (id: id, uid: $0) }
            }
            + quarantined.compactMap { id, entry in
                entry.jailUID.map { (id: id, uid: $0) }
            }

        var refusals: [SandboxJailUIDClaimRefusal] = []
        for claim in claims.sorted(by: { $0.id < $1.id }) {
            switch reserve(claim.uid, for: claim.id) {
            case .reserved, .unchanged:
                continue
            case .conflict(let holder):
                refusals.append(
                    SandboxJailUIDClaimRefusal(
                        sandboxId: claim.id,
                        uid: claim.uid,
                        reason: .conflict(holder: holder)))
            case .notAssignable:
                refusals.append(
                    SandboxJailUIDClaimRefusal(
                        sandboxId: claim.id,
                        uid: claim.uid,
                        reason: .notAssignable))
            }
        }
        return refusals
    }

    /// Assigns `sandboxId` a free uid, or returns the identity it already owns.
    ///
    /// Existing persisted identities are returned even when they are outside
    /// the current allocation range. Fresh assignments never are.
    public mutating func allocate(for sandboxId: String) throws -> UInt32 {
        if let existing = uid(for: sandboxId) { return existing }
        let previousUID = bySandbox[sandboxId]
        removeClaim(for: sandboxId)
        do {
            return try allocateFresh(for: sandboxId)
        } catch {
            if let previousUID { restoreClaim(previousUID, for: sandboxId) }
            throw error
        }
    }

    private mutating func allocateFresh(for sandboxId: String) throws -> UInt32 {
        let inUse = inRangeCount
        guard UInt64(inUse) < capacity else {
            throw AllocationError.exhausted(inUse: inUse)
        }

        var candidate = cursor
        while byUID[candidate] != nil {
            candidate = next(after: candidate)
        }

        bySandbox[sandboxId] = candidate
        byUID[candidate] = [sandboxId]
        cursor = next(after: candidate)
        return candidate
    }

    /// Takes an identity for a create that has not completed yet.
    public mutating func lease(for sandboxId: String) throws -> SandboxJailUIDLease {
        if let existing = uid(for: sandboxId) {
            return SandboxJailUIDLease(
                uid: existing, sandboxId: sandboxId, isNew: false, previousUID: nil)
        }
        let previousUID = bySandbox[sandboxId]
        // Keep a legacy duplicate claim in `byUID` until the caller confirms
        // its fresh assignment is durable. Only move the primary lookup now;
        // the old slot remains poisoned across the await back to Agent.
        bySandbox.removeValue(forKey: sandboxId)
        do {
            return SandboxJailUIDLease(
                uid: try allocateFresh(for: sandboxId), sandboxId: sandboxId, isNew: true,
                previousUID: previousUID)
        } catch {
            if let previousUID {
                bySandbox[sandboxId] = previousUID
                byUID[previousUID, default: []].insert(sandboxId)
            }
            throw error
        }
    }

    /// Finishes a lease after its new uid has been written to the manifest.
    public mutating func commit(_ lease: SandboxJailUIDLease) {
        guard lease.isNew, let previousUID = lease.previousUID else { return }
        byUID[previousUID]?.remove(lease.sandboxId)
        if byUID[previousUID]?.isEmpty == true {
            byUID.removeValue(forKey: previousUID)
        }
    }

    /// Releases only an identity newly taken by this lease.
    public mutating func rollBack(_ lease: SandboxJailUIDLease) {
        guard lease.isNew else { return }
        release(lease.sandboxId)
        if let previousUID = lease.previousUID {
            restoreClaim(previousUID, for: lease.sandboxId)
        }
    }

    /// Gives up the identity held by `sandboxId`.
    @discardableResult
    public mutating func release(_ sandboxId: String) -> UInt32? {
        removeClaim(for: sandboxId)
    }

    @discardableResult
    private mutating func removeClaim(for sandboxId: String) -> UInt32? {
        guard let uid = bySandbox.removeValue(forKey: sandboxId) else { return nil }
        byUID[uid]?.remove(sandboxId)
        if byUID[uid]?.isEmpty == true {
            byUID.removeValue(forKey: uid)
        }
        return uid
    }

    private mutating func restoreClaim(_ uid: UInt32, for sandboxId: String) {
        bySandbox[sandboxId] = uid
        byUID[uid, default: []].insert(sandboxId)
    }

    private func next(after uid: UInt32) -> UInt32 {
        uid >= last ? first : uid + 1
    }
}

extension SandboxJailUIDAllocator.AllocationError: ClassifiableError {
    public var failureClassification: FailureClassification { .permanent }
}
