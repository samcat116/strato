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

    @Test("Allocation skips CIDs that are already held")
    func allocationSkipsHeldCIDs() throws {
        var allocator = VsockCIDAllocator()
        let first = VsockCIDAllocator.firstAssignable
        for cid in first...(first + 9) {
            #expect(allocator.reserve(cid, for: "held-\(cid)") == .reserved)
        }

        #expect(try allocator.allocate(for: "vm-new") == first + 10)
        #expect(allocator.count == 11)
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

    /// Even at the end of the range the scan wraps to a *free* CID rather than
    /// overflowing past it or landing on a held one.
    @Test("The scan wraps within the range without reusing a held CID")
    func scanWrapsWithinRange() throws {
        var allocator = VsockCIDAllocator(first: 3, last: 5)

        #expect(try allocator.allocate(for: "vm-a") == 3)
        #expect(try allocator.allocate(for: "vm-b") == 4)
        #expect(try allocator.allocate(for: "vm-c") == 5)
        #expect(allocator.release("vm-a") == 3)

        // The cursor is past the top of the range; the next allocation wraps
        // to the one hole rather than to a CID that is still held.
        #expect(try allocator.allocate(for: "vm-d") == 3)
    }

    @Test("Exhaustion is reported with the number of CIDs in use")
    func exhaustionErrorDescribesItself() {
        let error = VsockCIDAllocator.AllocationError.exhausted(inUse: 12)
        #expect(error.description.contains("12"))
        #expect(error == .exhausted(inUse: 12))
    }

    /// The answer to STR-72's open question: Firecracker's vsock never touches
    /// the host kernel's namespace, so it draws nothing from this allocator.
    @Test("Only QEMU draws from the host vsock namespace")
    func onlyQEMUUsesTheHostNamespace() {
        #expect(HypervisorType.qemu.usesHostVsockNamespace)
        #expect(!HypervisorType.firecracker.usesHostVsockNamespace)
    }
}
