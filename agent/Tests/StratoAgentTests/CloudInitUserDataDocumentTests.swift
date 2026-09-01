import Foundation
import StratoShared
import Testing

@testable import StratoAgentCore

@Suite("Cloud-init user-data document assembly")
struct CloudInitUserDataDocumentTests {

    private static func metadata(keys: [String], userData: String?) -> InstanceMetadata {
        InstanceMetadata(
            instanceId: UUID(uuidString: "0F6AFCDE-2F3A-4F1C-B704-F8F9AAE2E17B")!,
            projectId: UUID(uuidString: "A9F5B93D-1BC2-4F14-9969-B5035713AD7C")!,
            sshAuthorizedKeys: keys,
            userData: userData,
            serviceEnabled: true)
    }

    private func runQGASetup(fakeCommands: [String: Int32]) throws -> (status: Int32, log: String) {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("strato-qga-setup-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: directory) }

        let logURL = directory.appendingPathComponent("commands.log")
        for (name, exitCode) in fakeCommands {
            let executable = directory.appendingPathComponent(name)
            let script = """
                #!/bin/sh
                printf '\(name) %s\\n' "$*" >> "$STRATO_QGA_TEST_LOG"
                exit \(exitCode)
                """
            try script.write(to: executable, atomically: true, encoding: .utf8)
            try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", CloudInitProvisioner.qgaSetupScript]
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = directory.path
        environment["STRATO_QGA_TEST_LOG"] = logURL.path
        process.environment = environment
        try process.run()
        process.waitUntilExit()

        let log = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
        return (process.terminationStatus, log)
    }

    @Test("NoCloud-net user-data is byte-identical to the seed ISO renderer")
    func noCloudNetGoldenParity() {
        let keys = ["  ssh-ed25519 AAAA key@host  ", "", "   "]
        let callerMIME = """
            Content-Type: multipart/mixed; boundary="callerboundary"
            MIME-Version: 1.0

            --callerboundary
            Content-Type: text/x-shellscript

            #!/bin/sh
            true
            --callerboundary--
            """
        let payloads: [String?] = [
            nil,
            "#cloud-config\nruncmd:\n  - echo strato-cloud-init-boundary\n",
            "#!/bin/sh\necho caller\n",
            callerMIME,
        ]

        for payload in payloads {
            let seedISO = CloudInitProvisioner.userDataDocument(
                sshAuthorizedKeys: keys, userData: payload)
            let noCloudNet = CloudInitProvisioner.userDataDocument(
                for: Self.metadata(keys: keys, userData: payload))
            #expect(noCloudNet.utf8.elementsEqual(seedISO.utf8))
        }
    }

    // MARK: - No caller payload (legacy single-document path)

    @Test("no user data renders the legacy single #cloud-config")
    func legacySingleDocument() {
        let doc = CloudInitProvisioner.userDataDocument(sshAuthorizedKeys: [], userData: nil)
        #expect(doc.hasPrefix("#cloud-config\n"))
        #expect(!doc.contains("multipart/mixed"))
        #expect(doc.contains("password: strato"))
        #expect(doc.contains("bootcmd:"))
        #expect(doc.contains("runcmd:"))
        #expect(doc.contains("ttyS0 ttyAMA0 hvc0"))
        #expect(doc.contains("serial-getty@$device.service"))
        #expect(!doc.contains("ssh_authorized_keys"))
    }

    @Test("default document keeps QGA installation best effort")
    func defaultGuestAgentInstallIsBestEffort() {
        let doc = CloudInitProvisioner.userDataDocument(sshAuthorizedKeys: [], userData: nil)

        // cloud-init treats a packages: failure as fatal to cloud-final. The
        // default path must use the same best-effort script policy as the
        // caller-user-data path instead.
        #expect(!doc.contains("packages:"))
        #expect(doc.contains("apt-get install -y qemu-guest-agent >/dev/null 2>&1 || true"))
        #expect(
            doc.contains(
                "zypper --non-interactive install --auto-agree-with-licenses qemu-guest-agent"))
        #expect(doc.contains("systemctl enable --now qemu-guest-agent"))
    }

    @Test("console setup starts gettys only for present character devices")
    func consoleSetupSkipsMissingDevices() {
        let guardedSetup =
            #"for device in ttyS0 ttyAMA0 hvc0; do [ -c "/dev/$device" ] || continue; systemctl enable --now "serial-getty@$device.service" || true; done"#
        let documents = [
            CloudInitProvisioner.userDataDocument(sshAuthorizedKeys: [], userData: nil),
            CloudInitProvisioner.userDataDocument(
                sshAuthorizedKeys: [], userData: "#!/bin/sh\ntrue\n"),
        ]

        for document in documents {
            #expect(document.contains(guardedSetup))
            #expect(!document.contains("systemctl enable --now serial-getty@ttyS0.service"))
            #expect(!document.contains("systemctl enable --now serial-getty@ttyAMA0.service"))
            #expect(!document.contains("systemctl enable --now serial-getty@hvc0.service"))
        }
    }

    @Test("QGA package and service failures do not fail setup")
    func guestAgentSetupSurvivesPackageFailure() throws {
        let result = try runQGASetup(fakeCommands: ["apt-get": 1, "systemctl": 1])

        #expect(result.status == 0)
        #expect(result.log.contains("apt-get update -y"))
        #expect(result.log.contains("apt-get install -y qemu-guest-agent"))
        #expect(result.log.contains("systemctl enable --now qemu-guest-agent"))
    }

    @Test("QGA setup skips package repositories when the image already contains QGA")
    func guestAgentSetupSkipsInstallWhenPresent() throws {
        let result = try runQGASetup(fakeCommands: [
            "qemu-ga": 0,
            "apt-get": 1,
            "systemctl": 0,
        ])

        #expect(result.status == 0)
        #expect(!result.log.contains("apt-get"))
        #expect(result.log.contains("systemctl enable --now qemu-guest-agent"))
    }

    @Test("QGA setup uses zypper when it is the available package manager")
    func guestAgentSetupUsesZypper() throws {
        let result = try runQGASetup(fakeCommands: ["zypper": 1, "systemctl": 1])

        #expect(result.status == 0)
        #expect(
            result.log.contains(
                "zypper --non-interactive install --auto-agree-with-licenses qemu-guest-agent"))
        #expect(result.log.contains("systemctl enable --now qemu-guest-agent"))
    }

    @Test("legacy document installs the hot-plug onlining udev rules")
    func legacyInstallsHotplugRules() {
        let doc = CloudInitProvisioner.userDataDocument(sshAuthorizedKeys: [], userData: nil)
        // Hot-added vCPUs/memory arrive offline; the guest has to bring them
        // up for a resize to be visible (issue #568).
        #expect(doc.contains("/etc/udev/rules.d/80-strato-hotplug.rules"))
        #expect(doc.contains(#"SUBSYSTEM=="cpu""#))
        #expect(doc.contains(#"SUBSYSTEM=="memory""#))
        #expect(doc.contains("udevadm control --reload-rules"))
    }

    @Test("legacy document authorizes trimmed, non-empty SSH keys")
    func legacyDocumentWithKeys() {
        let doc = CloudInitProvisioner.userDataDocument(
            sshAuthorizedKeys: ["  ssh-ed25519 AAAA key@host  ", "", "   "], userData: nil)
        #expect(doc.contains("ssh_authorized_keys:\n  - \"ssh-ed25519 AAAA key@host\""))
    }

    // MARK: - Caller payload → multipart

    @Test("cloud-config payload composes a multipart with the caller's part last")
    func multipartOrdering() {
        let payload = "#cloud-config\npackages:\n  - nginx\nruncmd:\n  - systemctl enable --now nginx\n"
        let doc = CloudInitProvisioner.userDataDocument(sshAuthorizedKeys: [], userData: payload)

        #expect(doc.hasPrefix("Content-Type: multipart/mixed; boundary="))
        #expect(doc.contains("packages:\n  - nginx"))

        // Caller part FOLLOWS Strato's parts: cloud-init's default part merge
        // (dict(replace)+list()+str()) replaces keys of prior parts, so the
        // caller part must come later to override provisioning defaults
        // (e.g. ssh_pwauth: false must actually disable password SSH auth).
        let userIndex = doc.range(of: "filename=\"user-data\"")?.lowerBound
        let systemIndex = doc.range(of: "filename=\"strato-provisioning.cfg\"")?.lowerBound
        let consoleIndex = doc.range(of: "filename=\"strato-console-setup.sh\"")?.lowerBound
        let qgaIndex = doc.range(of: "filename=\"strato-qga-setup.sh\"")?.lowerBound
        #expect(userIndex != nil && systemIndex != nil && consoleIndex != nil && qgaIndex != nil)
        if let userIndex, let systemIndex, let consoleIndex, let qgaIndex {
            #expect(systemIndex < consoleIndex)
            #expect(consoleIndex < qgaIndex)
            // All of Strato's parts precede the caller's, which merges last.
            #expect(qgaIndex < userIndex)
        }
    }

    @Test("qga install survives a caller that supplies its own packages: list")
    func multipartGuestAgentSurvivesCallerPackages() {
        // A caller cloud-config with its own packages: list would replace a
        // Strato `packages:` key under cloud-init's merge — so qga must ride in
        // as a script part instead, which always composes.
        let payload = "#cloud-config\npackages:\n  - nginx\n"
        let doc = CloudInitProvisioner.userDataDocument(sshAuthorizedKeys: [], userData: payload)

        // The qga install is a shell-script part, not a merged cloud-config key.
        #expect(doc.contains("filename=\"strato-qga-setup.sh\""))
        #expect(doc.contains("qemu-guest-agent"))
        #expect(doc.contains("systemctl enable --now qemu-guest-agent"))
        // Strato's own cloud-config part carries no packages: key that a caller
        // could clobber.
        #expect(!CloudInitProvisioner.systemCloudConfig(authorizedKeys: []).contains("packages"))
    }

    /// A caller cloud-config with its own `write_files`/`runcmd` would replace
    /// ours under cloud-init's list merge, so the onlining travels as a script
    /// part instead (issue #568).
    @Test("hot-plug onlining survives a caller that supplies its own write_files")
    func hotplugOnliningSurvivesCallerWriteFiles() {
        let payload = "#cloud-config\nwrite_files:\n  - path: /etc/motd\n    content: hi\n"
        let doc = CloudInitProvisioner.userDataDocument(sshAuthorizedKeys: [], userData: payload)
        #expect(doc.contains("filename=\"strato-hotplug-online.sh\""))
        #expect(doc.contains("80-strato-hotplug.rules"))
        // Strato's own cloud-config part carries no write_files to be replaced.
        #expect(doc.contains("/etc/motd"))
    }

    @Test("multipart labels the caller part with its detected content type")
    func multipartContentTypes() {
        let script = "#!/bin/bash\necho hello > /root/hello.txt\n"
        let doc = CloudInitProvisioner.userDataDocument(sshAuthorizedKeys: [], userData: script)
        #expect(doc.contains("Content-Type: text/x-shellscript; charset=\"utf-8\""))
        #expect(doc.contains("echo hello > /root/hello.txt"))

        let jinja = "## template: jinja\n#cloud-config\nhostname: {{ v1.local_hostname }}\n"
        let jinjaDoc = CloudInitProvisioner.userDataDocument(sshAuthorizedKeys: [], userData: jinja)
        #expect(jinjaDoc.contains("Content-Type: text/jinja2; charset=\"utf-8\""))
    }

    @Test("Strato's multipart cloud-config part avoids bootcmd/runcmd")
    func systemPartHasNoMergeConflictingKeys() {
        // Console setup must travel as a script part: cloud-init's default
        // part merge replaces colliding list keys instead of appending, so
        // bootcmd/runcmd in a caller part would silently drop Strato's.
        let payload = "#cloud-config\nruncmd:\n  - echo caller\n"
        let doc = CloudInitProvisioner.userDataDocument(sshAuthorizedKeys: [], userData: payload)

        let systemPart = CloudInitProvisioner.systemCloudConfig(authorizedKeys: [])
        #expect(!systemPart.contains("bootcmd"))
        #expect(!systemPart.contains("runcmd"))
        #expect(systemPart.contains("password: strato"))

        // The console setup still ships — as a shell script part.
        #expect(doc.contains("Content-Type: text/x-shellscript"))
        #expect(doc.contains("ttyS0 ttyAMA0 hvc0"))
        #expect(doc.contains("serial-getty@$device.service"))
    }

    @Test("multipart carries SSH keys in Strato's cloud-config part")
    func multipartCarriesSSHKeys() {
        let doc = CloudInitProvisioner.userDataDocument(
            sshAuthorizedKeys: ["ssh-ed25519 AAAA key@host"],
            userData: "#!/bin/sh\ntrue\n")
        #expect(doc.contains("ssh_authorized_keys:\n  - \"ssh-ed25519 AAAA key@host\""))
    }

    @Test("payload without a recognizable header is embedded as text/plain")
    func unknownPayloadEmbeddedInert() {
        let doc = CloudInitProvisioner.userDataDocument(
            sshAuthorizedKeys: [], userData: "echo missing shebang\n")
        #expect(doc.contains("Content-Type: text/plain; charset=\"utf-8\""))
        #expect(doc.contains("echo missing shebang"))
    }

    // MARK: - Caller-composed MIME passthrough

    @Test("a caller-composed MIME document is used verbatim")
    func mimePassthrough() {
        let mime = """
            Content-Type: multipart/mixed; boundary="callerboundary"
            MIME-Version: 1.0

            --callerboundary
            Content-Type: text/x-shellscript

            #!/bin/sh
            true
            --callerboundary--
            """
        let doc = CloudInitProvisioner.userDataDocument(
            sshAuthorizedKeys: ["ssh-ed25519 AAAA key@host"], userData: mime)
        #expect(doc == mime)
    }

    // MARK: - MIME framing

    @Test("boundary is extended until it no longer appears in any part")
    func boundaryCollisionAvoidance() {
        let hostile = "#cloud-config\n# contains strato-cloud-init-boundary in a comment\n"
        let doc = CloudInitProvisioner.userDataDocument(sshAuthorizedKeys: [], userData: hostile)

        guard let declared = doc.split(separator: "\n").first,
            let start = declared.range(of: "boundary=\"")?.upperBound,
            let end = declared[start...].firstIndex(of: "\"")
        else {
            Issue.record("no boundary declared in: \(doc.prefix(120))")
            return
        }
        let boundary = String(declared[start..<end])
        #expect(boundary != "strato-cloud-init-boundary")
        #expect(!hostile.contains(boundary))
        // Every part opener is framed with the extended boundary: five parts
        // (provisioning cfg, console setup, qga setup, hot-plug onlining,
        // caller payload) give five openers → six segments.
        #expect(doc.components(separatedBy: "\n--\(boundary)\n").count == 6)
        #expect(doc.hasSuffix("\n--\(boundary)--\n"))
    }

    @Test("multipart framing: headers, blank line, then part bodies")
    func multipartFraming() {
        let doc = CloudInitProvisioner.multipartDocument(parts: [
            CloudInitProvisioner.MIMEPart(
                mimeType: "text/cloud-config", filename: "a.cfg", content: "#cloud-config\nx: 1\n"),
            CloudInitProvisioner.MIMEPart(mimeType: "text/x-shellscript", filename: "b.sh", content: "#!/bin/sh\ntrue"),
        ])
        let expected = """
            Content-Type: multipart/mixed; boundary="strato-cloud-init-boundary"
            MIME-Version: 1.0

            --strato-cloud-init-boundary
            Content-Type: text/cloud-config; charset="utf-8"
            MIME-Version: 1.0
            Content-Disposition: attachment; filename="a.cfg"

            #cloud-config
            x: 1
            --strato-cloud-init-boundary
            Content-Type: text/x-shellscript; charset="utf-8"
            MIME-Version: 1.0
            Content-Disposition: attachment; filename="b.sh"

            #!/bin/sh
            true
            --strato-cloud-init-boundary--

            """
        #expect(doc == expected)
    }
}
