import Foundation
import Logging

/// Generates guest-bootstrap media for VMs that boot from a disk image.
///
/// Guest bootstrap is a per-backend concern: QEMU disk-boot VMs consume a
/// cloud-init NoCloud ISO, whereas other backends (e.g. Firecracker) inject
/// configuration through kernel command-line args or the MMDS metadata service
/// rather than an attached ISO. Keeping this logic out of the hypervisor service
/// lets each driver opt into the provisioning mechanism it actually needs.
struct CloudInitProvisioner {
    let logger: Logger

    /// Creates a cloud-init NoCloud ISO at `isoPath` that configures the guest's
    /// serial console (GRUB + getty) so console streaming works without modifying
    /// the disk image.
    ///
    /// No login credentials are provisioned here — access is expected to come
    /// from the base image or injected SSH keys, not a hardcoded password.
    ///
    /// - Parameters:
    ///   - isoPath: Destination path for the generated ISO.
    ///   - vmId: The VM identifier, used for the instance-id and hostname.
    /// - Returns: true if the ISO was created successfully.
    func makeNoCloudISO(at isoPath: String, vmId: String) -> Bool {
        let fileManager = FileManager.default
        let tempDir = (NSTemporaryDirectory() as NSString).appendingPathComponent("cloud-init-\(vmId)")

        // Clean up any existing temp directory
        try? fileManager.removeItem(atPath: tempDir)

        do {
            // Create temp directory structure
            try fileManager.createDirectory(atPath: tempDir, withIntermediateDirectories: true, attributes: nil)

            // Create meta-data file (required for NoCloud)
            let metaData = """
            instance-id: \(vmId)
            local-hostname: vm-\(vmId.prefix(8))
            """
            let metaDataPath = (tempDir as NSString).appendingPathComponent("meta-data")
            try metaData.write(toFile: metaDataPath, atomically: true, encoding: .utf8)

            // Create user-data file with serial console configuration
            let userData = """
            #cloud-config
            # Enable serial console output
            bootcmd:
              # Update GRUB to output to serial console
              - 'sed -i "s/GRUB_CMDLINE_LINUX_DEFAULT=.*/GRUB_CMDLINE_LINUX_DEFAULT=\\"console=tty0 console=ttyS0,115200 console=ttyAMA0,115200 console=hvc0\\"/" /etc/default/grub || true'
              - 'update-grub 2>/dev/null || grub2-mkconfig -o /boot/grub2/grub.cfg 2>/dev/null || true'

            # Enable getty on serial console
            runcmd:
              - systemctl enable --now serial-getty@ttyS0.service || true
              - systemctl enable --now serial-getty@ttyAMA0.service || true
              - systemctl enable --now serial-getty@hvc0.service || true
              # Emit a marker so we can verify console output quickly
              - "sh -c 'echo [cloud-init] console marker > /dev/ttyS0 2>/dev/null || true'"
              - "sh -c 'echo [cloud-init] console marker > /dev/ttyAMA0 2>/dev/null || true'"
              - "sh -c 'echo [cloud-init] console marker > /dev/hvc0 2>/dev/null || true'"
            """
            let userDataPath = (tempDir as NSString).appendingPathComponent("user-data")
            try userData.write(toFile: userDataPath, atomically: true, encoding: .utf8)

            // Create ISO using hdiutil (macOS) or genisoimage/mkisofs (Linux)
            let process = Process()
            #if os(macOS)
            process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
            process.arguments = [
                "makehybrid",
                "-iso",
                "-joliet",
                "-o", isoPath,
                "-default-volume-name", "cidata",
                tempDir
            ]
            #else
            // Try genisoimage first, then mkisofs
            let genisoimagePath = "/usr/bin/genisoimage"
            let mkisofsPath = "/usr/bin/mkisofs"
            if fileManager.fileExists(atPath: genisoimagePath) {
                process.executableURL = URL(fileURLWithPath: genisoimagePath)
            } else {
                process.executableURL = URL(fileURLWithPath: mkisofsPath)
            }
            process.arguments = [
                "-output", isoPath,
                "-volid", "cidata",
                "-joliet",
                "-rock",
                tempDir
            ]
            #endif

            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe

            try process.run()
            process.waitUntilExit()

            // Clean up temp directory
            try? fileManager.removeItem(atPath: tempDir)

            if process.terminationStatus == 0 {
                logger.debug("Created cloud-init ISO at: \(isoPath)")
                return true
            } else {
                let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                logger.warning("Failed to create cloud-init ISO: \(output)")
                return false
            }
        } catch {
            logger.warning("Failed to create cloud-init ISO: \(error.localizedDescription)")
            try? fileManager.removeItem(atPath: tempDir)
            return false
        }
    }
}
