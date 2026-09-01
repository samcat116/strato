import StratoShared
import Testing

@testable import StratoAgentCore

@Suite("SandboxJailUIDAllocator Tests")
struct SandboxJailUIDAllocatorTests {
    private func sandboxEntry(uid: UInt32?) -> VMManifestEntry {
        VMManifestEntry(
            sandboxSpec: SandboxSpec(image: "alpine:3", cpus: 1, memoryBytes: 1024),
            jailUID: uid)
    }

    private func quarantinedEntry(uid: UInt32?) -> QuarantinedManifestEntry {
        QuarantinedManifestEntry(
            kind: nil,
            hypervisorTypeRawValue: "future-firecracker",
            cpus: 1,
            memoryBytes: 1024,
            diskBytes: 0,
            vsockCID: nil,
            jailUID: uid,
            reason: "test",
            raw: .null)
    }

    @Test("Every fresh sandbox gets an exactly distinct uid")
    func allocationsAreDistinct() throws {
        var allocator = SandboxJailUIDAllocator(first: 100, last: 200)

        let uids = try Set((0..<32).map { try allocator.allocate(for: "sandbox-\($0)") })

        #expect(uids.count == 32)
        #expect(uids.allSatisfy { $0 >= 100 && $0 <= 200 })
        #expect(allocator.count == 32)
    }

    @Test("A released uid is not immediately reused")
    func releasedUIDIsNotImmediatelyReused() throws {
        var allocator = SandboxJailUIDAllocator(first: 100, last: 102)
        let first = try allocator.allocate(for: "sandbox-a")

        #expect(allocator.release("sandbox-a") == first)
        #expect(try allocator.allocate(for: "sandbox-b") == 101)
    }

    @Test("A full range refuses rather than reusing an identity")
    func exhaustionRefuses() throws {
        var allocator = SandboxJailUIDAllocator(first: 100, last: 101)
        #expect(try allocator.allocate(for: "sandbox-a") == 100)
        #expect(try allocator.allocate(for: "sandbox-b") == 101)

        #expect(throws: SandboxJailUIDAllocator.AllocationError.exhausted(inUse: 2)) {
            _ = try allocator.allocate(for: "sandbox-c")
        }
        #expect(allocator.uid(for: "sandbox-c") == nil)
    }

    @Test("Exhaustion is localized and classified")
    func exhaustionSurfacesThroughReconciliation() {
        let error: any Error = SandboxJailUIDAllocator.AllocationError.exhausted(inUse: 12)

        #expect(error.localizedDescription.contains("exhausted"))
        #expect((error as? any ClassifiableError)?.failureClassification == .permanent)
    }

    @Test("A fresh failed lease rolls back, while an existing identity stays held")
    func leaseRollbackOnlyReleasesWhatItTook() throws {
        var allocator = SandboxJailUIDAllocator(first: 100, last: 102)

        let fresh = try allocator.lease(for: "sandbox-a")
        #expect(fresh.uid == 100)
        allocator.rollBack(fresh)
        #expect(allocator.uid(for: "sandbox-a") == nil)

        #expect(allocator.reserve(101, for: "sandbox-b") == .reserved)
        let existing = try allocator.lease(for: "sandbox-b")
        allocator.rollBack(existing)
        #expect(allocator.uid(for: "sandbox-b") == 101)
    }

    @Test("An unjailed runtime does not consume a jail uid")
    func unjailedPolicySkipsLease() throws {
        var allocator = SandboxJailUIDAllocator(first: 100, last: 101)
        let policy = SandboxJailUIDPolicy(jailsNewSandboxes: false)

        #expect(!policy.requiresLease)
        #expect(try policy.lease(for: "sandbox-a", from: &allocator) == nil)
        #expect(allocator.uid(for: "sandbox-a") == nil)
        #expect(allocator.count == 0)
    }

    @Test("A jailed runtime consumes a jail uid")
    func jailedPolicyLeasesIdentity() throws {
        var allocator = SandboxJailUIDAllocator(first: 100, last: 101)
        let policy = SandboxJailUIDPolicy(jailsNewSandboxes: true)

        let lease = try #require(policy.lease(for: "sandbox-a", from: &allocator))
        #expect(policy.requiresLease)
        #expect(lease.uid == 100)
        #expect(allocator.uid(for: "sandbox-a") == 100)
    }

    @Test("Manifest reload reserves readable, unreadable-kind, and prior-range uids")
    func reserveAllRestoresEveryPersistedAssignment() throws {
        var allocator = SandboxJailUIDAllocator(first: 100, last: 101)

        let refusals = allocator.reserveAll(
            entries: ["sandbox-old": sandboxEntry(uid: 42)],
            quarantined: ["sandbox-future": quarantinedEntry(uid: 43)])

        #expect(refusals.isEmpty)
        #expect(allocator.uid(for: "sandbox-old") == 42)
        #expect(allocator.uid(for: "sandbox-future") == 43)
        #expect(try allocator.lease(for: "sandbox-old").uid == 42)
        #expect(try allocator.allocate(for: "sandbox-new") == 100)
        #expect(try allocator.allocate(for: "sandbox-next") == 101)
        #expect(throws: SandboxJailUIDAllocator.AllocationError.exhausted(inUse: 2)) {
            _ = try allocator.allocate(for: "sandbox-excess")
        }
    }

    @Test("Root and uid_t(-1) manifest identities are refused")
    func reserveAllRefusesUnassignableUIDs() {
        var allocator = SandboxJailUIDAllocator(first: 100, last: 101)

        let refusals = allocator.reserveAll(
            entries: [
                "sandbox-root": sandboxEntry(uid: 0),
                "sandbox-sentinel": sandboxEntry(uid: UInt32.max),
            ],
            quarantined: [:])

        #expect(refusals.map(\.sandboxId) == ["sandbox-root", "sandbox-sentinel"])
        #expect(refusals.map(\.reason) == [.notAssignable, .notAssignable])
        #expect(allocator.count == 0)
    }

    @Test("Duplicate manifest claims poison the uid until every claimant leaves")
    func duplicateClaimsRemainUnavailableAfterWinnerRelease() throws {
        var allocator = SandboxJailUIDAllocator(first: 100, last: 100)

        let refusals = allocator.reserveAll(
            entries: [
                "sandbox-b": sandboxEntry(uid: 100),
                "sandbox-a": sandboxEntry(uid: 100),
            ],
            quarantined: [:])

        #expect(refusals.map(\.sandboxId) == ["sandbox-b"])
        #expect(refusals.map(\.reason) == [.conflict(holder: "sandbox-a")])
        #expect(allocator.uid(for: "sandbox-a") == nil)
        #expect(allocator.uid(for: "sandbox-b") == nil)

        #expect(allocator.release("sandbox-a") == 100)
        #expect(allocator.uid(for: "sandbox-b") == 100)
        #expect(allocator.holder(of: 100) == "sandbox-b")
        #expect(throws: SandboxJailUIDAllocator.AllocationError.exhausted(inUse: 1)) {
            _ = try allocator.allocate(for: "sandbox-new")
        }
    }

    @Test("Repeated duplicate reservations remain explicit conflicts")
    func repeatedDuplicateReservationReportsConflict() {
        var allocator = SandboxJailUIDAllocator(first: 100, last: 102)

        #expect(allocator.reserve(100, for: "sandbox-a") == .reserved)
        #expect(allocator.isExclusive(100, to: "sandbox-a"))
        #expect(allocator.reserve(100, for: "sandbox-b") == .conflict(holder: "sandbox-a"))
        #expect(!allocator.isExclusive(100, to: "sandbox-a"))
        #expect(!allocator.isExclusive(100, to: "sandbox-b"))
        #expect(allocator.reserve(100, for: "sandbox-a") == .conflict(holder: "sandbox-b"))
        #expect(allocator.reserve(100, for: "sandbox-b") == .conflict(holder: "sandbox-a"))
    }

    @Test("Each legacy duplicate can be torn down without releasing the other claimant")
    func duplicateClaimsReleaseIndependently() throws {
        var allocator = SandboxJailUIDAllocator(first: 100, last: 100)
        #expect(allocator.reserve(100, for: "sandbox-a") == .reserved)
        #expect(allocator.reserve(100, for: "sandbox-b") == .conflict(holder: "sandbox-a"))

        // Removing either durable entry must leave the identity unavailable
        // while the other legacy jail may still exist.
        #expect(allocator.release("sandbox-a") == 100)
        #expect(allocator.uid(for: "sandbox-b") == 100)
        #expect(allocator.isExclusive(100, to: "sandbox-b"))
        #expect(throws: SandboxJailUIDAllocator.AllocationError.exhausted(inUse: 1)) {
            _ = try allocator.allocate(for: "sandbox-new")
        }

        #expect(allocator.release("sandbox-b") == 100)
        #expect(try allocator.allocate(for: "sandbox-new") == 100)
    }

    @Test("A conflicted sandbox leases a fresh uid and rollback restores its old claim")
    func conflictedLeaseMovesAndRollsBackSafely() throws {
        var allocator = SandboxJailUIDAllocator(first: 100, last: 101)
        _ = allocator.reserveAll(
            entries: [
                "sandbox-a": sandboxEntry(uid: 100),
                "sandbox-b": sandboxEntry(uid: 100),
            ],
            quarantined: [:])

        let lease = try allocator.lease(for: "sandbox-b")
        #expect(lease.uid == 101)
        #expect(allocator.uid(for: "sandbox-a") == nil)
        #expect(allocator.uid(for: "sandbox-b") == 101)

        allocator.commit(lease)
        #expect(allocator.uid(for: "sandbox-a") == 100)

        allocator.rollBack(lease)
        #expect(allocator.uid(for: "sandbox-a") == nil)
        #expect(allocator.uid(for: "sandbox-b") == nil)
        #expect(allocator.holder(of: 100) == "sandbox-a")
    }

    @Test("A pending duplicate lease keeps the old uid poisoned until commit")
    func pendingDuplicateLeaseRetainsOldPoison() throws {
        var allocator = SandboxJailUIDAllocator(first: 100, last: 102)
        _ = allocator.reserve(100, for: "sandbox-a")
        _ = allocator.reserve(100, for: "sandbox-b")

        let lease = try allocator.lease(for: "sandbox-b")

        #expect(allocator.uid(for: "sandbox-a") == nil)
        #expect(allocator.uid(for: "sandbox-b") == 101)
        allocator.commit(lease)
        #expect(allocator.uid(for: "sandbox-a") == 100)
    }
}
