import Foundation
import Testing

import StratoShared

/// The wire half of ADR 0001 stage 9 (STR-151): reboot and restore as monotonic
/// nonces on the desired entry.
///
/// Missing nonces are inert; an explicitly present zero remains distinguishable
/// from absence in the binary contract.
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
        #expect(decoded.vms.values[0].rebootGeneration == 3)
        #expect(decoded.vms.values[0].restore.generation == 2)
        #expect(decoded.vms.values[0].restore.snapshotID == Self.snapshotID.uuidString)
        // A VM checkpoint lives inside the VM's own disks, so it never moves
        // hosts and a VM restore never stages artifacts.
        #expect(!decoded.vms.values[0].restore.hasArtifacts)
    }

    @Test("Absent edge nonces remain distinct from an explicitly present zero")
    func absentNonces() throws {
        let message = DesiredStateMessage(syncId: "presence", vms: [vm(), vm(rebootGeneration: 0)])
        let decoded = try throughEnvelope(message)
        try #require(decoded.vms.values.count == 2)
        #expect(!decoded.vms.values[0].hasRebootGeneration)
        #expect(!decoded.vms.values[0].hasRestore)
        #expect(decoded.vms.values[1].hasRebootGeneration)
        #expect(decoded.vms.values[1].rebootGeneration == 0)
        #expect(!decoded.vms.values[1].hasRestore)
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

        let message = try throughEnvelope(DesiredStateMessage(syncId: "restore", vms: [], sandboxes: [entry]))
        let decoded = try #require(message.sandboxes.values.first)
        #expect(decoded.hasRestore)
        #expect(decoded.restore.hasArtifacts)
        #expect(decoded.restore.generation == 5)
        #expect(decoded.restore.artifacts.values.count == 1)
        #expect(decoded.restore.artifacts.values.first?.sha256 == "abc123")
        // `restore` and `spec.restoreFrom` have different
        // meanings — an edge on an existing sandbox versus a fork's create
        // strategy — and nothing may conflate them.
        #expect(!decoded.spec.hasRestoreFrom)
    }

}
