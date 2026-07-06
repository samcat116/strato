import Testing
import Foundation
import StratoShared
@testable import App

@Suite("VMSpecBuilder.buildImageInfo — artifact set")
struct VMSpecBuilderImageInfoTests {
    private let key = "test-signing-key-of-sufficient-length-1234567890"

    private func readyImage(architecture: CPUArchitecture) -> Image {
        let image = Image(
            name: "img",
            description: "",
            projectID: UUID(),
            filename: "disk.qcow2",
            architecture: architecture,
            status: .ready,
            uploadedByID: UUID()
        )
        image.id = UUID()
        image.checksum = "diskchk"
        image.storagePath = "p/disk.qcow2"
        return image
    }

    private func artifact(
        _ kind: ArtifactKind, format: ImageFormat? = nil, checksum: String
    ) -> ImageArtifact {
        ImageArtifact(
            imageID: UUID(),
            kind: kind,
            format: format,
            architecture: .x86_64,
            filename: "\(kind.rawValue).bin",
            size: 5,
            checksum: checksum,
            storagePath: "p/\(kind.rawValue)"
        )
    }

    @Test("Emits one signed artifact per artifact, with the disk image as primary")
    func emitsArtifactSet() throws {
        let image = readyImage(architecture: .x86_64)
        image.$artifacts.value = [
            artifact(.diskImage, format: .qcow2, checksum: "d"),
            artifact(.kernel, checksum: "k"),
            artifact(.rootfs, format: .raw, checksum: "r"),
        ]

        let info = try VMSpecBuilder.buildImageInfo(
            from: image, controlPlaneURL: "http://cp", agentName: "agent-1", signingKey: key)

        #expect(info.architecture == .x86_64)
        #expect(info.artifacts.count == 3)

        // Each artifact URL selects its own kind.
        for artifact in info.artifacts {
            #expect(artifact.downloadURL.contains("artifact=\(artifact.kind.rawValue)"))
        }

        // URLs are distinct per artifact.
        let urls = Set(info.artifacts.map(\.downloadURL))
        #expect(urls.count == 3)

        // Top-level fields describe the primary (disk-image) artifact.
        #expect(info.checksum == "d")
        #expect(info.artifact(ofKind: .kernel)?.checksum == "k")
        #expect(info.artifact(ofKind: .rootfs)?.format == "raw")
    }

    @Test("Falls back to legacy fields when no artifacts are present")
    func legacyFallback() throws {
        let image = readyImage(architecture: .arm64)
        image.$artifacts.value = []

        let info = try VMSpecBuilder.buildImageInfo(
            from: image, controlPlaneURL: "http://cp", agentName: "agent-1", signingKey: key)

        #expect(info.artifacts.isEmpty)
        #expect(info.architecture == .arm64)
        #expect(info.checksum == "diskchk")
        #expect(!info.downloadURL.contains("artifact="))
    }
}
