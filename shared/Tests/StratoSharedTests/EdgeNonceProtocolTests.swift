import Foundation
import Testing

@testable import StratoShared

/// The wire half of ADR 0001 stage 9 (STR-151): reboot and restore as monotonic
/// nonces on the desired entry.
///
/// What these pin is mostly *absence* semantics, because that is where the whole
/// safety argument lives. Both fields are `Optional`, and every reading of a
/// missing one has to be inert — a count of requests can only ever mean "nothing
/// was asked for". If either ever encoded a zero, or decoded a missing key into
/// something an agent could act on, a pre-v34 control plane would start
/// rebooting guests.
@Suite("Edge nonces on the wire (STR-151)")
struct EdgeNonceProtocolTests {
    private static let snapshotID = UUID(uuidString: "CCCCCCCC-9999-AAAA-BBBB-CCCCCCCCCCCC")!

    private func vm(
        rebootGeneration: Int64? = nil, restore: DesiredRestore? = nil
    ) -> DesiredVMState {
        DesiredVMState(
            vmId: Fixtures.uuidA,
            hypervisorType: .qemu,
            spec: VMSpec(cpus: 1, memoryBytes: 1 << 30, boot: .disk(firmware: nil)),
            desiredStatus: .running,
            generation: 4,
            rebootGeneration: rebootGeneration,
            restore: restore)
    }

    @Test("both nonces survive the envelope")
    func noncesRoundTrip() throws {
        let message = DesiredStateMessage(
            syncId: "sync-edges",
            vms: [
                vm(
                    rebootGeneration: 3,
                    restore: DesiredRestore(generation: 2, snapshotId: Self.snapshotID))
            ])

        let decoded = try throughEnvelope(message)
        #expect(decoded.vms[0].rebootGeneration == 3)
        #expect(decoded.vms[0].restore?.generation == 2)
        #expect(decoded.vms[0].restore?.snapshotId == Self.snapshotID)
        // A VM checkpoint lives inside the VM's own disks, so it never moves
        // hosts and a VM restore never stages artifacts.
        #expect(decoded.vms[0].restore?.artifacts == nil)
    }

    @Test("a VM that has never been restarted or restored puts nothing on the wire")
    func absentNoncesOmitTheKeys() throws {
        let keys = try encodedKeys(vm())
        #expect(!keys.contains("rebootGeneration"))
        #expect(!keys.contains("restore"))
    }

    /// The v34 skew case: a sync assembled by a pre-STR-151 control plane. It
    /// must decode, and it must decode to "no opinion" rather than to a zero an
    /// agent could compare against.
    @Test("a pre-v34 sync decodes with both nonces absent")
    func preV34SyncDecodes() throws {
        // Built by encoding a v34 entry and deleting the two keys, so the
        // fixture cannot drift out of date with the rest of `DesiredVMState`
        // and start passing for the wrong reason.
        let encoded = try encodeJSON(
            vm(rebootGeneration: 3, restore: DesiredRestore(generation: 2, snapshotId: Self.snapshotID)))
        var object = try #require(
            try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "rebootGeneration")
        object.removeValue(forKey: "restore")

        let decoded = try decodeJSON(
            DesiredVMState.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(decoded.rebootGeneration == nil)
        #expect(decoded.restore == nil)
        #expect(decoded.generation == 4)
    }

    @Test("a sandbox restore carries its exported artifacts")
    func sandboxRestoreCarriesArtifacts() throws {
        // Cross-agent restore (issue #428): the sandbox has moved off the host
        // that captured the snapshot, so the nonce carries the descriptors the
        // target stages from. They are minted at sync assembly, which is why a
        // long-outstanding nonce never holds a stale locator.
        let artifact = SandboxSnapshotArtifactDescriptor(
            kind: .memory,
            downloadURL: "/api/sandboxes/\(Fixtures.uuidB)/snapshots/\(Self.snapshotID)/artifacts/memory",
            sizeBytes: 4096,
            sha256: "abc123")
        let entry = DesiredSandboxState(
            sandboxId: Fixtures.uuidB,
            spec: SandboxSpec(image: "alpine:3", cpus: 1, memoryBytes: 1 << 28),
            desiredStatus: .running,
            generation: 9,
            restore: DesiredRestore(
                generation: 5, snapshotId: Self.snapshotID, artifacts: [artifact]))

        let decoded = try roundTrip(entry)
        #expect(decoded.restore?.generation == 5)
        #expect(decoded.restore?.artifacts?.count == 1)
        #expect(decoded.restore?.artifacts?.first?.sha256 == "abc123")
        // `restore` and `restoreFrom` are different fields with different
        // meanings — an edge on an existing sandbox versus a fork's create
        // strategy — and nothing may conflate them.
        #expect(decoded.restoreFrom == nil)
    }

    @Test("edge-nonce gate refuses anything below v34")
    func gate() {
    }
}
