import SwiftSCIM

// swift-scim#4 replaced the filter parser's untyped `String` comparison value
// with `SCIMComparisonValue`, so `userName eq "sam"` now arrives as
// `.string("sam")` and `active eq true` as `.bool(true)`. The handlers below
// compare against text columns, so they need the bare text back.
//
// Deliberately not `literal`: that renders a string case *with* its surrounding
// quotes (it exists to re-serialize a filter), and a quoted needle never
// matches a stored value.
extension SCIMComparisonValue {
    /// The comparison value as plain text, or `nil` for `null`.
    var plainText: String? {
        switch self {
        case .string(let value): return value
        case .bool(let value): return value ? "true" : "false"
        case .int(let value): return String(value)
        case .double(let value): return String(value)
        case .null: return nil
        }
    }

    /// The comparison value as plain text, rejecting `null`.
    ///
    /// A `null` literal has no text to compare a column against, and matching
    /// the four characters "null" would be worse than refusing: it would
    /// silently return rows whose value is the *string* "null".
    func requireText(path: String) throws -> String {
        guard let plainText else {
            throw SCIMServerError.invalidFilter(
                detail: "SCIM filter on '\(path)' does not support a null comparison value"
            )
        }
        return plainText
    }
}
