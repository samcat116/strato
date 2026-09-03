import Testing

@testable import StratoAgentCore
@testable import StratoAgentDomainXML

/// Whether this host can back a guest vTPM is libvirt's answer to give
/// (STR-136), and it arrives as a `virsh domcapabilities` document. Getting the
/// read wrong in either direction is expensive: a false negative keeps Windows
/// guests off a perfectly capable host, and a false positive advertises a
/// capability whose VMs then fail to start on the one node they were placed on.
@Suite("libvirt domain capabilities")
struct DomainCapabilitiesTests {

    /// Trimmed to the elements that matter, in the shape libvirt emits them.
    private static func document(tpm: String) -> String {
        """
        <domainCapabilities>
          <path>/usr/bin/qemu-system-x86_64</path>
          <domain>kvm</domain>
          <machine>pc-q35-9.1</machine>
          <arch>x86_64</arch>
          <devices>
            <disk supported='yes'>
              <enum name='diskDevice'><value>disk</value><value>cdrom</value></enum>
            </disk>
            <hostdev supported='yes'>
              <enum name='backendModel'><value>default</value><value>vfio</value></enum>
            </hostdev>
        \(tpm)
          </devices>
          <features>
            <sev supported='no'/>
          </features>
        </domainCapabilities>
        """
    }

    private static let emulatorBackend = """
            <tpm supported='yes'>
              <enum name='model'><value>tpm-tis</value><value>tpm-crb</value></enum>
              <enum name='backendModel'><value>passthrough</value><value>emulator</value></enum>
              <enum name='backendVersion'><value>2.0</value></enum>
            </tpm>
        """

    @Test("an emulator TPM backend is swtpm, and is reported")
    func emulatorBackendIsSupported() {
        #expect(DomainCapabilities.tpmEmulatorSupported(in: Self.document(tpm: Self.emulatorBackend)))
    }

    /// A host with a physical TPM to hand through cannot serve the *emulated*
    /// one Strato's domains ask for, so `passthrough` alone does not count.
    @Test("a passthrough-only TPM does not count")
    func passthroughOnlyIsNotSupported() {
        let passthroughOnly = """
                <tpm supported='yes'>
                  <enum name='model'><value>tpm-tis</value></enum>
                  <enum name='backendModel'><value>passthrough</value></enum>
                </tpm>
            """
        #expect(!DomainCapabilities.tpmEmulatorSupported(in: Self.document(tpm: passthroughOnly)))
    }

    /// libvirt reports the element with `supported='no'` on a host with no
    /// swtpm rather than omitting it, and the enums it carries then mean
    /// nothing.
    @Test("supported='no' is a no even when the enums are still listed")
    func unsupportedElementWins() {
        let unsupported = """
                <tpm supported='no'>
                  <enum name='backendModel'><value>emulator</value></enum>
                </tpm>
            """
        #expect(!DomainCapabilities.tpmEmulatorSupported(in: Self.document(tpm: unsupported)))
    }

    @Test("no TPM element at all is a no")
    func absentElementIsUnsupported() {
        #expect(!DomainCapabilities.tpmEmulatorSupported(in: Self.document(tpm: "")))
    }

    /// `<enum name='backendModel'>` also appears under `<hostdev>`, and a bare
    /// `<value>emulator</value>` could appear under any feature enum, so the
    /// path is matched all the way down rather than searched for.
    @Test("an emulator value from a neighbouring element is not mistaken for the TPM's")
    func neighbouringEnumsAreNotConfused() {
        let elsewhere = """
            <domainCapabilities>
              <devices>
                <hostdev supported='yes'>
                  <enum name='backendModel'><value>emulator</value></enum>
                </hostdev>
              </devices>
            </domainCapabilities>
            """
        #expect(!DomainCapabilities.tpmEmulatorSupported(in: elsewhere))
    }

    /// Every failure is `false` rather than a throw or a crash: the caller is an
    /// advisory check on the registration path, and a wrong `false` only keeps
    /// vTPM VMs away while a wrong `true` strands one on a host that cannot run
    /// it.
    @Test(
        "a document that cannot be read is a no, not a crash",
        arguments: [
            "", "not xml at all", "<domainCapabilities><tpm supported='yes'>",
            "<domainCapabilities><tpm supported='yes'><enum name='backendModel'><value>emulator",
        ])
    func unreadableDocumentsAreUnsupported(_ xml: String) {
        #expect(!DomainCapabilities.tpmEmulatorSupported(in: xml))
    }

    /// `XMLParser` may split character data across callbacks, so the value is
    /// accumulated rather than assigned — a document that pads or wraps it must
    /// still read as `emulator`.
    @Test("whitespace around the value does not hide it")
    func valueIsTrimmed() {
        let padded = """
                <tpm supported='yes'>
                  <enum name='backendModel'>
                    <value>
                      emulator
                    </value>
                  </enum>
                </tpm>
            """
        #expect(DomainCapabilities.tpmEmulatorSupported(in: Self.document(tpm: padded)))
    }
}
