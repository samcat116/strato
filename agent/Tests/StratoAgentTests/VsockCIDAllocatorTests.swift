import StratoShared
import Testing

@testable import StratoAgentCore

@Suite("VsockCIDAllocator Tests")
struct VsockCIDAllocatorTests {

    @Test("Allocates distinct CIDs starting above the reserved range")
    func allocatesDistinctAssignableCIDs() throws {
        var allocator = VsockCIDAllocator()

        let a = try allocator.allocate(for: "vm-a")
        let b = try allocator.allocate(for: "vm-b")

        #expect(a == VsockCIDAllocator.firstAssignable)
        #expect(a != b)
        #expect(VsockCIDAllocator.isAssignable(a))
        #expect(VsockCIDAllocator.isAssignable(b))
        #expect(allocator.count == 2)
    }

    @Test("CIDs 0-2 and the wildcard are never assignable")
    func reservedCIDsAreNotAssignable() {
        #expect(!VsockCIDAllocator.isAssignable(0))
        #expect(!VsockCIDAllocator.isAssignable(1))
        #expect(!VsockCIDAllocator.isAssignable(2))
        #expect(VsockCIDAllocator.isAssignable(3))
        #expect(!VsockCIDAllocator.isAssignable(UInt32.max))
        #expect(VsockCIDAllocator.isAssignable(UInt32.max - 1))
    }

    /// The re-create path (an orphan whose hypervisor process is gone runs
    /// through the same create code) must not hand the VM a second CID.
    @Test("Allocating twice for one workload returns the same CID")
    func allocationIsIdempotentPerWorkload() throws {
        var allocator = VsockCIDAllocator()

        let first = try allocator.allocate(for: "vm-a")
        let second = try allocator.allocate(for: "vm-a")

        #expect(first == second)
        #expect(allocator.count == 1)
    }

    @Test("Released CIDs are not immediately reused")
    func releasedCIDsAreNotImmediatelyReused() throws {
        var allocator = VsockCIDAllocator()

        let a = try allocator.allocate(for: "vm-a")
        #expect(allocator.release("vm-a") == a)
        #expect(allocator.cid(for: "vm-a") == nil)
        #expect(allocator.count == 0)

        let b = try allocator.allocate(for: "vm-b")
        #expect(b != a)
    }

    @Test("Releasing a workload that holds nothing is a no-op")
    func releasingUnknownWorkloadIsHarmless() {
        var allocator = VsockCIDAllocator()
        #expect(allocator.release("never-allocated") == nil)
        #expect(allocator.count == 0)
    }

    /// What the manifest read does on every agent start: the CIDs are facts
    /// about VMs that may still be running, not requests.
    @Test("Reserved CIDs survive into later allocations")
    func reservationsBlockLaterAllocations() throws {
        var allocator = VsockCIDAllocator()

        #expect(allocator.reserve(3, for: "vm-a") == .reserved)
        #expect(allocator.reserve(4, for: "vm-b") == .reserved)
        #expect(allocator.cid(for: "vm-a") == 3)
        #expect(allocator.holder(of: 4) == "vm-b")

        let fresh = try allocator.allocate(for: "vm-c")
        #expect(fresh != 3 && fresh != 4)
    }

    @Test("Re-reserving the same CID for the same workload changes nothing")
    func reReservationIsIdempotent() {
        var allocator = VsockCIDAllocator()

        #expect(allocator.reserve(7, for: "vm-a") == .reserved)
        #expect(allocator.reserve(7, for: "vm-a") == .unchanged)
        #expect(allocator.count == 1)
    }

    /// Two workloads on one CID is two guests on one control channel, so the
    /// second is refused outright rather than quietly taking it over.
    @Test("A CID another workload holds is refused")
    func conflictingReservationIsRefused() {
        var allocator = VsockCIDAllocator()

        #expect(allocator.reserve(9, for: "vm-a") == .reserved)
        #expect(allocator.reserve(9, for: "vm-b") == .conflict(holder: "vm-a"))
        #expect(allocator.cid(for: "vm-b") == nil)
        #expect(allocator.holder(of: 9) == "vm-a")
    }

    @Test("A reserved CID outside the assignable range is refused")
    func unassignableReservationIsRefused() {
        var allocator = VsockCIDAllocator()

        #expect(allocator.reserve(2, for: "vm-a") == .notAssignable)
        #expect(allocator.reserve(UInt32.max, for: "vm-a") == .notAssignable)
        #expect(allocator.cid(for: "vm-a") == nil)
        #expect(allocator.count == 0)
    }

    /// A workload arriving with a different CID than the one recorded is the
    /// durable record correcting this process; it takes the new one and gives
    /// the old one back rather than holding both.
    @Test("Re-reserving a workload onto a new CID releases its old one")
    func reReservationMovesTheWorkload() {
        var allocator = VsockCIDAllocator()

        #expect(allocator.reserve(5, for: "vm-a") == .reserved)
        #expect(allocator.reserve(6, for: "vm-a") == .reserved)

        #expect(allocator.cid(for: "vm-a") == 6)
        #expect(allocator.holder(of: 5) == nil)
        #expect(allocator.count == 1)
    }

    /// The restart half of the anti-reuse property: the stale host-side
    /// connections it guards against belong to other processes and outlive the
    /// agent, so a reload must not put the cursor back at the bottom of the
    /// range. Reserving walks it past everything the manifest recorded.
    @Test("Reserving walks the cursor past the recorded CIDs")
    func reservingAdvancesTheCursor() throws {
        var allocator = VsockCIDAllocator()
        let first = VsockCIDAllocator.firstAssignable
        // Deliberately not in ascending order: the cursor must end up past the
        // highest CID claimed, not past the last one seen.
        for cid in [first + 4, first, first + 9, first + 2] {
            #expect(allocator.reserve(cid, for: "held-\(cid)") == .reserved)
        }

        #expect(try allocator.allocate(for: "vm-new") == first + 10)
        #expect(allocator.count == 5)
    }

    /// Exhaustion is the point of the explicit range: the allocator refuses
    /// rather than wrapping onto a CID somebody else holds, because a second
    /// guest on one CID is an isolation failure. A real host cannot reach 2^32
    /// VMs, so the boundary is exercised on a narrowed range.
    @Test("A full range throws instead of reusing a held CID")
    func exhaustionThrows() throws {
        var allocator = VsockCIDAllocator(first: 3, last: 5)

        #expect(try allocator.allocate(for: "vm-a") == 3)
        #expect(try allocator.allocate(for: "vm-b") == 4)
        #expect(try allocator.allocate(for: "vm-c") == 5)

        #expect(throws: VsockCIDAllocator.AllocationError.exhausted(inUse: 3)) {
            _ = try allocator.allocate(for: "vm-d")
        }
        // The workloads that do hold CIDs keep them, and a failed allocation
        // records nothing.
        #expect(allocator.count == 3)
        #expect(allocator.cid(for: "vm-d") == nil)

        // Freeing one lets exactly one more through.
        #expect(allocator.release("vm-b") == 4)
        #expect(try allocator.allocate(for: "vm-d") == 4)
        #expect(throws: VsockCIDAllocator.AllocationError.self) {
            _ = try allocator.allocate(for: "vm-e")
        }
    }

    /// The scan itself has to wrap: the cursor must sit *on a held CID* with
    /// the only hole below it, or the `while` body never runs and the test
    /// proves nothing.
    @Test("The scan wraps off the end of the range onto a free CID")
    func scanWrapsWithinRange() throws {
        var allocator = VsockCIDAllocator(first: 3, last: 5)

        // Reserving 5 wraps the cursor back to 3; reserving 4 then walks it to
        // 5, which is held — leaving 3, the one free CID, *below* the cursor.
        #expect(allocator.reserve(5, for: "vm-c") == .reserved)
        #expect(allocator.reserve(4, for: "vm-b") == .reserved)

        #expect(try allocator.allocate(for: "vm-d") == 3)
        #expect(allocator.count == 3)
    }

    @Test("Exhaustion is reported with the number of CIDs in use")
    func exhaustionErrorDescribesItself() {
        let error = VsockCIDAllocator.AllocationError.exhausted(inUse: 12)
        #expect(error.description.contains("12"))
        #expect(error == .exhausted(inUse: 12))
    }

    /// The reconciler records `error.localizedDescription`, which for a bare
    /// Swift error is Foundation's placeholder rather than the message above —
    /// so the operator would see nothing useful for the one failure this type
    /// exists to report.
    @Test("Exhaustion's message survives localizedDescription")
    func exhaustionErrorIsLocalized() {
        let error: any Error = VsockCIDAllocator.AllocationError.exhausted(inUse: 12)
        #expect(error.localizedDescription.contains("exhausted"))
        #expect(!error.localizedDescription.contains("The operation couldn't be completed"))
    }

    /// Exhaustion only clears when another VM is deleted, which cannot happen
    /// inside one item's retry budget — so retrying is pure waste.
    @Test("Exhaustion is a permanent failure, not a transient one")
    func exhaustionIsPermanent() {
        let error = VsockCIDAllocator.AllocationError.exhausted(inUse: 3)
        #expect((error as any ClassifiableError).failureClassification == .permanent)
        #expect((error as? any ClassifiableError)?.failureClassification == .permanent)
    }

    // MARK: - Leases (the create path's rollback rule)

    @Test("A lease for a backend that needs no host CID spends nothing")
    func leaseWithoutHostCIDSpendsNothing() throws {
        var allocator = VsockCIDAllocator()

        let lease = try allocator.lease(for: "fc-vm", needsHostCID: false)
        #expect(lease.cid == nil)
        #expect(allocator.count == 0)

        allocator.rollBack(lease)
        #expect(allocator.count == 0)
    }

    @Test("Rolling back a fresh lease gives the CID back")
    func rollingBackAFreshLeaseReleases() throws {
        var allocator = VsockCIDAllocator()

        let lease = try allocator.lease(for: "vm-a", needsHostCID: true)
        #expect(lease.cid == VsockCIDAllocator.firstAssignable)
        #expect(allocator.count == 1)

        allocator.rollBack(lease)
        #expect(allocator.cid(for: "vm-a") == nil)
        #expect(allocator.count == 0)
    }

    /// The guard whose inversion would silently reintroduce the bug this whole
    /// change fixes: an orphan being re-created already holds a CID that the
    /// manifest still records, so a failed re-create must not free it for
    /// somebody else.
    @Test("Rolling back a lease on an already-held CID keeps it")
    func rollingBackAnExistingLeaseKeepsTheCID() throws {
        var allocator = VsockCIDAllocator()
        #expect(allocator.reserve(9, for: "vm-a") == .reserved)

        let lease = try allocator.lease(for: "vm-a", needsHostCID: true)
        #expect(lease.cid == 9)

        allocator.rollBack(lease)
        #expect(allocator.cid(for: "vm-a") == 9)
        #expect(allocator.holder(of: 9) == "vm-a")
    }

    @Test("A lease cannot be taken from an exhausted namespace")
    func leaseThrowsWhenExhausted() throws {
        var allocator = VsockCIDAllocator(first: 3, last: 3)
        _ = try allocator.lease(for: "vm-a", needsHostCID: true)

        #expect(throws: VsockCIDAllocator.AllocationError.exhausted(inUse: 1)) {
            _ = try allocator.lease(for: "vm-b", needsHostCID: true)
        }
    }

    // MARK: - Reclaiming a manifest read

    private func vmEntry(cid: UInt32?, guestAgentEnabled: Bool = true) -> VMManifestEntry {
        VMManifestEntry(
            hypervisorType: .qemu,
            spec: VMSpec(
                cpus: 1, memoryBytes: 1024, boot: .disk(firmware: nil),
                guestAgentEnabled: guestAgentEnabled),
            vsockCID: cid)
    }

    private func quarantinedEntry(cid: UInt32?) -> QuarantinedManifestEntry {
        QuarantinedManifestEntry(
            kind: .vm, hypervisorTypeRawValue: "libvirt", cpus: 1, memoryBytes: 1024, diskBytes: 0,
            vsockCID: cid, reason: "test", raw: .null)
    }

    /// Both halves of a manifest read are claimed: a quarantined workload may
    /// still be running on its CID, which is a host resource exactly like the
    /// capacity that entry keeps reserved.
    @Test("A manifest read reclaims routable and quarantined CIDs alike")
    func reserveAllClaimsBothHalves() throws {
        var allocator = VsockCIDAllocator()

        let refusals = allocator.reserveAll(
            entries: ["vm-a": vmEntry(cid: 10), "vm-b": vmEntry(cid: nil)],
            quarantined: ["vm-q": quarantinedEntry(cid: 11)])

        #expect(refusals.isEmpty)
        #expect(allocator.cid(for: "vm-a") == 10)
        #expect(allocator.cid(for: "vm-q") == 11)
        #expect(allocator.cid(for: "vm-b") == nil)
        #expect(allocator.count == 2)
        // And the reload leaves the cursor above them, so the next VM does not
        // land on a CID a since-deleted guest's connections may still target.
        #expect(try allocator.allocate(for: "vm-new") == 12)
    }

    @Test("A disabled typed VM does not reclaim a stale pre-STR-76 CID")
    func disabledVMDoesNotReserveCID() throws {
        var allocator = VsockCIDAllocator()
        let refusals = allocator.reserveAll(
            entries: ["vm-off": vmEntry(cid: 10, guestAgentEnabled: false)], quarantined: [:])

        #expect(refusals.isEmpty)
        #expect(allocator.cid(for: "vm-off") == nil)
        #expect(allocator.count == 0)
        #expect(try allocator.allocate(for: "vm-on") == 3)
    }

    /// Which side of a duplicate wins must not be a dictionary-ordering coin
    /// flip: an operator who re-creates the loser has to see the same verdict
    /// on the next start, not the opposite one.
    @Test("A duplicated CID in the manifest is refused deterministically")
    func reserveAllResolvesConflictsDeterministically() {
        for _ in 0..<20 {
            var allocator = VsockCIDAllocator()
            let refusals = allocator.reserveAll(
                entries: ["vm-b": vmEntry(cid: 10), "vm-a": vmEntry(cid: 10)],
                quarantined: ["vm-c": quarantinedEntry(cid: 10)])

            // Lowest id wins; the other two are refused, in id order.
            #expect(allocator.holder(of: 10) == "vm-a")
            #expect(refusals.map(\.workloadId) == ["vm-b", "vm-c"])
            #expect(refusals.allSatisfy { $0.reason == .conflict(holder: "vm-a") })
            #expect(refusals.allSatisfy { $0.cid == 10 })
            // A refused claim leaves the loser with nothing rather than
            // stealing the CID from the winner.
            #expect(allocator.cid(for: "vm-b") == nil)
            #expect(allocator.count == 1)
        }
    }

    @Test("An unusable CID in the manifest is refused, not reserved")
    func reserveAllRefusesUnusableCIDs() {
        var allocator = VsockCIDAllocator()

        let refusals = allocator.reserveAll(
            entries: ["vm-a": vmEntry(cid: 2)], quarantined: [:])

        #expect(refusals.map(\.reason) == [.notAssignable])
        #expect(refusals.map(\.workloadId) == ["vm-a"])
        #expect(allocator.count == 0)
    }

    /// The answer to STR-72's open question: Firecracker's vsock never touches
    /// the host kernel's namespace, so it draws nothing from this allocator.
    @Test("Only QEMU draws from the host vsock namespace")
    func onlyQEMUUsesTheHostNamespace() {
        #expect(HypervisorType.qemu.usesHostVsockNamespace)
        #expect(!HypervisorType.firecracker.usesHostVsockNamespace)
    }
}
