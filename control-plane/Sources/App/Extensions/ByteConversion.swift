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

extension Double {
    /// This gibibyte value expressed in whole bytes.
    var gbToBytes: Int64 {
        Int64(self * 1024 * 1024 * 1024)
    }
}
