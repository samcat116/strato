import Testing
import Foundation
@testable import StratoShared

@Suite("ImageInfo artifact set")
struct ImageInfoArtifactTests {

    @Test("ImageInfo with artifacts round-trips through Codable")
    func artifactSetRoundTrips() throws {
        let imageId = UUID()
        let projectId = UUID()
        let info = ImageInfo(
            imageId: imageId,
            projectId: projectId,
            filename: "disk.qcow2",
            checksum: "abc",
            size: 100,
            downloadURL: "https://cp/disk",
            architecture: .arm64,
            artifacts: [
                ArtifactInfo(
                    kind: .kernel, format: nil, filename: "vmlinux", checksum: "k1",
                    size: 10, downloadURL: "https://cp/kernel"),
                ArtifactInfo(
                    kind: .rootfs, format: "raw", filename: "rootfs.img", checksum: "r1",
                    size: 20, downloadURL: "https://cp/rootfs"),
            ]
        )

        let data = try JSONEncoder().encode(info)
        let decoded = try JSONDecoder().decode(ImageInfo.self, from: data)

        #expect(decoded.imageId == imageId)
        #expect(decoded.architecture == .arm64)
        #expect(decoded.artifacts.count == 2)
        #expect(decoded.artifact(ofKind: .kernel)?.checksum == "k1")
        #expect(decoded.artifact(ofKind: .rootfs)?.format == "raw")
        #expect(decoded.artifact(ofKind: .diskImage) == nil)
    }

    @Test("Legacy payload without architecture/artifacts still decodes")
    func legacyPayloadDecodes() throws {
        // A message shaped like the pre-#214 ImageInfo (no architecture/artifacts).
        let legacyJSON = """
        {
            "imageId": "\(UUID().uuidString)",
            "projectId": "\(UUID().uuidString)",
            "filename": "cloud.qcow2",
            "checksum": "deadbeef",
            "size": 42,
            "downloadURL": "https://cp/legacy"
        }
        """

        let decoded = try JSONDecoder().decode(ImageInfo.self, from: Data(legacyJSON.utf8))

        #expect(decoded.filename == "cloud.qcow2")
        #expect(decoded.architecture == nil)
        #expect(decoded.artifacts.isEmpty)
        #expect(decoded.artifact(ofKind: .diskImage) == nil)
    }
}
