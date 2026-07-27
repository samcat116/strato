import Testing

@testable import App

@Suite("Volume Status Tests")
struct VolumeStatusTests {

    @Test("canDelete allows every state except attached", arguments: VolumeStatus.allCases)
    func testCanDelete(status: VolumeStatus) {
        let volume = Volume()
        volume.status = status

        // Only an actively attached volume is undeletable. `.deleting` stays
        // deletable (agent-side directory removal is idempotent) and issue #644
        // extends the same escape hatch to every other transitional state so a
        // crash mid-operation can't strand a volume with no recovery.
        let expected = status != .attached
        #expect(volume.canDelete == expected)
    }

    @Test("canSnapshot admits only a detached volume", arguments: VolumeStatus.allCases)
    func testCanSnapshot(status: VolumeStatus) {
        let volume = Volume()
        volume.status = status

        // Issue #747: `.attached` used to be admitted, and produced an overlay
        // backed by the volume a guest was still writing — a "snapshot" that
        // tracked the live data instead of freezing a moment in time. Only a
        // detached volume can be snapshotted correctly by the overlay backend.
        let expected = status == .available
        #expect(volume.canSnapshot == expected)
    }
}
