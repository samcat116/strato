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
        switch attachment {
        case .file(let path, _), .blockDevice(let path):
            return path
        case .rbd:
            throw Error.nativeRBD
        }
    }
}
