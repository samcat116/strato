import Testing
import Foundation
import StratoShared
@testable import App

@Suite("Image hypervisor compatibility")
struct ImageCompatibilityTests {

    private func makeImage(architecture: CPUArchitecture) -> Image {
        let image = Image(
            name: "img",
            description: "",
            projectID: UUID(),
            architecture: architecture,
            uploadedByID: UUID()
        )
        image.id = UUID()
        return image
    }

    private func artifact(
        _ kind: ArtifactKind, arch: CPUArchitecture, format: ImageFormat? = nil
    ) -> ImageArtifact {
        ImageArtifact(
            imageID: UUID(),
            kind: kind,
            format: format,
            architecture: arch,
            filename: kind.rawValue,
            size: 1,
            checksum: String(repeating: "c", count: 64),
            storagePath: "p"
        )
    }

    @Test("Disk image is QEMU-usable, not Firecracker-usable")
    func diskImageIsQemuOnly() {
        let image = makeImage(architecture: .x86_64)
        image.$artifacts.value = [artifact(.diskImage, arch: .x86_64, format: .qcow2)]

        #expect(image.compatibleHypervisors() == [.qemu])
        #expect(image.isUsable(by: .qemu))
        #expect(!image.isUsable(by: .firecracker))
    }

    @Test("Kernel + rootfs is Firecracker-usable")
    func kernelAndRootfsIsFirecracker() {
        let image = makeImage(architecture: .arm64)
        image.$artifacts.value = [
            artifact(.kernel, arch: .arm64),
            artifact(.rootfs, arch: .arm64, format: .raw),
        ]

        #expect(image.compatibleHypervisors() == [.firecracker])
        #expect(image.isUsable(by: .firecracker))
        #expect(!image.isUsable(by: .qemu))
    }

    @Test("A full artifact set is usable by both")
    func fullSetIsUsableByBoth() {
        let image = makeImage(architecture: .x86_64)
        image.$artifacts.value = [
            artifact(.diskImage, arch: .x86_64, format: .qcow2),
            artifact(.kernel, arch: .x86_64),
            artifact(.rootfs, arch: .x86_64, format: .raw),
        ]

        #expect(image.compatibleHypervisors() == [.qemu, .firecracker])
    }

    @Test("Architecture-mismatched artifacts don't count")
    func archMismatchExcluded() {
        let image = makeImage(architecture: .arm64)
        // Artifacts are x86_64 while the image is arm64 — nothing matches.
        image.$artifacts.value = [
            artifact(.kernel, arch: .x86_64),
            artifact(.rootfs, arch: .x86_64, format: .raw),
        ]

        #expect(image.compatibleHypervisors().isEmpty)
    }

    @Test("Kernel without rootfs is not Firecracker-usable")
    func kernelWithoutRootfs() {
        let image = makeImage(architecture: .x86_64)
        image.$artifacts.value = [artifact(.kernel, arch: .x86_64)]

        #expect(image.compatibleHypervisors().isEmpty)
    }

    @Test("No loaded artifacts means compatible with nothing")
    func noArtifacts() {
        let image = makeImage(architecture: .x86_64)
        image.$artifacts.value = []

        #expect(image.compatibleHypervisors().isEmpty)
    }

    @Test("Status response reports progress from a downloading Firecracker artifact")
    func statusReportsActiveDownload() {
        let image = makeImage(architecture: .arm64)
        image.status = .downloading
        let kernel = artifact(.kernel, arch: .arm64)
        let rootfs = artifact(.rootfs, arch: .arm64, format: .raw)
        rootfs.status = .downloading
        rootfs.downloadProgress = 37
        image.$artifacts.value = [kernel, rootfs]

        let response = ImageStatusResponse(from: image)

        #expect(response.downloadProgress == 37)
        #expect(response.errorMessage == nil)
    }

    @Test("Image response reports progress from a downloading Firecracker artifact")
    func imageResponseReportsActiveDownload() {
        let image = makeImage(architecture: .arm64)
        image.status = .downloading
        let kernel = artifact(.kernel, arch: .arm64)
        kernel.status = .downloading
        kernel.downloadProgress = 42
        image.$artifacts.value = [kernel]

        let response = ImageResponse(from: image)

        #expect(response.downloadProgress == 42)
        #expect(response.errorMessage == nil)
    }

    @Test("Status response reports an error from a failed Firecracker artifact")
    func statusReportsActiveError() {
        let image = makeImage(architecture: .arm64)
        image.status = .error
        let kernel = artifact(.kernel, arch: .arm64)
        kernel.status = .error
        kernel.errorMessage = "kernel import failed"
        image.$artifacts.value = [kernel]

        let response = ImageStatusResponse(from: image)

        #expect(response.errorMessage == "kernel import failed")
        #expect(response.downloadProgress == nil)
    }

    @Test("Image response reports an error from a failed Firecracker artifact")
    func imageResponseReportsActiveError() {
        let image = makeImage(architecture: .arm64)
        image.status = .error
        let rootfs = artifact(.rootfs, arch: .arm64, format: .raw)
        rootfs.status = .error
        rootfs.errorMessage = "rootfs import failed"
        image.$artifacts.value = [rootfs]

        let response = ImageResponse(from: image)

        #expect(response.errorMessage == "rootfs import failed")
        #expect(response.downloadProgress == nil)
    }
}
