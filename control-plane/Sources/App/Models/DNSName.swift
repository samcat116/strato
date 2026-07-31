import Foundation
import StratoShared
import Vapor

/// Name syntax for the DNS model (issue #770).
///
/// Zone names, VM hostnames, and record owner names all reduce to the same
/// grammar — a sequence of RFC 1123 labels — so the rules live in one place
/// rather than being re-derived at each write site. Everything is normalized
/// to lowercase with no trailing dot: DNS comparison is case-insensitive, but
/// the uniqueness indexes behind zone names and record names compare strings,
/// so exactly one spelling may reach the database.
enum DNSName {
    /// RFC 1035 caps a label at 63 octets and a name at 255 octets including
    /// the length bytes, which leaves 253 characters of text form.
    static let maxLabelLength = 63
    static let maxNameLength = 253

    /// The apex of a zone, spelled the way zone files spell it. A record named
    /// `@` owns the zone name itself.
    static let apex = "@"

    /// Whether `label` is a legal RFC 1123 host label: 1–63 characters of
    /// `[a-z0-9-]`, not starting or ending with a hyphen. (RFC 1123 relaxed
    /// RFC 952 to permit a leading digit, which is why `0.example` is fine.)
    static func isValidLabel(_ label: String) -> Bool {
        guard (1...maxLabelLength).contains(label.count) else { return false }
        guard !label.hasPrefix("-"), !label.hasSuffix("-") else { return false }
        return label.allSatisfy { $0.isASCII && ($0.isLowercase || $0.isNumber || $0 == "-") }
    }

    /// Normalize and validate a fully-qualified zone name.
    ///
    /// Deliberately not constrained to `.internal`: a tenant may serve
    /// `corp.example.com` internally, and that overlap with the public name is
    /// exactly what makes split-horizon possible later (issue #769). At least
    /// two labels are required — a bare single label is a host, not a zone.
    static func normalizedZoneName(_ raw: String) throws -> String {
        let normalized = normalize(raw)
        guard !normalized.isEmpty else {
            throw Abort(.badRequest, reason: "Zone name must not be empty")
        }
        guard normalized.count <= maxNameLength else {
            throw Abort(.badRequest, reason: "Zone name must not exceed \(maxNameLength) characters")
        }
        let labels = normalized.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard labels.count >= 2 else {
            throw Abort(
                .badRequest,
                reason: "Zone name '\(raw)' must be fully qualified (at least two labels, e.g. 'acme.internal')")
        }
        guard labels.allSatisfy(isValidLabel) else {
            throw Abort(
                .badRequest,
                reason: "Zone name '\(raw)' is not a valid domain name: each label must be 1–\(maxLabelLength) "
                    + "characters of letters, digits, and hyphens, and must not start or end with a hyphen")
        }
        return normalized
    }

    /// Normalize and validate a VM hostname — a single RFC 1123 label, since a
    /// hostname is the leftmost label of the name the VM registers under.
    static func normalizedHostname(_ raw: String) throws -> String {
        let normalized = normalize(raw)
        guard isValidLabel(normalized) else {
            throw Abort(
                .badRequest,
                reason: "Hostname '\(raw)' is not a valid DNS label: 1–\(maxLabelLength) characters of letters, "
                    + "digits, and hyphens, not starting or ending with a hyphen")
        }
        return normalized
    }

    /// Normalize and validate a record's owner name *relative to its zone*.
    /// `@` (or an empty string) means the zone apex; anything else is one or
    /// more labels, so `api.staging` in `acme.internal` owns
    /// `api.staging.acme.internal`. Wildcards (`*.foo`) are permitted as the
    /// leftmost label — every record type in the vocabulary can legitimately
    /// carry one.
    static func normalizedRecordName(_ raw: String) throws -> String {
        let normalized = normalize(raw)
        if normalized.isEmpty || normalized == apex { return apex }
        guard normalized.count <= maxNameLength else {
            throw Abort(.badRequest, reason: "Record name must not exceed \(maxNameLength) characters")
        }
        var labels = normalized.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        if labels.first == "*" { labels.removeFirst() }
        guard !labels.isEmpty, labels.allSatisfy(isValidLabel) else {
            throw Abort(
                .badRequest,
                reason: "Record name '\(raw)' is not a valid DNS name: each label must be 1–\(maxLabelLength) "
                    + "characters of letters, digits, and hyphens, and must not start or end with a hyphen")
        }
        return normalized
    }

    /// The fully-qualified owner name of `name` inside `zone`.
    static func qualified(name: String, inZone zone: String) -> String {
        name == apex ? zone : "\(name).\(zone)"
    }

    /// A DNS label derived from a display name — the default a VM's hostname
    /// takes at create time.
    ///
    /// Lossy by construction (`My VM (prod)` → `my-vm-prod`), which is exactly
    /// why the result is *stored* rather than recomputed on read: renaming the
    /// VM afterward must not silently move its records. Returns `vm` when the
    /// name has no usable characters at all, since a workload with a purely
    /// non-ASCII name still needs somewhere to land.
    static func slugify(_ name: String) -> String {
        var slug = ""
        var lastWasHyphen = false
        for character in name.lowercased() {
            if character.isASCII && (character.isLetter || character.isNumber) {
                slug.append(character)
                lastWasHyphen = false
            } else if !slug.isEmpty && !lastWasHyphen {
                slug.append("-")
                lastWasHyphen = true
            }
        }
        while slug.hasSuffix("-") { slug.removeLast() }
        if slug.count > maxLabelLength {
            slug = String(slug.prefix(maxLabelLength))
            while slug.hasSuffix("-") { slug.removeLast() }
        }
        return slug.isEmpty ? "vm" : slug
    }

    /// Lowercase, trim surrounding whitespace, and drop the root dot: `WEB.Acme.Internal.`
    /// and `web.acme.internal` are the same name, and only one spelling is stored.
    private static func normalize(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while value.hasSuffix(".") { value.removeLast() }
        return value
    }
}

// MARK: - Reverse names

extension DNSName {
    /// The `in-addr.arpa` / `ip6.arpa` owner name for an address — the name a
    /// PTR record lives at. Nil for an address that parses as neither family,
    /// which stored addresses never are (IPAM validates at allocation).
    static func reverseName(forAddress address: String) -> String? {
        if let value = IPAMService.parseIPv4(address) {
            let octets = (0..<4).map { String((value >> UInt32(8 * $0)) & 0xFF) }
            return octets.joined(separator: ".") + ".in-addr.arpa"
        }
        guard let parsed = IPv6Address(address) else { return nil }
        // Every nibble of the 128-bit address, least significant first.
        var nibbles: [String] = []
        for half in [parsed.lo, parsed.hi] {
            for shift in stride(from: 0, to: 64, by: 4) {
                nibbles.append(String((half >> UInt64(shift)) & 0xF, radix: 16))
            }
        }
        return nibbles.joined(separator: ".") + ".ip6.arpa"
    }
}
