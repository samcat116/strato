import Testing
import Foundation
import StratoShared
@testable import App

@Suite("Image hypervisor compatibility")
struct ImageCompatibilityTests {

    private func makeImage(
        architecture: CPUArchitecture,
        status: ImageStatus = .pending,
        artifacts: [ImageArtifactSnapshot]? = nil
    ) -> Image {
        Image(
            name: "img",
            description: "",
            projectID: UUID(),
            architecture: architecture,
            status: status,
            uploadedByID: UUID(),
            loadedArtifacts: artifacts)
    }

    private func artifact(
        _ kind: ArtifactKind, arch: CPUArchitecture, format: ImageFormat? = nil,
        status: ArtifactStatus = .ready, progress: Int? = nil, error: String? = nil
    ) -> ImageArtifactSnapshot {
        ImageArtifactSnapshot(
            imageID: UUID(),
            kind: kind,
            format: format,
            architecture: arch,
            filename: kind.rawValue,
            size: 1,
            checksum: String(repeating: "c", count: 64),
            storagePath: "p",
            status: status,
            downloadProgress: progress,
            errorMessage: error
        )
    }

    @Test("Disk image is QEMU-usable, not Firecracker-usable")
    func diskImageIsQemuOnly() {
        let image = makeImage(
            architecture: .x86_64,
            artifacts: [artifact(.diskImage, arch: .x86_64, format: .qcow2)])

        #expect(image.compatibleHypervisors() == [.qemu])
        #expect(image.isUsable(by: .qemu))
        #expect(!image.isUsable(by: .firecracker))
    }

    @Test("Kernel + rootfs is Firecracker-usable")
    func kernelAndRootfsIsFirecracker() {
        let image = makeImage(
            architecture: .arm64,
            artifacts: [
                artifact(.kernel, arch: .arm64),
                artifact(.rootfs, arch: .arm64, format: .raw),
            ])

        #expect(image.compatibleHypervisors() == [.firecracker])
        #expect(image.isUsable(by: .firecracker))
        #expect(!image.isUsable(by: .qemu))
    }

    @Test("A full artifact set is usable by both")
    func fullSetIsUsableByBoth() {
        let image = makeImage(
            architecture: .x86_64,
            artifacts: [
                artifact(.diskImage, arch: .x86_64, format: .qcow2),
                artifact(.kernel, arch: .x86_64),
                artifact(.rootfs, arch: .x86_64, format: .raw),
            ])

        #expect(image.compatibleHypervisors() == [.qemu, .firecracker])
    }

    @Test("Architecture-mismatched artifacts don't count")
    func archMismatchExcluded() {
        let image = makeImage(
            architecture: .arm64,
            artifacts: [
                artifact(.kernel, arch: .x86_64),
                artifact(.rootfs, arch: .x86_64, format: .raw),
            ])
        // Artifacts are x86_64 while the image is arm64 — nothing matches.

        #expect(image.compatibleHypervisors().isEmpty)
    }

    @Test("Kernel without rootfs is not Firecracker-usable")
    func kernelWithoutRootfs() {
        let image = makeImage(
            architecture: .x86_64,
            artifacts: [artifact(.kernel, arch: .x86_64)])

        #expect(image.compatibleHypervisors().isEmpty)
    }

    @Test("No loaded artifacts means compatible with nothing")
    func noArtifacts() {
        let image = makeImage(architecture: .x86_64, artifacts: [])

        #expect(image.compatibleHypervisors().isEmpty)
    }

    @Test("Status response reports progress from a downloading Firecracker artifact")
    func statusReportsActiveDownload() {
        let kernel = artifact(.kernel, arch: .arm64)
        let rootfs = artifact(
            .rootfs, arch: .arm64, format: .raw, status: .downloading, progress: 37)
        let image = makeImage(
            architecture: .arm64, status: .downloading, artifacts: [kernel, rootfs])

        let response = ImageStatusResponse(from: image)

        #expect(response.downloadProgress == 37)
        #expect(response.errorMessage == nil)
    }

    @Test("Image response reports progress from a downloading Firecracker artifact")
    func imageResponseReportsActiveDownload() {
        let kernel = artifact(.kernel, arch: .arm64, status: .downloading, progress: 42)
        let image = makeImage(
            architecture: .arm64, status: .downloading, artifacts: [kernel])

        let response = ImageResponse(from: image)

        #expect(response.downloadProgress == 42)
        #expect(response.errorMessage == nil)
    }

    @Test("Status response reports an error from a failed Firecracker artifact")
    func statusReportsActiveError() {
        let kernel = artifact(
            .kernel, arch: .arm64, status: .error, error: "kernel import failed")
        let image = makeImage(architecture: .arm64, status: .error, artifacts: [kernel])

        let response = ImageStatusResponse(from: image)

        #expect(response.errorMessage == "kernel import failed")
        #expect(response.downloadProgress == nil)
    }

    @Test("Image response reports an error from a failed Firecracker artifact")
    func imageResponseReportsActiveError() {
        let rootfs = artifact(
            .rootfs, arch: .arm64, format: .raw, status: .error,
            error: "rootfs import failed")
        let image = makeImage(architecture: .arm64, status: .error, artifacts: [rootfs])

        let response = ImageResponse(from: image)

        #expect(response.errorMessage == "rootfs import failed")
        #expect(response.downloadProgress == nil)
    }
}
