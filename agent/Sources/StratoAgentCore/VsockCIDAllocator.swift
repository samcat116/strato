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
    /// channel — so the loser is left with no allocation and the caller is
    /// expected to say so loudly.
    case conflict(holder: String)
    /// Refused: the value is not an assignable CID.
    case notAssignable
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
/// matters because a host-side connection outlives the guest it was opened to:
/// reusing a CID promptly would let a stale connect land on a new VM. The
/// cursor is in-memory, so the guarantee is scoped to one agent process — which
/// is exactly the scope of the connections it protects.
public struct VsockCIDAllocator: Sendable {
    /// Why a CID could not be assigned.
    public enum AllocationError: Error, Equatable, CustomStringConvertible {
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
    }

    /// CIDs 0–2 are reserved by the address family (0 hypervisor, 1 local,
    /// 2 host), so 3 is the first a guest may take.
    public static let firstAssignable: UInt32 = 3
    /// `UInt32.max` is `VMADDR_CID_ANY`, the wildcard used for binding, so the
    /// assignable range stops one short of it.
    public static let lastAssignable: UInt32 = UInt32.max - 1

    /// Whether `cid` may be assigned to a guest.
    public static func isAssignable(_ cid: UInt32) -> Bool {
        cid >= firstAssignable && cid <= lastAssignable
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

    /// How many distinct CIDs this allocator can ever have outstanding.
    private var capacity: Int { Int(last - first) + 1 }

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
    @discardableResult
    public mutating func reserve(_ cid: UInt32, for workloadId: String) -> VsockCIDReservation {
        guard isInRange(cid) else { return .notAssignable }
        if let holder = byCID[cid] {
            return holder == workloadId ? .unchanged : .conflict(holder: holder)
        }
        if let previous = byWorkload[workloadId] { byCID.removeValue(forKey: previous) }
        byWorkload[workloadId] = cid
        byCID[cid] = workloadId
        return .reserved
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
        guard byCID.count < capacity else {
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
