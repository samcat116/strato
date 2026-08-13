import Foundation
import StratoShared

/// The host-local artifacts Firecracker needs before it can configure a boot
/// source. Resolving this value may download image artifacts, so replacement
/// paths do it before quiescing a guest whose existing VMM is still healthy.
public struct FirecrackerBootArtifacts: Equatable, Sendable {
    public let kernelPath: String
    public let initramfsPath: String?
    public let cmdline: String?

    public init(kernelPath: String, initramfsPath: String?, cmdline: String?) {
        self.kernelPath = kernelPath
        self.initramfsPath = initramfsPath
        self.cmdline = cmdline
    }
}

/// Resolves Firecracker's direct-kernel boot contract without touching a VMM.
/// Keeping this decision in the testable core lets lifecycle code prove all
/// replacement boot artifacts exist before it sends the old guest a shutdown.
public enum FirecrackerBootArtifactResolver {
    public static func resolve(
        spec: VMSpec, imageInfo: ImageInfo?, imageSource: (any ImageSource)?
    ) async throws -> FirecrackerBootArtifacts {
        var kernelPath: String?
        var initramfsPath: String?
        var cmdline: String?
        if case .directKernel(let specKernel, let specInitramfs, let specCmdline) = spec.boot {
            kernelPath = specKernel.isEmpty ? nil : specKernel
            initramfsPath = specInitramfs
            cmdline = specCmdline
        }

        if let imageInfo {
            guard let imageSource else {
                throw HypervisorServiceError.invalidConfiguration(
                    "Firecracker cannot realize typed kernel artifacts without an image-source service")
            }
            guard imageInfo.artifact(ofKind: .kernel) != nil else {
                throw HypervisorServiceError.invalidConfiguration(
                    "Firecracker image \(imageInfo.imageId) has no kernel artifact")
            }
            guard imageInfo.artifact(ofKind: .rootfs) != nil else {
                throw HypervisorServiceError.invalidConfiguration(
                    "Firecracker image \(imageInfo.imageId) has no rootfs artifact")
            }

            // An image that supplies its own kernel fully owns direct-kernel
            // boot. Never pair it with a stale initramfs from the VM spec.
            kernelPath = try await imageSource.localImagePath(for: imageInfo, kind: .kernel)
            if imageInfo.artifact(ofKind: .initramfs) != nil {
                initramfsPath = try await imageSource.localImagePath(
                    for: imageInfo, kind: .initramfs)
            } else {
                initramfsPath = nil
            }
        }

        guard let kernelPath, !kernelPath.isEmpty else {
            throw HypervisorServiceError.invalidConfiguration(
                "Firecracker requires direct kernel boot - no kernel artifact or kernel path available")
        }
        return FirecrackerBootArtifacts(
            kernelPath: kernelPath, initramfsPath: initramfsPath, cmdline: cmdline)
    }
}
