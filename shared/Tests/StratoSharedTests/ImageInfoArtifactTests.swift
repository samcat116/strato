import Testing
import Foundation
@testable import StratoShared

@Suite("ImageInfo artifact set")
struct ImageInfoArtifactTests {
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
