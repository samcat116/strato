import Foundation
import Logging
import StratoShared

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
    ///   - userData: Caller-supplied cloud-init user data, verbatim (any
    ///     format cloud-init dispatches on). Combined with Strato's own
    ///     provisioning config into a MIME multipart document; a caller
    ///     payload that is itself a full MIME document is used as the seed's
    ///     `user-data` unchanged, replacing Strato's config entirely.
    ///   - networkAttachments: The VM's resolved NICs; ones carrying a static
    ///     IP allocation are configured in the guest via a NoCloud
    ///     `network-config` (v2). User-mode NICs are left on DHCP.
    /// - Returns: true if the ISO was created successfully.
    public func makeNoCloudISO(
        at isoPath: String, vmId: String, sshAuthorizedKeys: [String] = [],
        userData: String? = nil,
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

            // Create the user-data file: Strato's provisioning config, combined
            // with caller-supplied user data when the VM carries any.
            if let userData, CloudInitUserDataFormat.detect(userData) == nil {
                logger.warning(
                    "VM user data has no recognizable cloud-init header; embedding as text/plain (the guest will ignore it)"
                )
            }
            if let userData, CloudInitUserDataFormat.detect(userData) == .mime {
                logger.info(
                    "VM user data is a caller-composed MIME document; using it verbatim (Strato console/SSH provisioning skipped)"
                )
            }
            let fullUserData = Self.userDataDocument(sshAuthorizedKeys: sshAuthorizedKeys, userData: userData)

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

    // MARK: - User-data document assembly

    /// Builds the NoCloud `user-data` document.
    ///
    /// - No caller payload: a single `#cloud-config` carrying Strato's
    ///   provisioning (console password, serial-console setup, SSH keys) —
    ///   byte-identical to what pre-user-data agents wrote.
    /// - Caller payload present: a MIME multipart document. The caller's part
    ///   comes LAST — cloud-init's `CloudConfigPartHandler` merges parts with
    ///   the default `dict(replace)+list()+str()` policy, replacing keys of
    ///   prior parts, so on key conflicts the caller's value wins and Strato's
    ///   config acts as defaults (e.g. `ssh_pwauth: false` in caller config
    ///   disables the console-password convenience). Strato's console setup
    ///   travels as a shell-script part (not `bootcmd`/`runcmd`) so those keys
    ///   in caller-supplied cloud-config can never replace — and silently
    ///   drop — the console setup.
    /// - Caller payload is itself a complete MIME document: used verbatim
    ///   (a MIME message cannot be nested as a plain part), replacing Strato's
    ///   provisioning entirely. Documented escape hatch for full control.
    public static func userDataDocument(sshAuthorizedKeys: [String], userData: String?) -> String {
        let keys =
            sshAuthorizedKeys
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard let userData, !userData.isEmpty else {
            return legacyCloudConfig(authorizedKeys: keys)
        }

        let format = CloudInitUserDataFormat.detect(userData)
        if format == .mime {
            return userData
        }

        let parts: [MIMEPart] = [
            MIMEPart(
                mimeType: "text/cloud-config",
                filename: "strato-provisioning.cfg",
                content: systemCloudConfig(authorizedKeys: keys)
            ),
            // Ahead of the caller's part also by filename ("s…" < "u…"), so
            // the console is usable before a long caller script finishes.
            MIMEPart(
                mimeType: "text/x-shellscript",
                filename: "strato-console-setup.sh",
                content: consoleSetupScript
            ),
            // qga install as a script part, not a `packages:` key: a caller
            // cloud-config's own `packages:` list would replace ours under
            // cloud-init's dict(replace)+list() merge, silently dropping the
            // guest agent. A script part always composes (see `qgaSetupScript`).
            MIMEPart(
                mimeType: "text/x-shellscript",
                filename: "strato-qga-setup.sh",
                content: qgaSetupScript
            ),
            // Unrecognized payloads (only reachable when something bypassed the
            // control plane's validation) travel as text/plain: cloud-init
            // ignores them with a logged warning instead of misinterpreting.
            MIMEPart(
                mimeType: format?.mimeType ?? "text/plain",
                filename: "user-data",
                content: userData
            ),
        ]
        return multipartDocument(parts: parts)
    }

    /// A part of a multipart `user-data` document.
    struct MIMEPart {
        let mimeType: String
        let filename: String
        let content: String
    }

    /// Renders a `multipart/mixed` MIME document. The boundary is extended
    /// until it collides with no part's content, so arbitrary caller payloads
    /// can never terminate a part early.
    static func multipartDocument(parts: [MIMEPart]) -> String {
        var boundary = "strato-cloud-init-boundary"
        while parts.contains(where: { $0.content.contains(boundary) }) {
            boundary += "-x"
        }

        var lines: [String] = [
            "Content-Type: multipart/mixed; boundary=\"\(boundary)\"",
            "MIME-Version: 1.0",
            "",
        ]
        for part in parts {
            lines.append("--\(boundary)")
            lines.append("Content-Type: \(part.mimeType); charset=\"utf-8\"")
            lines.append("MIME-Version: 1.0")
            lines.append("Content-Disposition: attachment; filename=\"\(part.filename)\"")
            lines.append("")
            // The newline before the next boundary belongs to the delimiter,
            // so drop the content's own trailing one to avoid a stray blank
            // line inside the part body.
            lines.append(part.content.hasSuffix("\n") ? String(part.content.dropLast()) : part.content)
        }
        lines.append("--\(boundary)--")
        return lines.joined(separator: "\n") + "\n"
    }

    /// The single-document `#cloud-config` used when the caller supplied no
    /// user data. Extends the pre-user-data agent output with the QEMU guest
    /// agent (issue #563); with no caller part to merge against, cloud-init's
    /// native `packages:` install and a `runcmd` service-enable are safe here
    /// (the multipart path can't use them — see `qgaSetupScript`).
    static func legacyCloudConfig(authorizedKeys keys: [String]) -> String {
        var document = """
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
            # Install the QEMU guest agent so the host can do verified shutdown,
            # fs-freeze snapshots, and guest IP reporting. Most cloud images
            # already ship it; this covers those that don't.
            packages:
              - qemu-guest-agent
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
              # Start the guest agent (installed above) without a reboot.
              - systemctl enable --now qemu-guest-agent 2>/dev/null || systemctl enable --now qemu-ga 2>/dev/null || true
              # Emit a marker so we can verify console output quickly
              - "sh -c 'echo [cloud-init] console marker > /dev/ttyS0 2>/dev/null || true'"
              - "sh -c 'echo [cloud-init] console marker > /dev/ttyAMA0 2>/dev/null || true'"
              - "sh -c 'echo [cloud-init] console marker > /dev/hvc0 2>/dev/null || true'"
            """
        document += sshAuthorizedKeysBlock(keys)
        return document
    }

    /// Strato's provisioning defaults as a standalone cloud-config, used as
    /// the FIRST part of a multipart document so the caller's later part
    /// replaces any conflicting key (cloud-init's default part merge is
    /// `dict(replace)+list()+str()`). Deliberately free of `bootcmd`/`runcmd`
    /// (console setup travels as a script part instead): those list keys in
    /// a caller part would replace — and silently drop — ours.
    static func systemCloudConfig(authorizedKeys keys: [String]) -> String {
        var document = """
            #cloud-config
            # Strato guest-provisioning defaults. Caller-supplied user data is a
            # later part of this document and wins on conflicting keys.
            password: \(Self.defaultConsolePassword)
            chpasswd:
              expire: false
            ssh_pwauth: true
            """
        document += sshAuthorizedKeysBlock(keys)
        return document
    }

    /// Authorizes keys for the image's default user. `ssh_authorized_keys` at
    /// the cloud-config top level applies to the default user, so no `users:`
    /// block is needed. Empty keys render nothing.
    private static func sshAuthorizedKeysBlock(_ keys: [String]) -> String {
        guard !keys.isEmpty else { return "" }
        // An SSH public key is a single line. Control characters are dropped,
        // and the two characters YAML gives meaning inside a double-quoted
        // scalar are escaped rather than deleted: `\` opens an escape sequence
        // (so a literal `\n` in a key value would otherwise decode to a newline
        // in the guest's authorized_keys) and `"` closes the scalar. Order
        // matters — backslashes first, or the escapes we add get re-escaped.
        let keyLines =
            keys.map { key -> String in
                let sanitized = String(key.unicodeScalars.filter { $0.value >= 0x20 && $0.value != 0x7f })
                    .replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "\"", with: "\\\"")
                return "  - \"\(sanitized)\""
            }
            .joined(separator: "\n")
        return "\n\nssh_authorized_keys:\n\(keyLines)\n"
    }

    /// Serial-console setup (GRUB output + getty) as a shell script, run by
    /// cloud-init's scripts-user stage. Same commands as the legacy
    /// `bootcmd`/`runcmd`, in script form so it composes with any
    /// caller-supplied cloud-config (see `systemCloudConfig`). GRUB edits only
    /// matter for subsequent boots, so running at scripts-user time (instead
    /// of bootcmd's early hook) changes nothing observable.
    static let consoleSetupScript = """
        #!/bin/sh
        # Strato serial-console setup: route GRUB/kernel output to the serial
        # console and enable a login getty there, so console streaming works
        # without modifying the disk image.
        sed -i "s/GRUB_CMDLINE_LINUX_DEFAULT=.*/GRUB_CMDLINE_LINUX_DEFAULT=\\"console=tty0 console=ttyS0,115200 console=ttyAMA0,115200 console=hvc0\\"/" /etc/default/grub || true
        update-grub 2>/dev/null || grub2-mkconfig -o /boot/grub2/grub.cfg 2>/dev/null || true
        systemctl enable --now serial-getty@ttyS0.service || true
        systemctl enable --now serial-getty@ttyAMA0.service || true
        systemctl enable --now serial-getty@hvc0.service || true
        # Emit a marker so we can verify console output quickly
        echo '[cloud-init] console marker' > /dev/ttyS0 2>/dev/null || true
        echo '[cloud-init] console marker' > /dev/ttyAMA0 2>/dev/null || true
        echo '[cloud-init] console marker' > /dev/hvc0 2>/dev/null || true
        """

    /// Installs and enables the QEMU guest agent as a shell script, run by
    /// cloud-init's scripts-user stage. Used only in the multipart (caller)
    /// path, where a `packages:` key would be clobbered by a caller's own list
    /// (see `systemCloudConfig`); the no-caller path installs it natively via
    /// `packages:` (see `legacyCloudConfig`). Best-effort across package
    /// managers and service names, and quiet on images that already ship it.
    static let qgaSetupScript = """
        #!/bin/sh
        # Strato guest-agent setup: install the QEMU guest agent so the host can
        # do verified shutdown, fs-freeze snapshots, and guest IP reporting
        # (issue #563). Most cloud images already ship it; this covers those
        # that don't, without requiring image changes.
        if command -v apt-get >/dev/null 2>&1; then
            apt-get update -y >/dev/null 2>&1 || true
            apt-get install -y qemu-guest-agent >/dev/null 2>&1 || true
        elif command -v dnf >/dev/null 2>&1; then
            dnf install -y qemu-guest-agent >/dev/null 2>&1 || true
        elif command -v yum >/dev/null 2>&1; then
            yum install -y qemu-guest-agent >/dev/null 2>&1 || true
        elif command -v apk >/dev/null 2>&1; then
            apk add --no-cache qemu-guest-agent >/dev/null 2>&1 || true
        fi
        # Service name differs across distros (qemu-guest-agent vs qemu-ga).
        systemctl enable --now qemu-guest-agent 2>/dev/null \
            || systemctl enable --now qemu-ga 2>/dev/null || true
        """

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
