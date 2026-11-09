import Foundation
import SwiftProtobuf

/// The role a single stored file plays inside an image's artifact set.
///
/// A QEMU workload boots from a single `diskImage`. A Firecracker workload is a
/// `kernel` + `rootfs` pair (with an optional `initramfs`) — there is no single
/// disk. Modeling artifacts by kind lets the agent fetch exactly the files a
/// given hypervisor driver needs and lets the control plane compute
/// per-hypervisor compatibility from the set of kinds present.
public typealias ArtifactKind = Strato_Agent_V1_ArtifactKind
extension Strato_Agent_V1_ArtifactKind: Codable {
    /// A bootable disk image (qcow2/raw). Consumed by QEMU; can also be attached
    /// as a Firecracker root drive.

    /// An uncompressed kernel image for direct kernel boot (Firecracker, or QEMU
    /// `-kernel`). Opaque blob, no disk format.

    /// An optional initial ramdisk paired with a `kernel`. Opaque blob.

    /// A root filesystem image attached as the boot drive under direct-kernel
    /// boot. Carries a disk format (raw/qcow2).

    /// Human-readable display name.
    public var displayName: String {
        switch self {
        case .diskImage:
            return "Disk Image"
        case .kernel:
            return "Kernel"
        case .initramfs:
            return "Initramfs"
        case .rootfs:
            return "Root Filesystem"
        case .unspecified, .UNRECOGNIZED:
            return "Unknown"
        }
    }

    public var protocolValue: String {
        switch self {
        case .diskImage: return "disk-image"
        case .kernel: return "kernel"
        case .initramfs: return "initramfs"
        case .rootfs: return "rootfs"
        case .unspecified, .UNRECOGNIZED: return ""
        }
    }

    public init?(rawValue: String) {
        switch rawValue {
        case "disk-image": self = .diskImage
        case "kernel": self = .kernel
        case "initramfs": self = .initramfs
        case "rootfs": self = .rootfs
        default: return nil
        }
    }

    public static var knownCases: [Self] { [.diskImage, .kernel, .initramfs, .rootfs] }

    public init(from decoder: any Swift.Decoder) throws {
        let container = try decoder.singleValueContainer()
        guard let value = Self(rawValue: try container.decode(String.self)) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unknown enum value")
        }
        self = value
    }

    public func encode(to encoder: any Swift.Encoder) throws {
        guard !protocolValue.isEmpty else {
            throw EncodingError.invalidValue(
                self, .init(codingPath: encoder.codingPath, debugDescription: "Unknown enum value"))
        }
        var container = encoder.singleValueContainer()
        try container.encode(protocolValue)
    }
}
