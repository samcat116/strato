import Foundation

/// The RFC 1123 name grammar, agent-side.
///
/// The control plane validates these names on write (`DNSName`), so reaching a
/// malformed one here means a row that predates the validation or a sender the
/// agent cannot vouch for. Re-checked rather than trusted because none of the
/// destinations carry a name as text: each interpolates it into a document with
/// its own grammar, where a stray character is a structural edit rather than a
/// bad string.
///
/// Uppercase is accepted, unlike the control plane's normalized-on-write
/// spelling: DNS comparison is case-insensitive, and a differently-cased name
/// still resolves. Nothing here compares names for identity.
public enum DNSNameSyntax {
    /// Whether `label` is a legal RFC 1123 host label: 1–63 characters of
    /// letters, digits, and hyphens, not starting or ending with a hyphen.
    public static func isValidLabel(_ label: String) -> Bool {
        guard (1...63).contains(label.count) else { return false }
        guard !label.hasPrefix("-"), !label.hasSuffix("-") else { return false }
        return label.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
    }

    /// Whether `name` is a sequence of valid labels — one or more, since a
    /// single-label search domain (`internal`, `lan`) is legitimate.
    public static func isValidDomainName(_ name: String) -> Bool {
        guard (1...253).contains(name.count) else { return false }
        return name.split(separator: ".", omittingEmptySubsequences: false).allSatisfy {
            isValidLabel(String($0))
        }
    }

    /// Whether `name` is legal as a **record owner** name: `isValidDomainName`
    /// plus a leading `*` wildcard label and RFC 8552 underscored labels
    /// (`_sip._tcp.example.com`).
    ///
    /// Mirrors the control plane's `DNSName.normalizedRecordName`, and is
    /// deliberately separate from `isValidDomainName` — which also guards the
    /// DHCP search domain, where neither a wildcard nor an underscore is
    /// meaningful. Only the zone-file renderer wants this looser grammar; the
    /// OVN driver does not, because the record types that use underscored
    /// owners (SRV, TXT) are exactly the ones it cannot express.
    public static func isValidOwnerName(_ name: String) -> Bool {
        guard (1...253).contains(name.count) else { return false }
        var labels = name.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        if labels.first == "*" { labels.removeFirst() }
        guard !labels.isEmpty else { return false }
        return labels.allSatisfy { label in
            guard label.hasPrefix("_") else { return isValidLabel(label) }
            // The underscore is a prefix marker, not a character the rest of the
            // label may use.
            return isValidLabel(String(label.dropFirst()))
        }
    }
}
