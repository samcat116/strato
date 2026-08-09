import Foundation

#if canImport(FoundationXML)
import FoundationXML
#endif

/// Reads the stable MAC identities of network devices from a libvirt domain.
/// Keeping this parser outside the driver makes hot-plug idempotency testable
/// without a running libvirtd.
public enum DomainNetworkInventory {
    public static func macAddresses(inDomainXML xml: String) throws -> Set<String> {
        guard let data = xml.data(using: .utf8) else {
            throw DomainInventoryError.unparseable("the domain document is not valid UTF-8")
        }
        let parser = XMLParser(data: data)
        let delegate = NetworkCollector()
        parser.delegate = delegate
        guard parser.parse(), parser.parserError == nil else {
            throw DomainInventoryError.unparseable(
                parser.parserError?.localizedDescription ?? "the domain document could not be parsed")
        }
        guard delegate.sawDomain else {
            throw DomainInventoryError.unparseable("no <domain> element")
        }
        return delegate.macAddresses
    }
}

private final class NetworkCollector: NSObject, XMLParserDelegate {
    var sawDomain = false
    var interfaceDepth: Int?
    var depth = 0
    var macAddresses: Set<String> = []

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String]
    ) {
        depth += 1
        if elementName == "domain" { sawDomain = true }
        if elementName == "interface" { interfaceDepth = depth }
        if elementName == "mac", interfaceDepth != nil, let address = attributeDict["address"] {
            macAddresses.insert(address.lowercased())
        }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        if elementName == "interface", interfaceDepth == depth { interfaceDepth = nil }
        depth -= 1
    }
}
