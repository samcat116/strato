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
    ///   - vmId: The VM identifier, used for the instance-id (and, absent a
    ///     hostname, for the derived `local-hostname` — see `metaDataDocument`).
    ///   - hostname: The VM's desired hostname, from
    ///     `InstanceMetadata.hostname`. Nil for VMs that have none.
    ///   - sshAuthorizedKeys: SSH public keys to authorize for the guest's
    ///     default user via cloud-init. Empty leaves the guest key-less.
    ///   - userData: Caller-supplied cloud-init user data, verbatim (any
    ///     format cloud-init dispatches on). Combined with Strato's own
    ///     provisioning config into a MIME multipart document; a caller
    ///     payload that is itself a full MIME document is used as the seed's
    ///     `user-data` unchanged, replacing Strato's config entirely.
    ///   - metadataSource: Whether the ISO carries the complete NoCloud
    ///     documents or only a `seedfrom` stub plus local network bootstrap.
    ///   - noCloudSeedToken: The per-VM capability embedded in an IMDS-backed
    ///     seed URL. Required when `metadataSource` is `.imds`.
    ///   - networkAttachments: The VM's resolved NICs; ones carrying a static
    ///     IP allocation are configured in the guest via a NoCloud
    ///     `network-config` (v2). User-mode NICs are left on DHCP.
    /// - Returns: true if the ISO was created successfully.
    public func makeNoCloudISO(
        at isoPath: String, vmId: String, hostname: String? = nil, sshAuthorizedKeys: [String] = [],
        userData: String? = nil,
        metadataSource: MetadataSource = .iso,
        noCloudSeedToken: UUID? = nil,
        networkAttachments: [ResolvedNetworkAttachment] = []
    ) async -> Bool {
        let fileManager = FileManager.default
        let tempDir = (NSTemporaryDirectory() as NSString).appendingPathComponent("cloud-init-\(vmId)")

        // Clean up any existing temp directory
        try? fileManager.removeItem(atPath: tempDir)

        do {
            // Create temp directory structure
            try fileManager.createDirectory(atPath: tempDir, withIntermediateDirectories: true, attributes: nil)

            if metadataSource == .iso {
                // The warning fires on exactly the condition the full renderer
                // decided on. An IMDS seed contains no hostname to disagree
                // with: the live endpoint renders it after networking is up.
                let localHostname = Self.localHostname(vmId: vmId, hostname: hostname)
                if let hostname, hostname != localHostname {
                    logger.warning(
                        "Desired hostname is not a valid DNS label; booting under a derived name instead",
                        metadata: [
                            "strato.vm.id": .string(vmId),
                            "hostname": .string(hostname.debugDescription),
                            "localHostname": .string(localHostname),
                        ])
                }
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
            }

            let documents = try Self.seedDocuments(
                metadataSource: metadataSource,
                noCloudSeedToken: noCloudSeedToken,
                vmId: vmId,
                hostname: hostname,
                sshAuthorizedKeys: sshAuthorizedKeys,
                userData: userData,
                networkAttachments: networkAttachments)
            for (filename, contents) in documents.sorted(by: { $0.key < $1.key }) {
                let path = (tempDir as NSString).appendingPathComponent(filename)
                try contents.write(toFile: path, atomically: true, encoding: .utf8)
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

    // MARK: - Meta-data document assembly

    /// The exact files written to the NoCloud ISO.
    ///
    /// Network configuration stays local in both modes: a statically addressed
    /// guest needs it before it can reach the `seedfrom` URL. IMDS mode keeps
    /// the empty `user-data` file NoCloud requires for filesystem discovery
    /// and replaces the ordinary identity document with the small redirect
    /// stub; the live service owns the real payload.
    static func seedDocuments(
        metadataSource: MetadataSource,
        noCloudSeedToken: UUID? = nil,
        vmId: String,
        hostname: String?,
        sshAuthorizedKeys: [String],
        userData: String?,
        networkAttachments: [ResolvedNetworkAttachment]
    ) throws -> [String: String] {
        var documents: [String: String]
        switch metadataSource {
        case .iso:
            documents = [
                "meta-data": metaDataDocument(vmId: vmId, hostname: hostname),
                "user-data": userDataDocument(
                    sshAuthorizedKeys: sshAuthorizedKeys, userData: userData),
            ]
        case .imds:
            guard let noCloudSeedToken else {
                throw CloudInitProvisionerError.missingNoCloudSeedToken
            }
            documents = [
                "meta-data": seedFromMetaDataDocument(token: noCloudSeedToken),
                // NoCloud's filesystem seed probe requires both files even
                // though the real payload is fetched from `seedfrom`.
                "user-data": "",
            ]
        }

        // In IMDS mode this document is applied during init-local solely to
        // make seedfrom reachable. Leave the kernel name intact: by the time
        // NoCloudNet consumes the live document during init-network the device
        // is already active, and cloud-init cannot rename it without finishing
        // degraded. The live renderer follows the same rule below.
        if let networkConfig = networkConfigYAML(
            for: networkAttachments,
            renameInterfaces: metadataSource == .iso
        ) {
            documents["network-config"] = networkConfig
        }
        return documents
    }

    /// The local NoCloud seed's hand-off to the agent's live document tree.
    static func seedFromMetaDataDocument(token: UUID) -> String {
        "seedfrom: http://\(InstanceMetadataEndpoint.address)\(MetadataRouter.noCloudSeedPath(for: token))"
    }

    /// Renders the NoCloud `meta-data` document.
    ///
    /// `local-hostname` is the name the guest configures itself under, and it
    /// has to be the same label the control plane publishes for the VM: a zone's
    /// contents are derived from `VM.hostname` (see `docs/architecture/dns.md`),
    /// so a seed that invents its own name leaves forward and reverse DNS naming
    /// a host that does not answer to it — the drift `InstanceMetadata.hostname`
    /// is deliberately optional to avoid (STR-177).
    ///
    /// The `vm-<id-prefix>` derivation is reached only when the VM has no
    /// hostname at all, or when the one it has is not a legal label — see
    /// `localHostname`, which decides between the two.
    static func metaDataDocument(vmId: String, hostname: String?) -> String {
        """
        instance-id: \(vmId)
        local-hostname: \(localHostname(vmId: vmId, hostname: hostname))
        """
    }

    /// Renders the same NoCloud `meta-data` bytes from the mutable metadata
    /// snapshot served over HTTP.
    public static func metaDataDocument(for metadata: InstanceMetadata) -> String {
        metaDataDocument(vmId: metadata.instanceId.uuidString, hostname: metadata.hostname)
    }

    /// The label the guest configures itself under: the desired `hostname` when
    /// there is a usable one, and `vm-<id-prefix>` otherwise.
    ///
    /// Two distinct cases fall back, and only one of them is benign:
    ///
    /// - **No hostname.** VMs predating the column (issue #770) and control
    ///   planes predating `DesiredVMState.metadata` publish no name for the
    ///   guest to disagree with, and a guest still needs *some* hostname to boot
    ///   with, so the historical derivation stays exactly as it was.
    /// - **An unusable hostname.** Reaching this means a bug or a hostile
    ///   sender: a control plane that ran `DNSName.normalizedHostname` on write
    ///   cannot emit an invalid label. The VM boots anyway, under a name its
    ///   zone does not publish — knowingly re-introducing the very drift this
    ///   renderer exists to prevent, because the alternative is refusing to
    ///   create the VM at all, and a guest with a wrong name is more useful than
    ///   a guest that will not boot. The trade is only defensible because it is
    ///   loud: `makeNoCloudISO` warns, naming both labels.
    static func localHostname(vmId: String, hostname: String?) -> String {
        hostname.flatMap { isValidHostnameLabel($0) ? $0 : nil } ?? "vm-\(vmId.prefix(8))"
    }

    /// Whether `label` is a legal RFC 1123 host label: 1–63 characters of
    /// letters, digits, and hyphens, not starting or ending with a hyphen. This
    /// is the control plane's `DNSName.isValidLabel` rule, which every stored
    /// `VM.hostname` passed — except that uppercase is accepted here, since DNS
    /// comparison is case-insensitive and a differently-cased spelling still
    /// answers to the VM's records.
    ///
    /// Re-checked on this side rather than trusted because the value lands
    /// unquoted in a YAML document the guest configures itself from: a name
    /// carrying a newline or a colon would author *keys* in `meta-data` rather
    /// than fail, and the agent cannot see the validation the sender did.
    static func isValidHostnameLabel(_ label: String) -> Bool {
        DNSNameSyntax.isValidLabel(label)
    }

    /// `value` as a YAML double-quoted scalar, escaping what would otherwise end
    /// the scalar or restructure the document around it.
    ///
    /// The control plane validates the values that reach these documents, but
    /// rows written before a given validation landed keep whatever they hold
    /// (issue #876), and validation on write can only ever cover the sender the
    /// agent happens to be talking to. Quoting is what makes the renderer safe
    /// on its own terms: inside double quotes a `]`, `,`, or `#` is data rather
    /// than syntax, and the escapes below cover the three characters that still
    /// aren't — the quote and backslash that end or reinterpret the scalar, and
    /// the newline that would otherwise fold into whatever the next line's
    /// indentation makes of it.
    static func yamlQuoted(_ value: String) -> String {
        var escaped = ""
        for character in value {
            switch character {
            case "\\": escaped += "\\\\"
            case "\"": escaped += "\\\""
            case "\n": escaped += "\\n"
            case "\r": escaped += "\\r"
            case "\t": escaped += "\\t"
            default: escaped.append(character)
            }
        }
        return "\"\(escaped)\""
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
            // Hot-plug onlining, likewise a script part so a caller's
            // `write_files`/`runcmd` cannot replace it (issue #568).
            MIMEPart(
                mimeType: "text/x-shellscript",
                filename: "strato-hotplug-online.sh",
                content: hotplugOnlineScript
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

    /// Renders the same NoCloud `user-data` bytes from the mutable metadata
    /// snapshot served over HTTP.
    public static func userDataDocument(for metadata: InstanceMetadata) -> String {
        userDataDocument(
            sshAuthorizedKeys: metadata.sshAuthorizedKeys,
            userData: metadata.userData)
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
            # Install the QEMU guest agent so the host can do verified shutdown
            # and guest IP reporting. Most cloud images already ship it; this
            # covers those that don't.
            packages:
              - qemu-guest-agent
            # Bring hot-added vCPUs/memory online automatically (issue #568).
            # Modern distros ship equivalent udev rules; this covers older
            # images, and is harmless where they already exist.
            write_files:
              - path: /etc/udev/rules.d/80-strato-hotplug.rules
                content: |
                  SUBSYSTEM=="cpu", ACTION=="add", TEST=="online", ATTR{online}=="0", ATTR{online}="1"
                  SUBSYSTEM=="memory", ACTION=="add", TEST=="state", ATTR{state}=="offline", ATTR{state}="online"
            # Enable serial console output
            bootcmd:
              # Update GRUB to output to serial console
              - 'sed -i "s/GRUB_CMDLINE_LINUX_DEFAULT=.*/GRUB_CMDLINE_LINUX_DEFAULT=\\"console=tty0 console=ttyS0,115200 console=ttyAMA0,115200 console=hvc0\\"/" /etc/default/grub || true'
              - 'update-grub 2>/dev/null || grub2-mkconfig -o /boot/grub2/grub.cfg 2>/dev/null || true'

            # Enable getty on serial console
            runcmd:
              - '\(Self.serialGettySetupCommand)'
              # Start the guest agent (installed above) without a reboot.
              - systemctl enable --now qemu-guest-agent 2>/dev/null || systemctl enable --now qemu-ga 2>/dev/null || true
              # Apply the hot-plug rules now, and online anything already
              # offline (a resize that landed mid-boot) — issue #568.
              - udevadm control --reload-rules 2>/dev/null || true
              - "sh -c 'for c in /sys/devices/system/cpu/cpu[0-9]*/online; do echo 1 > $c 2>/dev/null || true; done'"
              - "sh -c 'for m in /sys/devices/system/memory/memory[0-9]*/state; do grep -q offline $m 2>/dev/null && echo online > $m 2>/dev/null || true; done'"
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
        \(Self.serialGettySetupCommand)
        # Emit a marker so we can verify console output quickly
        echo '[cloud-init] console marker' > /dev/ttyS0 2>/dev/null || true
        echo '[cloud-init] console marker' > /dev/ttyAMA0 2>/dev/null || true
        echo '[cloud-init] console marker' > /dev/hvc0 2>/dev/null || true
        """

    /// Starts a getty only for serial devices present in this guest. Calling
    /// `systemctl --now` for an absent architecture-specific device waits for
    /// systemd's device-job timeout before it fails.
    static let serialGettySetupCommand =
        #"for device in ttyS0 ttyAMA0 hvc0; do [ -c "/dev/$device" ] || continue; "#
        + #"systemctl enable --now "serial-getty@$device.service" || true; done"#

    /// Installs and enables the QEMU guest agent as a shell script, run by
    /// cloud-init's scripts-user stage. Used only in the multipart (caller)
    /// path, where a `packages:` key would be clobbered by a caller's own list
    /// (see `systemCloudConfig`); the no-caller path installs it natively via
    /// `packages:` (see `legacyCloudConfig`). Best-effort across package
    /// managers and service names, and quiet on images that already ship it.
    static let qgaSetupScript = """
        #!/bin/sh
        # Strato guest-agent setup: install the QEMU guest agent so the host can
        # do verified shutdown and guest IP reporting
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

    /// Guest-side onlining for hot-added vCPUs and memory (issue #568).
    ///
    /// Hot-plugged resources arrive *offline*: the host's `device_add` /
    /// virtio-mem request only makes them visible to the guest kernel, which
    /// then has to bring them up. systemd-udev ships rules that do this on
    /// modern distros, so this script is for the older images that don't —
    /// and it also onlines whatever is already offline at first boot, so a
    /// resize applied while the guest was still booting isn't missed.
    ///
    /// Written as a script part for the same reason as the console and qga
    /// setup: a caller cloud-config's own list keys can't replace it.
    static let hotplugOnlineScript = """
        #!/bin/sh
        # Strato CPU/memory hot-add support: bring hot-plugged resources online
        # automatically (issue #568). Modern distros already do this via
        # systemd's 40-redhat.rules / 80-hotplug-cpu-mem.rules; installing our
        # own rule is harmless where those exist (both just write "online").
        if [ -d /etc/udev/rules.d ]; then
            cat > /etc/udev/rules.d/80-strato-hotplug.rules <<'EOF'
        SUBSYSTEM=="cpu", ACTION=="add", TEST=="online", ATTR{online}=="0", ATTR{online}="1"
        SUBSYSTEM=="memory", ACTION=="add", TEST=="state", ATTR{state}=="offline", ATTR{state}="online"
        EOF
            udevadm control --reload-rules 2>/dev/null || true
        fi
        # Online anything already present but offline (e.g. a resize that
        # landed while the guest was booting, before the rule existed).
        for cpu in /sys/devices/system/cpu/cpu[0-9]*/online; do
            [ -f "$cpu" ] && echo 1 > "$cpu" 2>/dev/null || true
        done
        for mem in /sys/devices/system/memory/memory[0-9]*/state; do
            [ -f "$mem" ] && grep -q offline "$mem" 2>/dev/null && echo online > "$mem" 2>/dev/null || true
        done
        # Let the kernel place onlined blocks in the movable zone where it can,
        # so memory added by virtio-mem stays unpluggable later.
        [ -f /sys/devices/system/memory/auto_online_blocks ] \\
            && echo online_movable > /sys/devices/system/memory/auto_online_blocks 2>/dev/null || true
        exit 0
        """

    /// Renders a NoCloud `network-config` (version 2), matched by MAC address:
    /// DHCP-managed NICs are set to `dhcp4: true` (OVN's responder delivers
    /// IP/gateway/DNS/domain), and NICs with a control-plane static allocation
    /// get an explicit address/nameservers block, including the network's
    /// search domain. The first eligible static NIC per address family also
    /// owns its default gateway; later NICs keep only their connected routes.
    ///
    /// A NIC on a network publishing a link-local service — instance metadata,
    /// the network's DNS resolver, or both — also carries on-link routes to its
    /// addresses, and a resolver-enabled static NIC is pointed at the resolver
    /// instead of at the network's configured servers. See
    /// `linkLocalRoutesBlock`.
    ///
    /// Returns nil when no NIC needs configuring — no `network-config` is written
    /// and the guest keeps its default behavior (DHCP), which is also what
    /// user-mode (SLIRP) NICs need.
    public static func networkConfigYAML(
        for attachments: [ResolvedNetworkAttachment],
        renameInterfaces: Bool = true
    ) -> String? {
        var sections: [String] = []
        // Tracked per family, not per NIC: the two routes are delivered by
        // different mechanisms and a NIC can discharge one without the other.
        // A v4-only NIC — DHCP or static — settles v4 while leaving v6 for
        // whichever later NIC actually has an IPv6 address, and one flag for
        // both would let it swallow the claim and render nothing, costing the
        // VM the only v6 delivery path there is. See `linkLocalRoutesBlock`.
        //
        // Tracked per *service* as well as per family, because a VM's two NICs
        // may enable different ones: the NIC that discharges the metadata route
        // is not necessarily the one that discharges the resolver route.
        var metadataV4RouteClaimed = false
        var metadataV6RouteClaimed = false
        var resolverV4RouteClaimed = false
        var resolverV6RouteClaimed = false
        // A netplan document may carry only one unqualified default route per
        // address family. Multi-NIC creation keeps the request's stable device
        // order, so the first eligible static NIC is the deterministic primary
        // and later NICs retain their addresses without competing gateways.
        var defaultV4RouteClaimed = false
        var defaultV6RouteClaimed = false

        for (index, nic) in attachments.enumerated() {
            // User-mode NICs are addressed by SLIRP's built-in DHCP.
            guard case .tap = nic.attachment else { continue }
            guard let macAddress = nic.macAddress else { continue }

            // Common header: always match the NIC by MAC. Full ISO seeds also
            // give it a stable name; both IMDS documents deliberately retain
            // the kernel name because NoCloudNet applies after the device is
            // active (see `seedDocuments`).
            var section = """
                  nic\(index):
                    match:
                      macaddress: "\(macAddress)"
                """
            if renameInterfaces {
                section += "\n    set-name: nic\(index)"
            }

            // Dual-stack only when the control plane *allocated* a v6 address —
            // not when the guest merely has a usable one. Every v6 line below
            // is gated on this so v4-only NICs render byte-identical config to
            // pre-IPv6 agents. The two readings coincide today (IPAM allocates
            // on every dual-stack network), but on a SLAAC-addressed network
            // (none exist yet) this would read v4-only and silently withhold
            // the v6 metadata route.
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
                // v4 is settled without rendering anything: OVN's responder
                // hands this guest the same routes in DHCP option 121, which
                // reach every DHCP client rather than only the ones booting
                // from this seed. Claiming them stops a later static NIC from
                // writing a second route to the same destination.
                //
                // v6 has no such option, so the seed is the only way to deliver
                // it — and only a NIC with a v6 address can, since a route
                // needs a source address of the same family.
                if nic.metadataEnabled { metadataV4RouteClaimed = true }
                if !nic.resolverAddresses.isEmpty { resolverV4RouteClaimed = true }
                let dhcpMetadataV6 = nic.metadataEnabled && hasIPv6 && !metadataV6RouteClaimed
                let dhcpResolverV6 =
                    hasIPv6 && !resolverV6RouteClaimed
                    ? nic.resolverAddresses.first(where: { IPv6Address($0) != nil }) : nil
                metadataV6RouteClaimed = metadataV6RouteClaimed || dhcpMetadataV6
                resolverV6RouteClaimed = resolverV6RouteClaimed || (dhcpResolverV6 != nil)
                section += linkLocalRoutesBlock(
                    metadataIPv4: false, metadataIPv6: dhcpMetadataV6,
                    resolverIPv4: nil, resolverIPv6: dhcpResolverV6)
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
            if let gateway = nic.gateway, !defaultV4RouteClaimed {
                section += "\n    gateway4: \(gateway)"
                defaultV4RouteClaimed = true
            }
            if hasIPv6, let gateway6 = nic.gateway6, !defaultV6RouteClaimed {
                section += "\n    gateway6: \(gateway6)"
                defaultV6RouteClaimed = true
            }
            if hasIPv6 {
                // Statically addressed, but RAs still refresh the on-link
                // prefix/route; EUI-64 link-locals keep port_security happy.
                section += "\n    accept-ra: true"
                section += "\n    ipv6-address-generation: eui64"
            }
            // Filtered to addresses that parse, matching what `OVNDHCPOptionsBuilder`
            // does on the DHCP path: these land in the same kind of flow sequence
            // the search domain does, so anything that isn't an address is a
            // character that could end it. `validatedDNS` has enforced this on
            // write since the field's first release, so nothing reachable is
            // dropped here — the renderer just stops depending on that.
            // With the resolver on, the guest is pointed at it rather than at
            // the network's configured servers — which are the resolver's
            // upstreams, not the guest's (STR-40). This is the static
            // counterpart of the `dns_server` substitution
            // `OVNDHCPOptionsBuilder` makes, and it has to happen here too or a
            // statically addressed guest would resolve nothing internal while
            // its DHCP neighbours on the same network resolved everything.
            //
            // The v6 address is added only when the control plane allocated a
            // v6 address for this NIC: without one the guest has no valid
            // source address for a ULA destination, and an unreachable entry in
            // `resolv.conf` costs every lookup a timeout before the v4 fallback.
            let dns: [String]
            if !nic.resolverAddresses.isEmpty {
                // The network's own pair, filtered to families this NIC can
                // actually source from: without a global v6 address the guest
                // has no valid source for a ULA destination, and an unreachable
                // entry in `resolv.conf` costs every lookup a timeout before the
                // v4 fallback.
                dns = nic.resolverAddresses.filter { address in
                    IPv4Address(address) != nil || (hasIPv6 && IPv6Address(address) != nil)
                }
            } else {
                dns =
                    nic.dnsServers
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { IPv4Address($0) != nil || IPv6Address($0) != nil }
            }
            // The network's domain reaches DHCP guests as the OVN responder's
            // domain_name/domain_search option; static guests only get it here,
            // so unqualified lookups need this `search` list to behave the same.
            let searchDomain = nic.domainName
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .flatMap { $0.isEmpty ? nil : $0 }
            if !dns.isEmpty || searchDomain != nil {
                section += "\n    nameservers:"
                if let searchDomain {
                    section += "\n      search: [\(yamlQuoted(searchDomain))]"
                }
                if !dns.isEmpty {
                    section += "\n      addresses: [\(dns.joined(separator: ", "))]"
                }
            }
            if let mtu = nic.mtu {
                section += "\n    mtu: \(mtu)"
            }
            // No DHCP responder on this NIC, so the seed is what carries both
            // families' routes for both services — each claimed only for what
            // it actually renders, so a v4-only NIC leaves v6 to a later one.
            let staticMetadataV4 = nic.metadataEnabled && !metadataV4RouteClaimed
            let staticMetadataV6 = nic.metadataEnabled && hasIPv6 && !metadataV6RouteClaimed
            let staticResolverV4 =
                resolverV4RouteClaimed
                ? nil : nic.resolverAddresses.first(where: { IPv4Address($0) != nil })
            let staticResolverV6 =
                (hasIPv6 && !resolverV6RouteClaimed)
                ? nic.resolverAddresses.first(where: { IPv6Address($0) != nil }) : nil
            if nic.metadataEnabled {
                metadataV4RouteClaimed = true
                metadataV6RouteClaimed = metadataV6RouteClaimed || hasIPv6
            }
            if !nic.resolverAddresses.isEmpty {
                resolverV4RouteClaimed = true
                resolverV6RouteClaimed = resolverV6RouteClaimed || hasIPv6
            }
            section += linkLocalRoutesBlock(
                metadataIPv4: staticMetadataV4, metadataIPv6: staticMetadataV6,
                resolverIPv4: staticResolverV4, resolverIPv6: staticResolverV6)
            sections.append(section)
        }

        guard !sections.isEmpty else { return nil }

        return """
            version: 2
            ethernets:
            \(sections.joined(separator: "\n"))
            """
    }

    /// Renders the NoCloud-net `network-config` from the metadata snapshot.
    ///
    /// The IMDS bootstrap ISO and HTTP paths deliberately converge on the
    /// existing `ResolvedNetworkAttachment` renderer. Keeping one
    /// byte-producing path is what makes their parity a property of the
    /// implementation rather than two sets of examples that happen to agree
    /// today.
    public static func networkConfigYAML(for metadata: InstanceMetadata) -> String? {
        networkConfigYAML(
            for: metadata.nics.map { nic in
                ResolvedNetworkAttachment(
                    network: nic.networkName,
                    // A caller can reach this listener only over a realized
                    // network attachment. The control-plane snapshot has no
                    // host TAP name, and the renderer needs only the case.
                    attachment: .tap(interface: nic.deviceName),
                    macAddress: nic.macAddress,
                    ipAddress: nic.ipAddress,
                    netmask: dottedIPv4Netmask(prefixLength: nic.prefixLength),
                    gateway: nic.gateway,
                    ip6Address: nic.ipv6Address,
                    prefixLength6: nic.ipv6PrefixLength,
                    gateway6: nic.gateway6,
                    mtu: nic.mtu,
                    dhcpEnabled: nic.dhcpEnabled,
                    dnsServers: nic.dnsServers,
                    domainName: nic.domainName,
                    metadataEnabled: nic.metadataEnabled,
                    resolverAddresses: nic.resolverAddresses)
            },
            renameInterfaces: false)
    }

    private static func dottedIPv4Netmask(prefixLength: Int?) -> String? {
        guard let prefixLength, (0...32).contains(prefixLength) else { return nil }
        let mask: UInt32 = prefixLength == 0 ? 0 : ~UInt32(0) << (32 - prefixLength)
        return IPv4Address(raw: mask).description
    }

    /// The `routes:` block giving a guest on-link routes to the link-local
    /// service addresses its networks publish — instance metadata (STR-53) and
    /// the network's DNS resolver (STR-40).
    ///
    /// None of these addresses belongs to the network's subnets, so without
    /// this the guest has no path to the `localport` that terminates them
    /// (STR-49) — most Linux images carry a `169.254.0.0/16` link-local route
    /// that covers both v4 addresses by accident, but that is not universal and
    /// nothing covers the v6 ULAs.
    ///
    /// **One NIC per family carries them, within this document.** Two
    /// interfaces claiming the same destination is a duplicate route the guest
    /// resolves arbitrarily, so the first NIC that can discharge a family wins
    /// — the `eth0`-only rule AWS uses, generalized to "the first *eligible*
    /// NIC" because NIC 0 may be on a network with the service turned off, or
    /// be v4-only while a later NIC is dual-stack.
    ///
    /// This is a property of the seed, **not an invariant of the feature**.
    /// DHCP option 121 is authored on the *network's* `DHCP_Options` row and
    /// delivered to every DHCP client on that network, which nothing here
    /// arbitrates: a VM with NICs on two service-enabled DHCP networks
    /// receives the v4 routes on both, and the loser of the guest's route
    /// insert is whichever its client writes second. Harmless — either route
    /// reaches a namespace serving that same VM — but the claim below is not
    /// what makes it so.
    ///
    /// **Both routes carry an explicit zero next hop** rather than being
    /// written gateway-less, which is the more natural netplan spelling and the
    /// one this renderer would otherwise use. cloud-init's `eni` and
    /// `sysconfig` renderers — first and second in its renderer priority, so
    /// Debian/ifupdown and RHEL-family images reach them ahead of netplan and
    /// NetworkManager — index `route["gateway"]` unconditionally while
    /// converting network-config v2, and raise `KeyError` on a route that has
    /// none. That aborts the *entire* network render, leaving the guest with no
    /// configuration at all: a far worse failure than the missing metadata
    /// route it was meant to fix. A zero next hop is also exactly what RFC 3442
    /// encodes for the on-link route in DHCP option 121, so both halves of
    /// STR-53 say the same thing.
    ///
    /// Known gap: the v6 route reaches guests rendered by netplan/networkd and
    /// NetworkManager, but not by `eni`/`sysconfig` — those emit a literal
    /// `via ::`, which iproute2 rejects as an invalid gateway. Gateway-less
    /// would crash them outright (above) and a self-referential next hop needs
    /// an `onlink` flag that cloud-init's v2 conversion drops, so a no-op on
    /// those two renderers is the best available outcome.
    static func linkLocalRoutesBlock(
        metadataIPv4: Bool, metadataIPv6: Bool, resolverIPv4: String?, resolverIPv6: String?
    ) -> String {
        var block = ""
        // Metadata first, so a NIC that carries both renders the same bytes it
        // did before the resolver existed plus an appended pair — a diffable
        // seed rather than a reordered one.
        if metadataIPv4 { block += ipv4Route(to: InstanceMetadataEndpoint.cidr) }
        if metadataIPv6 { block += ipv6Route(to: InstanceMetadataEndpoint.cidrV6) }
        if let resolverIPv4 { block += ipv4Route(to: "\(resolverIPv4)/32") }
        if let resolverIPv6 { block += ipv6Route(to: "\(resolverIPv6)/128") }
        return block.isEmpty ? "" : "\n    routes:" + block
    }

    private static func ipv4Route(to destination: String) -> String {
        "\n      - to: \(destination)\n        via: 0.0.0.0"
    }

    private static func ipv6Route(to destination: String) -> String {
        // Quoted: `via: ::` is a YAML scanner error (a plain scalar may not
        // open with a `:` indicator), and an unparseable network-config costs
        // the guest every other setting in this document too.
        "\n      - to: \(destination)\n        via: \"::\""
    }
}

enum CloudInitProvisionerError: LocalizedError {
    case missingNoCloudSeedToken

    var errorDescription: String? {
        switch self {
        case .missingNoCloudSeedToken:
            return "an IMDS-backed NoCloud seed requires a bootstrap token"
        }
    }
}
