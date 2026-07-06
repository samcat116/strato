import Foundation
import Logging

/// Generates guest-bootstrap media for VMs that boot from a disk image.
///
/// Guest bootstrap is a per-backend concern: QEMU disk-boot VMs consume a
/// cloud-init NoCloud ISO, whereas other backends (e.g. Firecracker) inject
/// configuration through kernel command-line args or the MMDS metadata service
/// rather than an attached ISO. Keeping this logic out of the hypervisor service
/// lets each driver opt into the provisioning mechanism it actually needs.
public struct CloudInitProvisioner {
    let logger: Logger

    public init(logger: Logger) {
        self.logger = logger
    }

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
    ///   - networkAttachments: The VM's resolved NICs; ones carrying a static
    ///     IP allocation are configured in the guest via a NoCloud
    ///     `network-config` (v2). User-mode NICs are left on DHCP.
    /// - Returns: true if the ISO was created successfully.
    public func makeNoCloudISO(
        at isoPath: String, vmId: String, networkAttachments: [ResolvedNetworkAttachment] = []
    ) async -> Bool {
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

            // Static NIC addressing, when the control plane allocated it.
            if let networkConfig = Self.networkConfigYAML(for: networkAttachments) {
                let networkConfigPath = (tempDir as NSString).appendingPathComponent("network-config")
                try networkConfig.write(toFile: networkConfigPath, atomically: true, encoding: .utf8)
            }

            // Create ISO using hdiutil (macOS) or genisoimage/mkisofs (Linux)
            let executableURL: URL
            let arguments: [String]
            #if os(macOS)
            executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
            arguments = [
                "makehybrid",
                "-iso",
                "-joliet",
                "-o", isoPath,
                "-default-volume-name", "cidata",
                tempDir,
            ]
            #else
            // Try genisoimage first, then mkisofs
            let genisoimagePath = "/usr/bin/genisoimage"
            let mkisofsPath = "/usr/bin/mkisofs"
            executableURL = URL(
                fileURLWithPath:
                    fileManager.fileExists(atPath: genisoimagePath) ? genisoimagePath : mkisofsPath)
            arguments = [
                "-output", isoPath,
                "-volid", "cidata",
                "-joliet",
                "-rock",
                tempDir,
            ]
            #endif

            let result = try await ProcessRunner.run(executableURL: executableURL, arguments: arguments)

            // Clean up temp directory
            try? fileManager.removeItem(atPath: tempDir)

            if result.terminationStatus == 0 {
                logger.debug("Created cloud-init ISO at: \(isoPath)")
                return true
            } else {
                logger.warning("Failed to create cloud-init ISO: \(result.combinedOutput)")
                return false
            }
        } catch {
            logger.warning("Failed to create cloud-init ISO: \(error.localizedDescription)")
            try? fileManager.removeItem(atPath: tempDir)
            return false
        }
    }

    /// Renders a NoCloud `network-config` (version 2) that statically configures
    /// every NIC carrying a control-plane IP allocation, matched by MAC address.
    ///
    /// Returns nil when no NIC has a static allocation — in that case no
    /// `network-config` is written and the guest keeps its default behavior
    /// (DHCP), which is also what user-mode (SLIRP) NICs need.
    public static func networkConfigYAML(for attachments: [ResolvedNetworkAttachment]) -> String? {
        var sections: [String] = []

        for (index, nic) in attachments.enumerated() {
            // User-mode NICs are addressed by SLIRP's built-in DHCP.
            guard case .tap = nic.attachment else { continue }
            guard let macAddress = nic.macAddress,
                let ipAddress = nic.ipAddress,
                let prefix = nic.netmask.flatMap({ IPv4Address($0)?.prefixLength })
            else { continue }

            var section = """
                  nic\(index):
                    match:
                      macaddress: "\(macAddress)"
                    set-name: nic\(index)
                    addresses:
                      - \(ipAddress)/\(prefix)
                """
            if let gateway = nic.gateway {
                section += "\n    gateway4: \(gateway)"
            }
            if let mtu = nic.mtu {
                section += "\n    mtu: \(mtu)"
            }
            sections.append(section)
        }

        guard !sections.isEmpty else { return nil }

        return """
            version: 2
            ethernets:
            \(sections.joined(separator: "\n"))
            """
    }
}
