import Foundation
import Testing

@testable import StratoShared

/// The wire shape of snapshot artifacts as desired state (ADR 0001 stage 8,
/// STR-150).
///
/// The tests that matter most here are the two absence tests. Both new lists
/// are `Optional` rather than `[]`-defaulted, and that difference is the whole
/// safety property: nil means "the sender has no opinion", never "delete every
/// checkpoint on this host". Read wrong, silence here destroys a point in time
/// nothing can recreate, so each direction is pinned separately.
@Suite("Snapshot artifacts on the wire (STR-150)")
struct SnapshotReconciliationTests {

    @Test("A desired entry survives the envelope with its capture strategy")
    func desiredEntryRoundTrips() throws {
        let entry = DesiredSnapshotState(
            snapshotId: Fixtures.uuidA,
            kind: .sandboxSnapshot,
            parentId: Fixtures.uuidB,
            desiredStatus: .present,
            generation: 7,
            capture: .sandbox(.stop),
            export: DesiredSnapshotExport(uploads: [
                SandboxSnapshotArtifactUploadTarget(kind: .memory, uploadURL: "/api/…/memory")
            ]))

        let decoded = try roundTrip(entry)
        #expect(decoded.snapshotId == Fixtures.uuidA)
        #expect(decoded.kind == .sandboxSnapshot)
        #expect(decoded.parentId == Fixtures.uuidB)
        #expect(decoded.generation == 7)
        #expect(decoded.capture?.sandboxMode == .stop)
        #expect(decoded.export?.uploads.count == 1)
    }

    /// The strict decode is deliberate and shared with `DesiredVMStatus`: an
    /// unknown value must fail rather than route an artifact to the wrong
    /// backend, where a delete would find nothing and quietly succeed.
    @Test("An unknown artifact kind fails to decode rather than defaulting")
    func unknownKindThrows() {
        #expect(throws: DecodingError.self) {
            try decodeJSON([SnapshotArtifactKind].self, from: #"["RBDSnapshot"]"#)
        }
    }

    @Test("An unknown desired status fails to decode rather than defaulting")
    func unknownDesiredStatusThrows() {
        #expect(throws: DecodingError.self) {
            try decodeJSON([DesiredSnapshotStatus].self, from: #"["Archived"]"#)
        }
    }

    /// A sync from a pre-v33 control plane says nothing about snapshots. It
    /// must decode to nil, not `[]`: the agent skips its whole snapshot half on
    /// nil, and would plan against an empty desired list otherwise — reporting
    /// every artifact on the host as unaccounted for.
    @Test("A pre-v33 sync decodes snapshots to nil, not an empty list")
    func desiredSnapshotsAbsenceIsNotEmptiness() throws {
        let legacy = #"{"requestId":"r","timestamp":0,"syncId":"s","vms":[]}"#
        let decoded = try decodeJSON(DesiredStateMessage.self, from: legacy)
        #expect(decoded.snapshots == nil)

        // An explicit empty list is a *different* statement — "this host should
        // hold no artifacts" — and must survive the round trip as one.
        let empty = DesiredStateMessage(syncId: "s", vms: [], snapshots: [])
        #expect(try roundTrip(empty).snapshots?.isEmpty == true)
    }

    /// The other direction, with sharper stakes: an empty list the control
    /// plane believed would reap every checkpoint row it holds for the agent.
    @Test("A pre-v33 report decodes snapshots to nil, not an empty list")
    func observedSnapshotsAbsenceIsNotEmptiness() throws {
        let legacy = """
            {"requestId":"r","timestamp":0,"agentId":"a","vms":[],
             "resources":{"totalCPU":1,"availableCPU":1,"totalMemory":1,"availableMemory":1,
             "totalDisk":1,"availableDisk":1}}
            """
        let decoded = try decodeJSON(ObservedStateReport.self, from: legacy)
        #expect(decoded.snapshots == nil)

        let empty = ObservedStateReport(
            agentId: "a", vms: [], resources: Fixtures.resources, snapshots: [])
        #expect(try roundTrip(empty).snapshots?.isEmpty == true)
    }

    @Test("Snapshot fields actually reach the wire")
    func snapshotKeysEncoded() throws {
        let message = DesiredStateMessage(syncId: "s", vms: [], snapshots: [])
        #expect(try encodedKeys(message).contains("snapshots"))

        let report = ObservedStateReport(
            agentId: "a", vms: [], resources: Fixtures.resources, snapshots: [])
        #expect(try encodedKeys(report).contains("snapshots"))
    }

    /// Every captured fact is optional, and absence means "unknown" rather than
    /// "zero" at every consumer: a footprint the agent could not measure must
    /// not silently become a free one in quota accounting.
    @Test("Observed facts round-trip and tolerate a sparse capture")
    func observedFactsRoundTrip() throws {
        let full = ObservedSnapshotState(
            snapshotId: Fixtures.uuidA,
            kind: .vmCheckpoint,
            parentId: Fixtures.uuidB,
            present: true,
            exported: false,
            facts: ObservedSnapshotFacts(
                sizeBytes: 2_147_483_648,
                architecture: .x86_64,
                qemuVersion: "9.1.0"),
            observedGeneration: 3)
        let decoded = try roundTrip(full)
        #expect(decoded.facts?.sizeBytes == 2_147_483_648)
        #expect(decoded.facts?.qemuVersion == "9.1.0")

        // A QEMU build that reported no size for the tag it just wrote leaves
        // the field nil — the checkpoint is still valid.
        let sizeless = ObservedSnapshotState(
            snapshotId: Fixtures.uuidA,
            kind: .vmCheckpoint,
            parentId: Fixtures.uuidB,
            present: true,
            facts: ObservedSnapshotFacts(),
            observedGeneration: 3)
        let decodedSizeless = try roundTrip(sizeless)
        #expect(decodedSizeless.facts?.sizeBytes == nil)
        #expect(decodedSizeless.facts?.qemuVersion == nil)
    }

    /// `SnapshotArtifactKind` and `WorkloadKind` are in bijection, and both
    /// halves are load-bearing: the reconciler namespaces generations by
    /// workload kind, and the control plane keys a claim on it.
    @Test("Artifact kinds map both ways to workload kinds")
    func kindBijection() {
        for kind in SnapshotArtifactKind.allCases {
            #expect(SnapshotArtifactKind(kind.workloadKind) == kind)
            #expect(kind.workloadKind.isSnapshotArtifact)
        }
        for kind in [WorkloadKind.vm, .sandbox, .volume] {
            #expect(SnapshotArtifactKind(kind) == nil)
            #expect(!kind.isSnapshotArtifact)
        }
    }

    /// A parent's kind decides which lane a capture holds, which is what keeps
    /// it from interleaving with that parent's own convergence.
    @Test("Each artifact family names its parent's workload kind")
    func parentKinds() {
        #expect(SnapshotArtifactKind.volumeSnapshot.parentKind == .volume)
        #expect(SnapshotArtifactKind.vmCheckpoint.parentKind == .vm)
        #expect(SnapshotArtifactKind.sandboxSnapshot.parentKind == .sandbox)
    }

}
