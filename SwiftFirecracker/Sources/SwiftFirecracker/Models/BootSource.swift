import Foundation

/// Boot source configuration for direct kernel boot
/// Maps to PUT /boot-source API endpoint
public struct BootSource: Codable, Sendable {
    /// Path to the kernel image (vmlinux format, uncompressed)
    let kernelImagePath: String

    /// Path to the initramfs (optional)
    let initrdPath: String?

    /// Kernel command line arguments
    let bootArgs: String?

    enum CodingKeys: String, CodingKey {
        case kernelImagePath = "kernel_image_path"
        case initrdPath = "initrd_path"
        case bootArgs = "boot_args"
    }

    public init(
        kernelImagePath: String,
        initrdPath: String? = nil,
        bootArgs: String? = nil
    ) {
        self.kernelImagePath = kernelImagePath
        self.initrdPath = initrdPath
        self.bootArgs = bootArgs
    }
}
