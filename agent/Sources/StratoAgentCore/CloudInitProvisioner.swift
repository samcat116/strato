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

    /// Password set on the guest image's default user for serial-console login.
    /// This is a development/test convenience for user-mode-networked VMs that
    /// have no reachable SSH endpoint; production access should use injected SSH
    /// keys over a routable network.
    static let defaultConsolePassword = "strato"

    public init(logger: Logger) {
        self.logger = logger
    }

    /// Creates a cloud-init NoCloud ISO at `isoPath` that configures the guest's
    /// serial console (GRUB + getty) so console streaming works without modifying
    /// the disk image.
    ///
    /// Login access is provisioned by authorizing the caller-supplied SSH public
    /// keys for the image's default user — never a hardcoded password.
    ///
    /// - Parameters:
    ///   - isoPath: Destination path for the generated ISO.
    ///   - vmId: The VM identifier, used for the instance-id and hostname.
    ///   - sshAuthorizedKeys: SSH public keys to authorize for the guest's
    ///     default user via cloud-init. Empty leaves the guest key-less.
    ///   - networkAttachments: The VM's resolved NICs; ones carrying a static
    ///     IP allocation are configured in the guest via a NoCloud
    ///     `network-config` (v2). User-mode NICs are left on DHCP.
    /// - Returns: true if the ISO was created successfully.
    public func makeNoCloudISO(
        at isoPath: String, vmId: String, sshAuthorizedKeys: [String] = [],
        networkAttachments: [ResolvedNetworkAttachment] = []
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
                # Console login: set a password on the image's default user so
                # the serial console — the only reachable login path on user-mode
                # (SLIRP) networking, which has no inbound route for SSH — is
                # usable. `expire: false` avoids a forced reset on first login.
                # Injected SSH keys (below) remain preferred once the VM is
                # network-reachable (OVN / port-forward).
                password: \(Self.defaultConsolePassword)
                chpasswd:
                  expire: false
                ssh_pwauth: true
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
            // Authorize the caller's SSH public keys for the image's default
            // user. `ssh_authorized_keys` at the cloud-config top level applies
            // to the default user, so no `users:` block is needed.
            var fullUserData = userData
            let keys =
                sshAuthorizedKeys
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            if !keys.isEmpty {
                let keyLines = keys.map { "  - \"\($0.replacingOccurrences(of: "\"", with: ""))\"" }
                    .joined(separator: "\n")
                fullUserData += "\n\nssh_authorized_keys:\n\(keyLines)\n"
            }

            let userDataPath = (tempDir as NSString).appendingPathComponent("user-data")
            try fullUserData.write(toFile: userDataPath, atomically: true, encoding: .utf8)

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

    /// Renders a NoCloud `network-config` (version 2), matched by MAC address:
    /// DHCP-managed NICs are set to `dhcp4: true` (OVN's responder delivers
    /// IP/gateway/DNS), and NICs with a control-plane static allocation get an
    /// explicit address/gateway/nameservers block.
    ///
    /// Returns nil when no NIC needs configuring — no `network-config` is written
    /// and the guest keeps its default behavior (DHCP), which is also what
    /// user-mode (SLIRP) NICs need.
    public static func networkConfigYAML(for attachments: [ResolvedNetworkAttachment]) -> String? {
        var sections: [String] = []

        for (index, nic) in attachments.enumerated() {
            // User-mode NICs are addressed by SLIRP's built-in DHCP.
            guard case .tap = nic.attachment else { continue }
            guard let macAddress = nic.macAddress else { continue }

            // Common header: match the NIC by MAC and give it a stable name.
            var section = """
                  nic\(index):
                    match:
                      macaddress: "\(macAddress)"
                    set-name: nic\(index)
                """

            // Dual-stack only when the control plane allocated a v6 address.
            // Every v6 line below is gated on this so v4-only NICs render
            // byte-identical config to pre-IPv6 agents.
            let hasIPv6 = nic.ip6Address != nil

            if nic.dhcpEnabled {
                // OVN's DHCP responder delivers IP, gateway, and DNS; just bring
                // the NIC up on DHCP so it sends a request. For v6, DHCPv6
                // assigns the address while the router's RAs deliver the
                // default route; the guest's link-local address must be EUI-64
                // (derived from the MAC) or OVN port_security — which lists
                // exactly that address — drops its NDP and DHCPv6 traffic.
                section += "\n    dhcp4: true"
                if hasIPv6 {
                    section += "\n    dhcp6: true"
                    section += "\n    accept-ra: true"
                    section += "\n    ipv6-address-generation: eui64"
                }
                sections.append(section)
                continue
            }

            // Static path: needs a control-plane IP + netmask. Skip NICs without
            // one (the guest keeps its default DHCP behavior).
            guard let ipAddress = nic.ipAddress,
                let prefix = nic.netmask.flatMap({ IPv4Address($0)?.prefixLength })
            else { continue }

            section += "\n    addresses:\n      - \(ipAddress)/\(prefix)"
            if let ip6Address = nic.ip6Address {
                section += "\n      - \(ip6Address)/\(nic.prefixLength6 ?? 64)"
            }
            if let gateway = nic.gateway {
                section += "\n    gateway4: \(gateway)"
            }
            if hasIPv6, let gateway6 = nic.gateway6 {
                section += "\n    gateway6: \(gateway6)"
            }
            if hasIPv6 {
                // Statically addressed, but RAs still refresh the on-link
                // prefix/route; EUI-64 link-locals keep port_security happy.
                section += "\n    accept-ra: true"
                section += "\n    ipv6-address-generation: eui64"
            }
            let dns = nic.dnsServers.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            if !dns.isEmpty {
                section += "\n    nameservers:\n      addresses: [\(dns.joined(separator: ", "))]"
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
