import Foundation
import StratoShared
import Testing

@testable import StratoAgentCore

private struct StaticFirecrackerImageSource: ImageSource {
    let kernelPath: String
    let initramfsPath: String

    func localImagePath(for imageInfo: ImageInfo, kind: ArtifactKind) async throws -> String {
        switch kind {
        case .kernel:
            return kernelPath
        case .initramfs:
            return initramfsPath
        case .diskImage, .rootfs:
            Issue.record("Unexpected Firecracker boot artifact request: \(kind)")
            return ""
        }
    }
}

@Suite("Firecracker boot artifact resolver")
struct FirecrackerBootArtifactResolverTests {
    @Test("Image-backed disk boot requires image info before VMM replacement")
    func diskBootWithoutImageInfoIsRejected() async throws {
        let spec = VMSpec(cpus: 1, memoryBytes: 1 << 30, boot: .disk(firmware: nil))

        let error = await #expect(throws: HypervisorServiceError.self) {
            _ = try await FirecrackerBootArtifactResolver.resolve(
                spec: spec, imageInfo: nil, imageSource: nil)
        }

        let description = try #require(error?.errorDescription)
        #expect(description.contains("no kernel artifact or kernel path"))
    }

    @Test("Image artifacts replace direct-kernel paths as one resolved boot set")
    func imageArtifactsOverrideSpecPaths() async throws {
        let imageInfo = ImageInfo(
            imageId: UUID(), projectId: UUID(), architecture: .x86_64,
            artifacts: [
                ArtifactInfo(
                    kind: .kernel, filename: "vmlinux", checksum: "kernel", size: 1,
                    downloadURL: "/kernel"),
                ArtifactInfo(
                    kind: .initramfs, filename: "initrd", checksum: "initrd", size: 1,
                    downloadURL: "/initrd"),
                ArtifactInfo(
                    kind: .rootfs, filename: "rootfs", checksum: "rootfs", size: 1,
                    downloadURL: "/rootfs"),
            ])
        let source = StaticFirecrackerImageSource(
            kernelPath: "/cache/vmlinux", initramfsPath: "/cache/initrd")
        let spec = VMSpec(
            cpus: 1, memoryBytes: 1 << 30,
            boot: .directKernel(
                kernel: "/old/kernel", initramfs: "/old/initrd", cmdline: "console=ttyS0"))

        let resolved = try await FirecrackerBootArtifactResolver.resolve(
            spec: spec, imageInfo: imageInfo, imageSource: source)

        #expect(resolved.kernelPath == "/cache/vmlinux")
        #expect(resolved.initramfsPath == "/cache/initrd")
        #expect(resolved.cmdline == "console=ttyS0")
    }
}
