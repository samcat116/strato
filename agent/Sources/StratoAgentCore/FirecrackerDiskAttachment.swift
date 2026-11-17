import StratoShared

/// Resolves the host path Firecracker's drive API requires.
///
/// Firecracker has no native librbd driver. A future Ceph backend can map an
/// RBD image through krbd and return `.blockDevice`; passing `.rbd` directly is
/// an explicit error instead of treating its coordinates as a path.
public enum FirecrackerDiskAttachment {
    public enum Error: Swift.Error, Equatable {
        case nativeRBD
    }

    public static func hostPath(for attachment: DiskAttachment) throws -> String {
        switch attachment.value {
        case .file(let file):
            return file.path
        case .blockDevice(let device):
            return device.path
        case .none:
            throw AgentProtocolDecodeError.invalidField
        case .rbd:
            throw Error.nativeRBD
        }
    }
}
