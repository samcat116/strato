import Testing
import Foundation
@testable import StratoShared

@Suite("ImageInfo artifact set")
struct ImageInfoArtifactTests {
    @Test("Artifact-only payload round-trips")
    func artifactPayloadRoundTrips() throws {
        let info = ImageInfo(
            imageId: UUID(), projectId: UUID(), architecture: .arm64,
            artifacts: [
                ArtifactInfo(
                    kind: .diskImage, filename: "cloud.qcow2",
                    checksum: String(repeating: "d", count: 64), size: 42,
                    downloadURL: "/download?artifact=disk-image")
            ])

        let decoded = try JSONDecoder().decode(ImageInfo.self, from: JSONEncoder().encode(info))

        #expect(decoded.architecture == .arm64)
        #expect(decoded.artifact(ofKind: .diskImage)?.filename == "cloud.qcow2")
    }

    @Test("Payload without typed artifacts is rejected")
    func legacyPayloadRejected() {
        let legacyJSON = """
            {"imageId":"\(UUID())","projectId":"\(UUID())","filename":"legacy.qcow2"}
            """
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(ImageInfo.self, from: Data(legacyJSON.utf8))
        }
    }
}
