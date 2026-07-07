import Foundation

/// Parser for the `X-Forwarded-Client-Cert` (XFCC) header set by Envoy.
///
/// Format (see Envoy's HTTP connection manager docs): one element per proxy hop,
/// elements separated by commas, each element a `Key=Value` list separated by
/// semicolons. Values containing `,`, `;` or `=` are double-quoted with `\"`
/// escaping. `Cert` and `Chain` values are URL-encoded PEM.
///
/// With `forward_client_cert_details: SANITIZE_SET` Envoy replaces the whole
/// header, so a well-configured deployment produces exactly one element; the
/// parser still handles multi-element headers by letting callers take the last
/// element (the one appended by the nearest, trusted proxy).
struct XFCCElement: Sendable {
    /// Raw key/value pairs in header order, values unquoted but not URL-decoded.
    let pairs: [(key: String, value: String)]

    /// First value for a key (keys are matched case-insensitively).
    private func value(for key: String) -> String? {
        pairs.first { $0.key.caseInsensitiveCompare(key) == .orderedSame }?.value
    }

    /// The URI SAN of the client certificate as asserted by Envoy.
    var uri: String? { value(for: "URI") }

    /// The subject of the client certificate.
    var subject: String? { value(for: "Subject") }

    /// The SHA256 digest of the client certificate.
    var hash: String? { value(for: "Hash") }

    /// The leaf client certificate, URL-decoded to PEM.
    var certPEM: String? { value(for: "Cert")?.removingPercentEncoding }

    /// The full client certificate chain (leaf first), URL-decoded to PEM.
    var chainPEM: String? { value(for: "Chain")?.removingPercentEncoding }

    /// Parse an XFCC header and return the element appended by the nearest
    /// proxy hop (the last one), or nil if the header contains no key/value
    /// pairs at all.
    static func parseNearestHop(header: String) -> XFCCElement? {
        let elements = split(header[...], on: ",")
        guard let last = elements.last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
        else {
            return nil
        }

        var pairs: [(key: String, value: String)] = []
        for pair in split(last, on: ";") {
            let trimmed = pair.trimmingCharacters(in: .whitespaces)
            guard let equals = trimmed.firstIndex(of: "=") else { continue }
            let key = String(trimmed[..<equals])
            let rawValue = String(trimmed[trimmed.index(after: equals)...])
            guard !key.isEmpty else { continue }
            pairs.append((key: key, value: unquote(rawValue)))
        }

        guard !pairs.isEmpty else { return nil }
        return XFCCElement(pairs: pairs)
    }

    /// Split on a separator, ignoring separators inside double-quoted spans.
    /// Backslash escapes the next character inside quotes.
    private static func split(_ input: Substring, on separator: Character) -> [Substring] {
        var parts: [Substring] = []
        var start = input.startIndex
        var inQuotes = false
        var index = input.startIndex

        while index < input.endIndex {
            let char = input[index]
            if inQuotes && char == "\\" {
                // Skip the escaped character (guarding against a trailing backslash)
                index = input.index(after: index)
                if index < input.endIndex {
                    index = input.index(after: index)
                }
                continue
            }
            if char == "\"" {
                inQuotes.toggle()
            } else if char == separator && !inQuotes {
                parts.append(input[start..<index])
                start = input.index(after: index)
            }
            index = input.index(after: index)
        }

        parts.append(input[start...])
        return parts
    }

    /// Strip surrounding double quotes and resolve `\"` / `\\` escapes.
    private static func unquote(_ value: String) -> String {
        guard value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") else {
            return value
        }

        let inner = value.dropFirst().dropLast()
        var result = ""
        result.reserveCapacity(inner.count)
        var escaped = false
        for char in inner {
            if escaped {
                result.append(char)
                escaped = false
            } else if char == "\\" {
                escaped = true
            } else {
                result.append(char)
            }
        }
        return result
    }
}
