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
}
