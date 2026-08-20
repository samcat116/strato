import Testing
import Foundation
import StratoShared
import Vapor
@testable import App

@Suite("VMSpecBuilder.buildImageInfo — artifact set")
struct VMSpecBuilderImageInfoTests {
    private func readyImage(
        architecture: CPUArchitecture,
        artifacts: [ImageArtifactSnapshot]? = nil
    ) -> Image {
        Image(
            name: "img",
            description: "",
            projectID: UUID(),
            architecture: architecture,
            status: .ready,
            uploadedByID: UUID(),
            loadedArtifacts: artifacts)
    }

    private func artifact(
        _ kind: ArtifactKind, format: ImageFormat? = nil, checksum: String
    ) -> ImageArtifactSnapshot {
        ImageArtifactSnapshot(
            imageID: UUID(),
            kind: kind,
            format: format,
            architecture: .x86_64,
            filename: "\(kind.rawValue).bin",
            size: 5,
            checksum: String(repeating: checksum, count: 64),
            storagePath: "p/\(kind.rawValue)"
        )
    }

    @Test("Emits one explicit download descriptor per artifact")
    func emitsArtifactSet() throws {
        let image = readyImage(
            architecture: .x86_64,
            artifacts: [
                artifact(.diskImage, format: .qcow2, checksum: "d"),
                artifact(.kernel, checksum: "a"),
                artifact(.rootfs, format: .raw, checksum: "b"),
            ])

        let info = try VMSpecBuilder.buildImageInfo(from: image)

        #expect(info.architecture == .x86_64)
        #expect(info.artifacts.count == 3)

        // Each artifact URL is a control-plane-relative path selecting its own
        // kind — the agent resolves it against the base it dials and
        // authenticates with its SVID, so there is no signature to carry.
        for artifact in info.artifacts {
            #expect(artifact.downloadURL.hasPrefix("/api/projects/"))
            #expect(artifact.downloadURL.contains("artifact=\(artifact.kind.rawValue)"))
        }

        // URLs are distinct per artifact.
        let urls = Set(info.artifacts.map(\.downloadURL))
        #expect(urls.count == 3)

        #expect(info.artifact(ofKind: .diskImage)?.checksum == String(repeating: "d", count: 64))
        #expect(info.artifact(ofKind: .kernel)?.checksum == String(repeating: "a", count: 64))
        #expect(info.artifact(ofKind: .rootfs)?.checksum == String(repeating: "b", count: 64))
    }

    @Test("Fails explicitly when a ready image has no usable artifacts")
    func missingArtifactsFail() throws {
        let image = readyImage(architecture: .arm64, artifacts: [])

        #expect(throws: Abort.self) {
            try VMSpecBuilder.buildImageInfo(from: image)
        }
    }

    @Test("Volume image info rejects a Firecracker-only artifact set")
    func volumeInfoRequiresDiskImage() throws {
        let image = readyImage(
            architecture: .x86_64,
            artifacts: [
                artifact(.kernel, checksum: "a"),
                artifact(.rootfs, format: .raw, checksum: "b"),
            ])

        #expect(throws: Abort.self) {
            try VMSpecBuilder.buildDiskImageInfo(from: image)
        }
    }

    @Test("Volume image info accepts a usable disk artifact")
    func volumeInfoAcceptsDiskImage() throws {
        let image = readyImage(
            architecture: .x86_64,
            artifacts: [artifact(.diskImage, format: .qcow2, checksum: "d")])

        let info = try VMSpecBuilder.buildDiskImageInfo(from: image)

        #expect(info.artifact(ofKind: .diskImage) != nil)
    }
}
