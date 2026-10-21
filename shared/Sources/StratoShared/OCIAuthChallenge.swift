import Foundation

/// A parsed `WWW-Authenticate` challenge from a distribution registry.
/// Exposes the optional scope without deciding whether a client should honor it.
/// Supports the Basic/Bearer forms used by registries, not the full HTTP auth grammar.
public enum OCIAuthChallenge: Equatable, Sendable {
    case bearer(realm: String, service: String?, scope: String?)
    case basic

    /// Parses `Bearer realm="https://...",service="..."` (parameter order and
    /// quoting vary by registry) or a `Basic ...` challenge. Nil for anything
    /// unrecognized.
    public static func parse(_ header: String) -> OCIAuthChallenge? {
        let trimmed = header.trimmingCharacters(in: .whitespaces)
        if trimmed.lowercased().hasPrefix("basic") {
            return .basic
        }
        guard trimmed.lowercased().hasPrefix("bearer") else {
            return nil
        }

        var params: [String: String] = [:]
        for part in Self.splitParameters(trimmed.dropFirst("bearer".count)) {
            let pair = part.split(separator: "=", maxSplits: 1)
            guard pair.count == 2 else { continue }
            let key = pair[0].trimmingCharacters(in: .whitespaces).lowercased()
            let value = pair[1].trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            params[key] = value
        }
        guard let realm = params["realm"], !realm.isEmpty else { return nil }
        return .bearer(realm: realm, service: params["service"], scope: params["scope"])
    }

    /// Splits parameters on commas outside quoted values, preserving scopes
    /// such as `repository:app:pull,push`.
    private static func splitParameters(_ text: Substring) -> [String] {
        var parts: [String] = []
        var current = ""
        var inQuotes = false
        for character in text {
            if character == "\"" {
                inQuotes.toggle()
                current.append(character)
            } else if character == "," && !inQuotes {
                parts.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty {
            parts.append(current)
        }
        return parts
    }
}
