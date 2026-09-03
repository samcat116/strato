import Foundation

/// Conversions between raw byte counts and gibibytes (GiB), used throughout the
/// quota and resource-usage code. Centralized here so the `/ 1024 / 1024 / 1024`
/// (and its inverse) are written once and can be unit-tested.
extension Int64 {
    /// This byte count expressed in gibibytes.
    var bytesToGB: Double {
        Double(self) / 1024 / 1024 / 1024
    }

    /// This byte count as a human-readable string in binary units.
    ///
    /// Backs every preformatted `…Formatted` field the API ships — a VM's
    /// memory and disk, an image's size, a volume's and a volume snapshot's
    /// size — which previously each carried their own identical copy of this
    /// arithmetic, labelling a `/ 1024` result `GB`/`MB`/`KB` (issue #1007).
    ///
    /// This deliberately mirrors the web UI's `formatMemory`
    /// (`control-plane/web/src/lib/format-bytes.ts`) tier for tier, because
    /// the two appear side by side: the VM detail page renders the server's
    /// `memoryFormatted` directly above a snapshots card the browser formats
    /// itself, and a client is free to format `memory` rather than read
    /// `memoryFormatted`. Change one and change the other.
    ///
    /// The one place the two deliberately diverge is degenerate input. This is
    /// wire-visible — the CLI prints it straight into a table cell — so it is
    /// always a size, clamping a negative (unreachable: every source is a
    /// non-negative column) to `0 B`. The browser's copy renders `—` instead,
    /// because JSON can hand it a `NaN` or an `undefined` that no `Int64` can be.
    var formattedByteSize: String {
        // Clamp rather than print "-1 GiB": callers document this field as a size.
        if self < 0 { return "0 B" }
        let bytes = Double(self)

        // Each tier rounds *before* the next unit's test, so a value just under
        // the boundary can't both fail the larger unit and round up to
        // "1024 MiB".
        if self < 1024 { return "\(self) B" }
        let kib = (bytes / 1024).rounded()
        if kib < 1024 { return "\(Int64(kib)) KiB" }
        let mib = (bytes / (1024 * 1024)).rounded()
        if mib < 1024 { return "\(Int64(mib)) MiB" }
        let gib = ((bytes / (1024 * 1024 * 1024)) * 10).rounded() / 10
        if gib < 1024 { return Self.oneDecimal(gib, unit: "GiB") }
        return Self.oneDecimal(bytes / (1024 * 1024 * 1024 * 1024), unit: "TiB")
    }

    /// One decimal place, dropped entirely when the value lands whole.
    private static func oneDecimal(_ value: Double, unit: String) -> String {
        let rounded = (value * 10).rounded() / 10
        let digits = rounded == rounded.rounded() ? String(format: "%.0f", rounded) : String(format: "%.1f", rounded)
        return "\(digits) \(unit)"
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
    /// This gibibyte value expressed in whole bytes, or `nil` when the input is
    /// non-finite or outside the `Int64` range.
    var gbToBytes: Int64? {
        let bytes = (self * 1024 * 1024 * 1024).rounded(.towardZero)
        guard bytes.isFinite else { return nil }
        // `Double(Int64.max)` rounds up to 2^63, exactly the point at which
        // `Int64(_:Double)` would trap, so these guards (which also absorb
        // ±infinity) fence off every out-of-range operand.
        if bytes >= Double(Int64.max) || bytes <= Double(Int64.min) { return nil }
        return Int64(bytes)
    }
}
