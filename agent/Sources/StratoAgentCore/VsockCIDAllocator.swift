import Foundation
import StratoShared

/// What a reservation did, or why it was refused.
public enum VsockCIDReservation: Sendable, Equatable {
    /// The CID is now recorded as this workload's.
    case reserved
    /// This workload already held exactly this CID; nothing changed.
    case unchanged
    /// Refused: another workload already holds this CID. Two workloads on one
    /// CID is not a bookkeeping nuisance — it is two guests sharing a control
    /// channel — so the claim is dropped rather than taken over, and the caller
    /// is expected to say so loudly.
    ///
    /// The refused workload is left exactly as it was: with no allocation if it
    /// had none, and still holding its own earlier CID if it had one. Nothing
    /// is taken away by a refusal.
    case conflict(holder: String)
    /// Refused: the value is not an assignable CID. Same post-state as
    /// ``conflict(holder:)`` — the workload keeps whatever it already had.
    case notAssignable
}

/// A manifest claim this allocator would not honor, for the caller to report.
public struct VsockCIDClaimRefusal: Sendable, Equatable {
    public let workloadId: String
    public let cid: UInt32
    /// Why it was refused — always ``VsockCIDReservation/conflict(holder:)`` or
    /// ``VsockCIDReservation/notAssignable``.
    public let reason: VsockCIDReservation
}

/// A CID taken for an in-flight create, and whether rolling the create back
/// should give it up.
///
/// The distinction is the whole reason this type exists rather than a bare
/// `UInt32?`: a create that *re-runs* for a VM that already holds a CID (an
/// orphan whose hypervisor process is gone is rebuilt through the create path)
/// must not release that CID when it fails, because the manifest still records
/// it and a later create would then hand a live VM's CID to another one.
/// Keeping the rule inside ``VsockCIDAllocator/rollBack(_:)`` means no caller
/// can get the polarity wrong.
public struct VsockCIDLease: Sendable, Equatable {
    /// The CID to build the VM with, or nil when this backend takes none from
    /// the host namespace.
    public let cid: UInt32?
    let workloadId: String
    /// Whether this lease is what put the CID in the allocator.
    let isNew: Bool
}

/// Assigns each workload a context ID in the host kernel's AF_VSOCK namespace.
///
/// ## Why this is host-global
///
/// A vsock context ID is not a property of a VM the way a MAC address is. When
/// QEMU is given a `vhost-vsock-pci` device, the CID is programmed into the
/// host kernel's `vhost_vsock` driver, which keeps one flat 32-bit namespace
/// for the whole machine and refuses a CID another guest already holds. So a
/// CID cannot be derived from a VM id — two VMs whose ids happened to derive
/// the same number would be one failed VM start on a good day, and on a bad one
/// (a CID handed out again after the first holder went away) a host process
/// reaching the wrong guest's control agent. It has to be allocated, and the
/// allocation has to be remembered across an agent restart, which is why every
/// assignment is written into the VM manifest (`VMManifestEntry.vsockCID`) and
/// read back into this allocator on the next start.
///
/// ## Which workloads draw from it
///
/// Only backends that put a device in *this* namespace: QEMU, via vhost-vsock.
/// Firecracker does not. Its virtio-vsock device is emulated inside the
/// Firecracker process and its host side is a Unix-domain socket
/// (`VsockConfig.udsPath`), so a Firecracker guest's CID is private to that one
/// microVM and never reaches the host kernel — which is why every Firecracker
/// sandbox can and does use CID 3 without colliding with anything, and why
/// routing those through this allocator would be a category error rather than a
/// unification: it would consume host CIDs for devices that occupy none.
/// `HypervisorType.usesHostVsockNamespace` is the single place that decides.
///
/// ## Reuse
///
/// Allocation walks forward from a cursor rather than always taking the lowest
/// free CID, so a freed CID is not immediately handed to the next VM. That
/// matters because a host-side connection outlives the guest it was opened to,
/// and those connections belong to *other* host processes talking to guest
/// agents — they survive an agent restart, so the property has to as well. It
/// does: `reserveAll` walks the cursor past every CID the manifest records, so
/// a restarted agent resumes above its last assignment instead of handing the
/// next VM the lowest free CID.
///
/// ## What it is not authoritative over
///
/// Only the VMs this agent created. A CID held by a process outside Strato, or
/// by a VM started outside the agent, is invisible here and can be handed out.
/// That fails safe rather than silently: the host kernel refuses a duplicate
/// CID (`EADDRINUSE`), so the VM fails to start instead of two guests sharing a
/// channel. The consumer (STR-76) should surface that as "CID already in use on
/// this host" rather than an opaque hypervisor error.
public struct VsockCIDAllocator: Sendable {
    /// Why a CID could not be assigned.
    ///
    /// `LocalizedError` because the reconciler records failures as
    /// `error.localizedDescription`; without it an operator would see
    /// Foundation's placeholder text for the one failure this type reports.
    public enum AllocationError: Error, LocalizedError, Equatable, CustomStringConvertible {
        /// Every assignable CID on this host is held. Explicit rather than
        /// wrapping: handing out a CID that is already in use would put two
        /// guests on one control channel.
        case exhausted(inUse: Int)

        public var description: String {
            switch self {
            case .exhausted(let inUse):
                return "the host's vsock context ID namespace is exhausted (\(inUse) in use)"
            }
        }

        public var errorDescription: String? { description }
    }

    /// CIDs 0–2 are reserved by the address family (0 hypervisor, 1 local,
    /// 2 host), so 3 is the first a guest may take.
    public static let firstAssignable = VsockCID.firstAssignable
    /// `UInt32.max` is `VMADDR_CID_ANY`, the wildcard used for binding, so the
    /// assignable range stops one short of it.
    public static let lastAssignable = VsockCID.lastAssignable

    /// Whether `cid` may be assigned to a guest.
    public static func isAssignable(_ cid: UInt32) -> Bool {
        VsockCID.isAssignable(cid)
    }

    /// The range this allocator hands out from. Always the host's full
    /// assignable range in production; narrowed only by tests, which cannot
    /// otherwise reach the exhaustion boundary of a 32-bit space.
    private let first: UInt32
    private let last: UInt32

    private var byWorkload: [String: UInt32] = [:]
    private var byCID: [UInt32: String] = [:]
    /// Where the next scan starts. See the type's "Reuse" note.
    private var cursor: UInt32

    public init() {
        self.init(first: Self.firstAssignable, last: Self.lastAssignable)
    }

    init(first: UInt32, last: UInt32) {
        precondition(first >= Self.firstAssignable && last <= Self.lastAssignable && first <= last)
        self.first = first
        self.last = last
        self.cursor = first
    }

    /// How many distinct CIDs this allocator can ever have outstanding. Held as
    /// `UInt64` because the real range does not fit a 32-bit `Int`.
    private var capacity: UInt64 { UInt64(last - first) + 1 }

    /// Whether `cid` is inside this allocator's range.
    private func isInRange(_ cid: UInt32) -> Bool { cid >= first && cid <= last }

    /// How many CIDs are currently held.
    public var count: Int { byCID.count }

    /// The CID assigned to `workloadId`, or nil if it has none.
    public func cid(for workloadId: String) -> UInt32? { byWorkload[workloadId] }

    /// The workload holding `cid`, or nil if it is free.
    public func holder(of cid: UInt32) -> String? { byCID[cid] }

    /// Record a CID this workload already has — the manifest read on agent
    /// start, where the CID is a fact about a VM that may still be running
    /// rather than a request for a new one.
    ///
    /// A workload that somehow arrives holding a *different* CID than the one
    /// recorded here takes the new one: the caller is replaying the durable
    /// record, which outranks anything this process inferred.
    ///
    /// A successful reservation also walks the cursor past the CID, so a
    /// restarted agent allocates *above* what it has recorded rather than
    /// restarting at the bottom of the range. See the type's "Reuse" note.
    @discardableResult
    public mutating func reserve(_ cid: UInt32, for workloadId: String) -> VsockCIDReservation {
        guard isInRange(cid) else { return .notAssignable }
        if let holder = byCID[cid] {
            return holder == workloadId ? .unchanged : .conflict(holder: holder)
        }
        if let previous = byWorkload[workloadId] { byCID.removeValue(forKey: previous) }
        byWorkload[workloadId] = cid
        byCID[cid] = workloadId
        // Only ever forward, so reserving in any order lands the cursor past
        // the highest CID claimed rather than past the last one seen.
        if cid >= cursor { cursor = next(after: cid) }
        return .reserved
    }

    /// Re-claim every CID a manifest read records, and report what could not be
    /// honored.
    ///
    /// Both halves of the read are claimed. A quarantined entry is one this
    /// build cannot route, but something is running under it — that is the
    /// whole reason the entry is kept — and its CID is one of the host
    /// resources it is still consuming, exactly like the CPU and memory the
    /// entry keeps reserved.
    ///
    /// Claims are applied in workload-id order so which side of a duplicate
    /// wins is stable across restarts rather than a dictionary-ordering coin
    /// flip, and the refusals come back in that same order.
    public mutating func reserveAll(
        entries: [String: VMManifestEntry], quarantined: [String: QuarantinedManifestEntry]
    ) -> [VsockCIDClaimRefusal] {
        let claims =
            entries.compactMap { id, entry in
                guard entry.spec.guestAgentEnabled else { return nil }
                return entry.vsockCID.map { (id: id, cid: $0) }
            }
            + quarantined.compactMap { id, entry in entry.vsockCID.map { (id: id, cid: $0) } }

        var refusals: [VsockCIDClaimRefusal] = []
        for claim in claims.sorted(by: { $0.id < $1.id }) {
            switch reserve(claim.cid, for: claim.id) {
            case .reserved, .unchanged:
                continue
            case .conflict(let holder):
                refusals.append(
                    VsockCIDClaimRefusal(
                        workloadId: claim.id, cid: claim.cid, reason: .conflict(holder: holder)))
            case .notAssignable:
                refusals.append(
                    VsockCIDClaimRefusal(workloadId: claim.id, cid: claim.cid, reason: .notAssignable))
            }
        }
        return refusals
    }

    /// Assign `workloadId` a free CID, or return the one it already holds.
    ///
    /// Idempotent by workload id, which is what makes it safe on the paths that
    /// re-run a create: an orphan whose hypervisor process is gone is rebuilt
    /// through the same code as a first create, and must come back on the CID
    /// the manifest says it has rather than a second one.
    ///
    /// - Throws: ``AllocationError/exhausted(inUse:)`` when no CID is free.
    public mutating func allocate(for workloadId: String) throws -> UInt32 {
        if let existing = byWorkload[workloadId] { return existing }
        guard UInt64(byCID.count) < capacity else {
            throw AllocationError.exhausted(inUse: byCID.count)
        }

        // At most `count` of any `count + 1` distinct candidates can be taken,
        // and the guard above proves the range holds that many, so this
        // terminates without ever needing to scan the whole 32-bit space.
        var candidate = cursor
        while byCID[candidate] != nil { candidate = next(after: candidate) }

        byWorkload[workloadId] = candidate
        byCID[candidate] = workloadId
        cursor = next(after: candidate)
        return candidate
    }

    /// Take a CID for a create that has not happened yet.
    ///
    /// - Parameter needsHostCID: false for a backend that occupies none of this
    ///   namespace, which leases a nil CID rather than spending one.
    /// - Throws: ``AllocationError/exhausted(inUse:)`` when no CID is free.
    public mutating func lease(for workloadId: String, needsHostCID: Bool) throws -> VsockCIDLease {
        guard needsHostCID else {
            return VsockCIDLease(cid: nil, workloadId: workloadId, isNew: false)
        }
        if let existing = byWorkload[workloadId] {
            return VsockCIDLease(cid: existing, workloadId: workloadId, isNew: false)
        }
        return VsockCIDLease(cid: try allocate(for: workloadId), workloadId: workloadId, isNew: true)
    }

    /// Undo a lease whose create failed. Releases only what the lease itself
    /// took: a CID the VM already held stays held, because the manifest still
    /// records it.
    public mutating func rollBack(_ lease: VsockCIDLease) {
        guard lease.isNew else { return }
        release(lease.workloadId)
    }

    /// Give up `workloadId`'s CID. A no-op for a workload that holds none, so
    /// it can be called from every teardown path — including the ones that
    /// discover the workload was already gone.
    ///
    /// - Returns: the released CID, for the caller's log.
    @discardableResult
    public mutating func release(_ workloadId: String) -> UInt32? {
        guard let cid = byWorkload.removeValue(forKey: workloadId) else { return nil }
        byCID.removeValue(forKey: cid)
        return cid
    }

    /// Wrapping successor within the assignable range.
    private func next(after cid: UInt32) -> UInt32 {
        cid >= last ? first : cid + 1
    }
}

extension VsockCIDAllocator.AllocationError: ClassifiableError {
    /// The namespace frees up when another VM is deleted. That can happen
    /// without changing this VM's generation, so every sync must re-drive it.
    public var failureClassification: FailureClassification { .blocked }
}

extension HypervisorType {
    /// Whether a VM on this backend takes a CID from the host kernel's vsock
    /// namespace, and therefore needs one allocated.
    ///
    /// QEMU does, through `vhost-vsock-pci`. Firecracker emulates virtio-vsock
    /// in-process over a Unix-domain socket, so its guest CID is private to the
    /// microVM; see ``VsockCIDAllocator``.
    public var usesHostVsockNamespace: Bool {
        switch self {
        case .qemu: return true
        case .firecracker: return false
        }
    }
}
