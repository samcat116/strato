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
            filename: "disk.qcow2",
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
            checksum: "c",
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
}
