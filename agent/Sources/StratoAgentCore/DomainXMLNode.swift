import Foundation

#if canImport(FoundationXML)
import FoundationXML
#endif

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
    /// Character data. Mutually exclusive with `children`: an element in this
    /// document is either a leaf with text or a container, and `render` has no
    /// mixed-content form — it emits text only where there are no children, so
    /// breaking the rule loses the text.
    ///
    /// The `assert`s at the mutation points below say so to whoever writes the
    /// call, and that is all they do: they are compiled out at `-O`, which is
    /// the build hypervisor nodes run. Anything that edits a document it did not
    /// itself construct therefore has to establish this for real —
    /// `DomainXMLNode.parse` refuses mixed content on the way in, and
    /// `DomainRedefinition` refuses a document whose `<devices>` or `<cpu>` is a
    /// leaf before it adds anything to either.
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
        assert(text == nil || children.isEmpty, "<\(name)> would drop its text: mixed content is not rendered")
    }

    /// Appends a child, ignoring nil. Lets a conditional *element* stay as flat
    /// as a conditional attribute: `devices.append(tpm ? tpmNode : nil)`.
    mutating func append(_ child: DomainXMLNode?) {
        guard let child else { return }
        assert(text == nil, "<\(name)> would drop its text: mixed content is not rendered")
        children.append(child)
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

    // MARK: - Editing

    /// The first child called `name`, or nil.
    func child(named name: String) -> DomainXMLNode? {
        children.first { $0.name == name }
    }

    /// The position of the first child called `name`, or nil. Positions matter
    /// here: libvirt's schema fixes the order of `<domain>`'s children, so a
    /// `<maxMemory>` inserted after `<memory>` is a document it rejects.
    func firstIndex(ofChildNamed name: String) -> Int? {
        children.firstIndex { $0.name == name }
    }

    func attribute(_ name: String) -> String? {
        attributes.first { $0.name == name }?.value
    }

    /// Sets an attribute, appending it when the element does not already carry
    /// one by that name.
    mutating func setAttribute(_ name: String, _ value: String) {
        if let index = attributes.firstIndex(where: { $0.name == name }) {
            attributes[index] = DomainXMLAttribute(name: name, value: value)
        } else {
            attributes.append(DomainXMLAttribute(name: name, value: value))
        }
    }

    /// Replaces this element's character data. Refuses a container for the
    /// reason `text` gives: `render` has no mixed-content form, so the text
    /// would be dropped.
    mutating func setText(_ value: String) {
        assert(children.isEmpty, "<\(name)> would drop its children: mixed content is not rendered")
        text = value
    }

    mutating func insert(_ child: DomainXMLNode, at index: Int) {
        assert(text == nil, "<\(name)> would drop its text: mixed content is not rendered")
        children.insert(child, at: index)
    }

    /// Applies `edit` to the first child called `name`, doing nothing when there
    /// is none. The closure form keeps a nested edit — `<cpu>`'s `<numa>`'s
    /// `<cell>` — from having to copy each level back down by hand.
    @discardableResult
    mutating func editChild(named name: String, _ edit: (inout DomainXMLNode) -> Void) -> Bool {
        guard let index = firstIndex(ofChildNamed: name) else { return false }
        edit(&children[index])
        return true
    }

    /// Applies `edit` to every child called `name`.
    mutating func editChildren(named name: String, _ edit: (inout DomainXMLNode) -> Void) {
        for index in children.indices where children[index].name == name {
            edit(&children[index])
        }
    }

    mutating func removeChildren(named name: String) {
        children.removeAll { $0.name == name }
    }

    // MARK: - Reading a document back

    /// Reads a rendered document back into a tree, so a transform can change a
    /// few elements and leave every other one exactly as libvirt wrote it
    /// (`DomainRedefinition`, STR-187).
    ///
    /// This is the inverse of `render` and only of `render`: it is for documents
    /// **libvirt produced**, which is a far smaller language than XML. Three
    /// things are consequently not round-tripped, and each is either harmless
    /// here or refused rather than silently dropped:
    ///
    /// - **Attribute order.** `XMLParser` reports attributes as a dictionary, so
    ///   there is no order to preserve; they come back sorted by name. XML gives
    ///   attribute order no meaning and libvirt reads the result identically —
    ///   but a re-rendered document is not textually diffable against the
    ///   `dumpxml` it came from, which is why nothing here treats it as one.
    /// - **Comments.** Dropped. libvirt regenerates the warning banner it writes
    ///   at the top of a stored domain configuration on every define.
    /// - **Mixed content and CDATA.** Refused (`unparseable`), never dropped.
    ///   Neither appears in a domain document libvirt writes, and a document
    ///   carrying one is a document this cannot re-emit faithfully — which for a
    ///   transform that ends in `virDomainDefineXML` would mean quietly
    ///   redefining a VM's hardware.
    static func parse(_ xml: String) throws -> DomainXMLNode {
        guard let data = xml.data(using: .utf8) else {
            throw DomainInventoryError.unparseable("the domain document is not valid UTF-8")
        }
        let parser = XMLParser(data: data)
        let builder = DomainXMLTreeBuilder()
        parser.delegate = builder
        // Namespaces stay unprocessed, so `xmlns:qemu` comes back as an ordinary
        // attribute and `<qemu:commandline>` as an ordinary element name. The
        // agent emits neither, but a domain that acquired one through `virsh
        // edit` still has to survive a redefine with it intact.
        parser.shouldProcessNamespaces = false
        // `parse()` alone is not the check — see `DomainDiskInventory.disks`,
        // where swift-corelibs-foundation answers true for a document that
        // simply stops early.
        guard parser.parse(), parser.parserError == nil else {
            throw DomainInventoryError.unparseable(
                parser.parserError?.localizedDescription ?? "the domain document could not be parsed")
        }
        if let refusal = builder.refusal {
            throw DomainInventoryError.unparseable(refusal)
        }
        guard let root = builder.root else {
            throw DomainInventoryError.unparseable("the domain document has no root element")
        }
        return root
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

/// Assembles a `DomainXMLNode` tree from `XMLParser` events.
///
/// The delegate methods cannot throw, so a document this cannot represent is
/// recorded in `refusal` and raised by `DomainXMLNode.parse` once the parse
/// finishes — never swallowed, for the reason that method's note gives.
private final class DomainXMLTreeBuilder: NSObject, XMLParserDelegate {
    /// One element being read: its own facts, plus the children and character
    /// data accumulated so far. A `DomainXMLNode` is only built once the
    /// element ends, since its text-versus-children exclusivity is not
    /// decidable before then.
    private struct Frame {
        let name: String
        let attributes: [DomainXMLAttribute]
        var children: [DomainXMLNode] = []
        var text = ""
    }

    private var stack: [Frame] = []
    private(set) var root: DomainXMLNode?
    private(set) var refusal: String?

    func parser(
        _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
        qualifiedName: String?, attributes attributeDict: [String: String] = [:]
    ) {
        // Sorted, because a dictionary has no order to preserve and Swift's
        // iteration order is seeded per process — the same determinism argument
        // `DomainXMLNode` makes for its own ordered array.
        let attributes = attributeDict.keys.sorted().map {
            DomainXMLAttribute(name: $0, value: attributeDict[$0] ?? "")
        }
        stack.append(Frame(name: elementName, attributes: attributes))
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard !stack.isEmpty else { return }
        stack[stack.count - 1].text += string
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        record("a CDATA section, which this cannot re-emit")
    }

    func parser(
        _ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
        qualifiedName: String?
    ) {
        guard let frame = stack.popLast() else { return }

        // Whitespace around an element's children is layout, not content, and
        // `render` re-creates it. That holds for an element whose children are
        // *none* as much as for one with several: a pretty-printed `<cpu>` with
        // nothing in it yet arrives here carrying a newline and an indent, and
        // reading that as character data would make it a leaf — one that
        // `append` then refuses to give a child to, which is precisely what a
        // widening needs to do to it.
        var text: String?
        if frame.children.isEmpty {
            text = frame.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : frame.text
        } else if !frame.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // Anything else alongside children is mixed content, which this
            // refuses rather than drops.
            record("mixed content in <\(frame.name)>, which this cannot re-emit")
        }

        let node = DomainXMLNode(
            frame.name, frame.attributes.map { ($0.name, Optional($0.value)) }, text: text,
            children: frame.children)
        if stack.isEmpty {
            root = node
        } else {
            stack[stack.count - 1].children.append(node)
        }
    }

    /// Keeps the first refusal: it is the one closest to whatever the document
    /// actually is, and later ones are as likely to be its consequences.
    private func record(_ what: String) {
        guard refusal == nil else { return }
        refusal = "the domain document contains \(what)"
    }
}
