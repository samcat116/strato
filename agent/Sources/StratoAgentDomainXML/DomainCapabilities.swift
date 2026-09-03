import Foundation

#if canImport(FoundationXML)
import FoundationXML
#endif

/// Reads `virsh domcapabilities` — libvirt's report of what *this* host's QEMU
/// driver can actually be asked for.
///
/// Only one question is asked of it today: can this node back a guest vTPM
/// (issue #565)? That used to be answered by looking for an `swtpm` binary at a
/// configured path, which was the right question while the agent supervised
/// swtpm itself. It no longer does — libvirt starts and supervises one per
/// domain from the `<tpm>` element (STR-136) — so the fact that matters is
/// whether *libvirtd* can, which is exactly what it reports here:
///
/// ```xml
/// <domainCapabilities>
///   <devices>
///     <tpm supported='yes'>
///       <enum name='model'><value>tpm-tis</value></enum>
///       <enum name='backendModel'><value>passthrough</value><value>emulator</value></enum>
///     </tpm>
///   </devices>
/// </domainCapabilities>
/// ```
///
/// `emulator` in `backendModel` is swtpm. A `passthrough`-only host has a
/// physical TPM to hand through and cannot serve the emulated one Strato asks
/// for, so it does not count.
///
/// Parsing lives here, away from the daemon, for the same reason
/// `DomainXMLBuilder` and `DomainDiskInventory` do.
public enum DomainCapabilities {

    /// Whether `xml` reports an emulated TPM backend.
    ///
    /// Deliberately total: every failure — malformed XML, a truncated document,
    /// no `<domainCapabilities>` at all — is `false`. The result gates an
    /// advisory check and a capability the scheduler filters on, so the cost of
    /// a wrong `false` is that vTPM VMs are not placed here, while a wrong
    /// `true` is a VM that fails to start on a host that advertised it.
    public static func tpmEmulatorSupported(in xml: String) -> Bool {
        guard let data = xml.data(using: .utf8) else { return false }
        let parser = XMLParser(data: data)
        let collector = TPMBackendCollector()
        parser.delegate = collector
        // `parse()` alone is not the check: swift-corelibs-foundation answers
        // true for a document that simply stops early, reporting the truncation
        // only through `parserError`. Here that would be harmless — a truncated
        // document has not reported an emulator backend — but the two are
        // checked together anyway so this reads like its neighbours.
        guard parser.parse(), parser.parserError == nil else { return false }
        return collector.supportsEmulatorBackend
    }
}

/// Collects `<domainCapabilities><devices><tpm supported='yes'><enum
/// name='backendModel'><value>emulator</value>`, and nothing else.
///
/// The path is matched all the way down rather than searched for: `<enum
/// name='backendModel'>` also appears under `<hostdev>`, and a bare
/// `<value>emulator</value>` appears under several other feature enums.
private final class TPMBackendCollector: NSObject, XMLParserDelegate {
    private(set) var supportsEmulatorBackend = false
    /// Ancestors of the element being parsed, innermost last.
    private var path: [String] = []
    /// Whether the open `<tpm>` element reports `supported='yes'`.
    private var inSupportedTPM = false
    /// Whether the open `<enum>` inside that element is the backend list.
    private var inBackendModelEnum = false
    /// Character data of the `<value>` currently open. Accumulated rather than
    /// assigned: `XMLParser` may split text across callbacks.
    private var valueText: String?

    func parser(
        _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
        qualifiedName: String?, attributes: [String: String] = [:]
    ) {
        defer { path.append(elementName) }

        switch elementName {
        case "tpm" where path.suffix(2) == ["domainCapabilities", "devices"] && attributes["supported"] == "yes":
            inSupportedTPM = true
        case "enum" where inSupportedTPM && path.last == "tpm":
            inBackendModelEnum = attributes["name"] == "backendModel"
        case "value" where inBackendModelEnum && path.last == "enum":
            valueText = ""
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard valueText != nil else { return }
        valueText? += string
    }

    func parser(
        _ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
        qualifiedName: String?
    ) {
        path.removeLast()

        switch elementName {
        case "value":
            if valueText?.trimmingCharacters(in: .whitespacesAndNewlines) == "emulator" {
                supportsEmulatorBackend = true
            }
            valueText = nil
        case "enum":
            inBackendModelEnum = false
        case "tpm":
            inSupportedTPM = false
        default:
            break
        }
    }
}
