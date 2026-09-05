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
            capture: DesiredSnapshotCapture(sandboxMode: .stop),
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
        #expect(decoded.volumeStorage == nil)
    }

    @Test("A volume snapshot carries its Ceph backend without a parent volume entry")
    func volumeSnapshotStorageRoundTrips() throws {
        let storage = DesiredVolumeStorage.ceph(
            CephVolumeStorage(
                clusterId: Fixtures.uuidA,
                fsid: "11111111-2222-4333-8444-555555555555",
                pool: "volumes",
                namespace: "project-a",
                clientName: "client.strato-project-a",
                monEndpoints: ["v2:mon.example:3300"],
                credentialId: Fixtures.uuidB,
                keyring: "[client.strato-project-a]\nkey = secret",
                messengerMode: .secure))
        let entry = DesiredSnapshotState(
            snapshotId: UUID(), kind: .volumeSnapshot, parentId: UUID(),
            desiredStatus: .absent, generation: 8, volumeStorage: storage)

        #expect(try roundTrip(entry).volumeStorage == storage)

        // Optional by design: a v53/pre-Ceph snapshot entry still decodes and
        // uses the agent's legacy parent-volume fallback.
        let legacyJSON = """
            {"snapshotId":"\(UUID().uuidString)","kind":"VolumeSnapshot",
             "parentId":"\(UUID().uuidString)","desiredStatus":"Absent","generation":1}
            """
        #expect(try decodeJSON(DesiredSnapshotState.self, from: legacyJSON).volumeStorage == nil)
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

    @Test("The current desired schema requires an authoritative snapshot list")
    func desiredSnapshotsAreRequired() throws {
        let malformed = """
            {"requestId":"r","timestamp":0,"syncId":"s","vms":[],"sandboxes":[],
             "networks":[],"networksAuthoritative":true,"tombstones":[],"volumes":[]}
            """
        #expect(throws: DecodingError.self) {
            try decodeJSON(DesiredStateMessage.self, from: malformed)
        }

        let empty = DesiredStateMessage(syncId: "s", vms: [], snapshots: [])
        #expect(try roundTrip(empty).snapshots.isEmpty)
    }

    /// Unlike desired state, a current observation may omit snapshots when the
    /// local artifact store cannot be enumerated. Nil means unknown; `[]` is an
    /// authoritative empty inventory that can confirm deletion.
    @Test("An unavailable observed snapshot inventory remains semantically optional")
    func observedSnapshotsAbsenceIsNotEmptiness() throws {
        let unavailable = """
            {"requestId":"r","timestamp":0,"agentId":"a","vms":[],"sandboxes":[],
             "resources":{"totalCPU":1,"availableCPU":1,"totalMemory":1,"availableMemory":1,
             "totalDisk":1,"availableDisk":1,"physicalFreeDisk":1},"unrecognized":[]}
            """
        let decoded = try decodeJSON(ObservedStateReport.self, from: unavailable)
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
