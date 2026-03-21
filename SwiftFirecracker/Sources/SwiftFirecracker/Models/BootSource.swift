import Foundation

/// Boot source configuration for direct kernel boot
/// Maps to PUT /boot-source API endpoint
public struct BootSource: Codable, Sendable {
    /// Path to the kernel image (vmlinux format, uncompressed)
    public let kernelImagePath: String

    /// Path to the initramfs (optional)
    public let initrdPath: String?

    /// Kernel command line arguments
    public let bootArgs: String?

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

    /// Creates a boot source with common kernel arguments for a root filesystem
    public static func withRootFS(
        kernelImagePath: String,
        initrdPath: String? = nil,
        rootDevice: String = "/dev/vda",
        consoleDevice: String = "ttyS0",
        additionalArgs: String? = nil
    ) -> BootSource {
        var args = "console=\(consoleDevice) reboot=k panic=1 pci=off root=\(rootDevice) rw"
        if let additional = additionalArgs {
            args += " \(additional)"
        }
        return BootSource(
            kernelImagePath: kernelImagePath,
            initrdPath: initrdPath,
            bootArgs: args
        )
    }
}
