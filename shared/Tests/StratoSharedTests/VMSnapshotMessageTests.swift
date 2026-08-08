import Foundation
import Testing

@testable import StratoShared

/// What is left of the full-VM checkpoint message set: no messages at all.
/// Capture and delete became desired state at wire v33 (ADR 0001 stage 8,
/// STR-150) and restore became an edge-nonce at v34 (stage 9, STR-151); both are
/// pinned by `SnapshotReconciliationTests` and `EdgeNonceReconciliationTests`.
/// The tag derivation both sides depend on is what remains.
@Suite("VM checkpoint snapshot tags (issue #564)")
struct VMSnapshotMessageTests {
    @Test("snapshot tags are valid QEMU identifiers derived from the id")
    func tagDerivation() {
        let tag = VMSnapshotTag.tag(for: "AAAAAAAA-1111-2222-3333-444444444444")
        // A bare UUID may start with a digit, which QEMU rejects as an
        // identifier; the fixed prefix makes every tag legal.
        #expect(tag == "strato-aaaaaaaa-1111-2222-3333-444444444444")
        #expect(tag.first?.isLetter == true)
        #expect(tag.allSatisfy { $0.isLetter || $0.isNumber || "-._".contains($0) })
        // Total and pure: a delete re-derives exactly what the create wrote.
        #expect(VMSnapshotTag.tag(for: "aaaaaaaa-1111-2222-3333-444444444444") == tag)
    }

    /// The inverse mapping is what lets an agent turn a disk's tag list back
    /// into control-plane identities — and, just as importantly, leave anyone
    /// else's internal snapshots alone.
    @Test("tags map back to the snapshot id they were minted from")
    func tagInverse() {
        let id = "aaaaaaaa-1111-2222-3333-444444444444"
        #expect(
            VMSnapshotTag.snapshotId(fromTag: VMSnapshotTag.tag(for: id))
                == UUID(uuidString: id))
        #expect(VMSnapshotTag.snapshotId(fromTag: "someone-elses-snapshot") == nil)
        #expect(VMSnapshotTag.snapshotId(fromTag: "strato-not-a-uuid") == nil)
    }
}
