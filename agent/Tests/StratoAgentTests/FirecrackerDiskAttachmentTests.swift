import StratoShared
import Testing

@testable import StratoAgentCore

@Suite("Firecracker disk attachments")
struct FirecrackerDiskAttachmentTests {
    @Test("file and block-device attachments resolve to host paths")
    func hostPaths() throws {
        #expect(
            try FirecrackerDiskAttachment.hostPath(
                for: .file(path: "/volumes/root.raw", format: .raw)) == "/volumes/root.raw")
        #expect(
            try FirecrackerDiskAttachment.hostPath(for: .blockDevice(path: "/dev/rbd0"))
                == "/dev/rbd0")
    }

    @Test("native RBD is rejected until the storage layer maps it through krbd")
    func rejectsNativeRBD() {
        #expect(throws: FirecrackerDiskAttachment.Error.nativeRBD) {
            try FirecrackerDiskAttachment.hostPath(
                for: .rbd(
                    pool: "volumes", image: "root", user: "client.project",
                    monHosts: ["mon-1:6789"]))
        }
    }
}
