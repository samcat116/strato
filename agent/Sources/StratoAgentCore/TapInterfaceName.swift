import Foundation

/// Deterministic, collision-resistant TAP interface name for a VM.
///
/// Linux caps network interface names at 15 characters (`IFNAMSIZ`), but a VM id
/// is a 36-character UUID, so the naïve `tap-<vmId>` (40 chars) is rejected by
/// `ip`/QEMU and never produced a working device. We instead derive a stable short
/// name — `"tap"` + 12 hex chars of an FNV-1a digest of the vmId — which is exactly
/// 15 characters.
///
/// The digest is a fixed FNV-1a (not Swift's `Hasher`, whose seed is randomized per
/// process) so the same vmId always maps to the same interface name across agent
/// restarts. This is what lets create and teardown agree on the device name.
///
/// This lives in `StratoAgentCore` (rather than the platform-gated
/// `NetworkServiceLinux`) so it is pure, portable, and unit-testable.
public func tapInterfaceName(for vmId: String) -> String {
    var hash: UInt64 = 0xcbf2_9ce4_8422_2325 // FNV-1a 64-bit offset basis
    for byte in vmId.utf8 {
        hash ^= UInt64(byte)
        hash = hash &* 0x0000_0100_0000_01b3 // FNV-1a 64-bit prime
    }
    let hex = String(format: "%012x", hash & 0xffff_ffff_ffff)
    return "tap" + hex
}
