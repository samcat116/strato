import Testing

@testable import App

@Suite("Volume Status Tests")
struct VolumeStatusTests {

    @Test("canDelete allows available, error, and deleting", arguments: VolumeStatus.allCases)
    func testCanDelete(status: VolumeStatus) {
        let volume = Volume()
        volume.status = status

        // `.deleting` must stay deletable: a control-plane restart mid-delete
        // strands the volume in that state, and re-issuing the DELETE is the
        // only recovery path (agent-side directory removal is idempotent).
        let expected = status == .available || status == .error || status == .deleting
        #expect(volume.canDelete == expected)
    }
}
