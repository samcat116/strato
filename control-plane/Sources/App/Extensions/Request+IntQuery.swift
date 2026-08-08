import Vapor

extension Request {
    /// An integer query parameter, or `nil` when absent (or present but empty).
    ///
    /// A malformed value is a 400 rather than a silent fallback to the caller's
    /// default: an endpoint that quietly ignores `limit=abc` answers a
    /// different question than the one it was asked, and the caller never finds
    /// out.
    func intQuery(_ name: String) throws -> Int? {
        guard let raw = query[String.self, at: name], !raw.isEmpty else { return nil }
        guard let value = Int(raw) else {
            throw Abort(.badRequest, reason: "Query parameter '\(name)' must be an integer")
        }
        return value
    }

    /// `intQuery(_:)` with the caller's default substituted when the parameter
    /// is absent and the result clamped into `range`. Out-of-range values are
    /// clamped, not rejected — only unparseable ones are a 400.
    func intQuery(_ name: String, default defaultValue: Int, in range: ClosedRange<Int>) throws -> Int {
        let value = try intQuery(name) ?? defaultValue
        return Swift.min(Swift.max(value, range.lowerBound), range.upperBound)
    }

    /// A boolean query parameter, or `nil` when absent (or present but empty).
    ///
    /// Deliberately **not** `query[Bool.self, at:]`: that decodes a missing key
    /// as `false` rather than as nil, so an optional tri-state filter written
    /// against it silently becomes "absent means exclude" — a listing that
    /// answers a narrower question than it was asked, and nobody finds out.
    /// Same rule as `intQuery` for a malformed value: a 400, not a fallback.
    func boolQuery(_ name: String) throws -> Bool? {
        guard let raw = query[String.self, at: name], !raw.isEmpty else { return nil }
        switch raw.lowercased() {
        case "true", "1", "yes": return true
        case "false", "0", "no": return false
        default:
            throw Abort(.badRequest, reason: "Query parameter '\(name)' must be true or false")
        }
    }
}
