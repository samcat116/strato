import Foundation
import Testing

@testable import StratoAgentCore

@Suite("Cloud-init user-data document assembly")
struct CloudInitUserDataDocumentTests {

    // MARK: - No caller payload (legacy single-document path)

    @Test("no user data renders the legacy single #cloud-config")
    func legacySingleDocument() {
        let doc = CloudInitProvisioner.userDataDocument(sshAuthorizedKeys: [], userData: nil)
        #expect(doc.hasPrefix("#cloud-config\n"))
        #expect(!doc.contains("multipart/mixed"))
        #expect(doc.contains("password: strato"))
        #expect(doc.contains("bootcmd:"))
        #expect(doc.contains("runcmd:"))
        #expect(doc.contains("serial-getty@ttyS0.service"))
        #expect(!doc.contains("ssh_authorized_keys"))
    }

    @Test("legacy document installs and enables the QEMU guest agent")
    func legacyInstallsGuestAgent() {
        let doc = CloudInitProvisioner.userDataDocument(sshAuthorizedKeys: [], userData: nil)
        // With no caller part to merge against, the native packages: key is safe.
        #expect(doc.contains("packages:"))
        #expect(doc.contains("- qemu-guest-agent"))
        // And the service is brought up without a reboot.
        #expect(doc.contains("systemctl enable --now qemu-guest-agent"))
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
        #expect(doc.contains("serial-getty@ttyS0.service"))
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
