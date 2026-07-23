import Foundation

/// Conversions between raw byte counts and gibibytes (GiB), used throughout the
/// quota and resource-usage code. Centralized here so the `/ 1024 / 1024 / 1024`
/// (and its inverse) are written once and can be unit-tested.
extension Int64 {
    /// This byte count expressed in gibibytes.
    var bytesToGB: Double {
        Double(self) / 1024 / 1024 / 1024
    }
}

extension Int {
    /// This whole-gibibyte value expressed in whole bytes, computed exactly in
    /// integer arithmetic, or `nil` if the result would overflow `Int64`.
    ///
    /// Prefer this over `Double(gb).gbToBytes` for caller-supplied sizes: it
    /// avoids the `Double` round-trip entirely and lets the call site reject an
    /// oversized request with `400 Bad Request` instead of trapping the process.
    var gbToBytes: Int64? {
        let (bytes, overflow) = Int64(self).multipliedReportingOverflow(by: 1024 * 1024 * 1024)
        return overflow ? nil : bytes
    }
}

extension Double {
    /// This gibibyte value expressed in whole bytes.
    ///
    /// Saturates to the `Int64` range (and maps non-finite input to `0`) rather
    /// than trapping on an out-of-range operand, so no caller can crash the
    /// process by supplying an oversized value. Callers that must reject such
    /// input should bounds-check before converting.
    var gbToBytes: Int64 {
        let bytes = (self * 1024 * 1024 * 1024).rounded(.towardZero)
        if bytes.isNaN { return 0 }
        // `Double(Int64.max)` rounds up to 2^63, exactly the point at which
        // `Int64(_:Double)` would trap, so these guards (which also absorb
        // ±infinity) fence off every out-of-range operand.
        if bytes >= Double(Int64.max) { return Int64.max }
        if bytes <= Double(Int64.min) { return Int64.min }
        return Int64(bytes)
    }
}
