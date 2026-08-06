import Foundation
import Testing

@testable import StratoAgentCore

@Suite("Cloud-init meta-data document assembly")
struct CloudInitMetaDataTests {

    @Test("the desired hostname is what the guest configures itself under")
    func desiredHostnameWins() {
        let doc = CloudInitProvisioner.metaDataDocument(
            vmId: "0F6AFCDE-2F3A-4F1C-B704-F8F9AAE2E17B", hostname: "e2e-noble-1")

        // The name the control plane publishes in the VM's DNS zone, verbatim:
        // a guest answering to anything else disagrees with its own records
        // (STR-177).
        #expect(doc.contains("local-hostname: e2e-noble-1"))
        #expect(!doc.contains("vm-0F6AFCDE"))
        // instance-id stays the VM id — cloud-init keys "have I run for this
        // instance" on it, so it must not follow the hostname.
        #expect(doc.contains("instance-id: 0F6AFCDE-2F3A-4F1C-B704-F8F9AAE2E17B"))
    }

    @Test("a VM with no hostname keeps the historical derivation")
    func noHostnameFallsBack() {
        let doc = CloudInitProvisioner.metaDataDocument(
            vmId: "0F6AFCDE-2F3A-4F1C-B704-F8F9AAE2E17B", hostname: nil)

        // VMs predating `VM.hostname` (issue #770) publish no name for this to
        // disagree with, so the pre-STR-177 output is unchanged for them.
        #expect(
            doc == """
                instance-id: 0F6AFCDE-2F3A-4F1C-B704-F8F9AAE2E17B
                local-hostname: vm-0F6AFCDE
                """)
    }

    @Test("a hostname that is not a DNS label falls back instead of authoring YAML")
    func invalidHostnameFallsBack() {
        // Newlines and colons are the hazard: the value lands unquoted in a YAML
        // document, so an unchecked name could add keys to meta-data.
        let hostileNames = [
            "web\nlocal-hostname: attacker",
            "web: x",
            "",
            "-web",
            "web-",
            String(repeating: "a", count: 64),
        ]
        for hostile in hostileNames {
            let doc = CloudInitProvisioner.metaDataDocument(vmId: "abcdefgh-0000", hostname: hostile)
            #expect(doc.contains("local-hostname: vm-abcdefgh"))
            #expect(doc.split(separator: "\n").count == 2)
        }
    }

    @Test("the resolved label is the single decision the document renders from")
    func resolvedLabel() {
        // `makeNoCloudISO` warns on `resolved != desired` rather than re-deriving
        // the validity check, so this is the one place the fallback is decided.
        #expect(CloudInitProvisioner.localHostname(vmId: "abcdefgh-0000", hostname: "web-01") == "web-01")
        #expect(CloudInitProvisioner.localHostname(vmId: "abcdefgh-0000", hostname: nil) == "vm-abcdefgh")
        #expect(CloudInitProvisioner.localHostname(vmId: "abcdefgh-0000", hostname: "web 01") == "vm-abcdefgh")

        // And the document renders exactly that label.
        let resolved = CloudInitProvisioner.localHostname(vmId: "abcdefgh-0000", hostname: "web-01")
        #expect(CloudInitProvisioner.metaDataDocument(vmId: "abcdefgh-0000", hostname: "web-01").contains(resolved))
    }

    @Test("label validation matches the control plane's RFC 1123 rule")
    func labelValidation() {
        #expect(CloudInitProvisioner.isValidHostnameLabel("web-01"))
        #expect(CloudInitProvisioner.isValidHostnameLabel("0"))
        #expect(CloudInitProvisioner.isValidHostnameLabel(String(repeating: "a", count: 63)))
        // DNS comparison is case-insensitive, so a differently-cased spelling
        // still answers to the VM's records.
        #expect(CloudInitProvisioner.isValidHostnameLabel("Web"))

        #expect(!CloudInitProvisioner.isValidHostnameLabel("web.example.internal"))
        #expect(!CloudInitProvisioner.isValidHostnameLabel("web_01"))
        #expect(!CloudInitProvisioner.isValidHostnameLabel("wéb"))
        #expect(!CloudInitProvisioner.isValidHostnameLabel(" web"))
    }
}
