import Foundation

/// One attribute of a `DomainXMLNode`.
struct DomainXMLAttribute: Equatable {
    let name: String
    let value: String
}

/// A minimal, deterministic XML element tree — just enough to emit a libvirt
/// domain document (see `DomainXMLBuilder`).
///
/// Named `DomainXMLNode` rather than `XMLElement`/`XMLNode` on purpose:
/// Foundation defines both of those, in the umbrella module on Darwin and in
/// the *not* automatically imported `FoundationXML` on Linux. An unprefixed
/// name would therefore build on the hypervisor nodes and collide on a macOS
/// dev host — a failure that only ever shows up on someone else's machine.
///
/// Why a tree at all, rather than interpolating strings the way the QEMU
/// command line is assembled:
///
/// - **Determinism.** The obvious spelling of "attributes" is a dictionary, and
///   Swift's `Dictionary` iteration order is seeded per process — attribute
///   order, and so every golden file, would change from run to run. The ordered
///   array below makes order a property of the source line that wrote it.
/// - **Escaping.** Paths, kernel command lines and network names now flow into
///   a document where `&` and `<` are structural. One funnel (`escaped`) is
///   auditable; ~60 interpolation sites are not.
struct DomainXMLNode: Equatable {
    let name: String
    /// Ordered, never a `Dictionary` — see the type's note on determinism.
    private(set) var attributes: [DomainXMLAttribute]
    private(set) var children: [DomainXMLNode]
    /// Character data. Mutually exclusive with `children` by construction: an
    /// element in this document is either a leaf with text or a container.
    private(set) var text: String?

    /// Builds an element. Attributes whose value is nil are dropped, so a
    /// conditional attribute stays a one-liner:
    /// `("secure", secureBoot ? "yes" : nil)`.
    init(
        _ name: String,
        _ attributes: [(String, String?)] = [],
        text: String? = nil,
        children: [DomainXMLNode] = []
    ) {
        self.name = name
        self.attributes = attributes.compactMap { name, value in
            value.map { DomainXMLAttribute(name: name, value: $0) }
        }
        self.children = children
        self.text = text
    }

    /// Appends a child, ignoring nil. Lets a conditional *element* stay as flat
    /// as a conditional attribute: `devices.append(tpm ? tpmNode : nil)`.
    mutating func append(_ child: DomainXMLNode?) {
        if let child { children.append(child) }
    }

    /// Renders the element and its descendants.
    ///
    /// The shape deliberately matches `virsh dumpxml`'s: no XML declaration
    /// (libvirt emits none, and omitting it keeps a golden diffable against a
    /// real dumped domain), single-quoted attributes, two-space indent, one
    /// element per line, and short-form empty elements.
    func render(indent: Int = 0) -> String {
        let pad = String(repeating: "  ", count: indent)
        let attributeText = attributes.map { " \($0.name)='\(Self.escaped($0.value))'" }.joined()

        if children.isEmpty {
            guard let text else {
                return "\(pad)<\(name)\(attributeText)/>\n"
            }
            return "\(pad)<\(name)\(attributeText)>\(Self.escaped(text))</\(name)>\n"
        }

        var out = "\(pad)<\(name)\(attributeText)>\n"
        for child in children {
            out += child.render(indent: indent + 1)
        }
        out += "\(pad)</\(name)>\n"
        return out
    }

    /// Escapes a value for use as character data or an attribute value.
    ///
    /// All five predefined entities are replaced — `&` first, or the
    /// replacements themselves get re-escaped. `>` is only required inside
    /// `]]>`, and each quote only inside a same-quoted attribute, but escaping
    /// all five keeps this correct wherever it is called and independent of the
    /// renderer's quoting style.
    ///
    /// Characters XML 1.0 forbids outright — the C0 controls other than tab, LF
    /// and CR, plus U+FFFE and U+FFFF — are **dropped** rather than escaped:
    /// there is no entity that can represent them (`&#0;` is exactly as illegal
    /// as a literal NUL), so the only alternatives are dropping them or
    /// emitting a document libvirt cannot parse. Swift `String` cannot hold a
    /// lone surrogate, so there is nothing to do about those.
    static func escaped(_ value: String) -> String {
        var out = String()
        out.reserveCapacity(value.unicodeScalars.count)
        for scalar in value.unicodeScalars {
            switch scalar {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&apos;"
            case "\t", "\n", "\r": out.unicodeScalars.append(scalar)
            case let other where other.value < 0x20: continue
            case "\u{FFFE}", "\u{FFFF}": continue
            case let other: out.unicodeScalars.append(other)
            }
        }
        return out
    }
}
