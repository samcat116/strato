import Foundation

/// The role a single stored file plays inside an image's artifact set.
///
/// A QEMU workload boots from a single `diskImage`. A Firecracker workload is a
/// `kernel` + `rootfs` pair (with an optional `initramfs`) — there is no single
/// disk. Modeling artifacts by kind lets the agent fetch exactly the files a
/// given hypervisor driver needs and lets the control plane compute
/// per-hypervisor compatibility from the set of kinds present.
public enum ArtifactKind: String, Codable, CaseIterable, Sendable {
    /// A bootable disk image (qcow2/raw). Consumed by QEMU; can also be attached
    /// as a Firecracker root drive.
    case diskImage = "disk-image"

    /// An uncompressed kernel image for direct kernel boot (Firecracker, or QEMU
    /// `-kernel`). Opaque blob, no disk format.
    case kernel

    /// An optional initial ramdisk paired with a `kernel`. Opaque blob.
    case initramfs

    /// A root filesystem image attached as the boot drive under direct-kernel
    /// boot. Carries a disk format (raw/qcow2).
    case rootfs

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
        }
    }
}
