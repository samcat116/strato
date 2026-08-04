import Foundation
import StratoShared

/// The virtio-mem sizing a resizable VM is realized with (issue #568).
///
/// Lifted out of `QEMUService` so the domain builder and the QEMU command line
/// compute the same numbers, and so the arithmetic is testable: the QEMU copy
/// reads `#if arch`, which makes only the host's own branch assertable, while
/// this one takes the architecture as a parameter the way `QEMUGraphicsDevice`
/// does.
public enum MemoryHotplugPlan {

    /// virtio-mem plugs memory in fixed-size blocks: the memory backend and
    /// every requested size must be a multiple of the device's block size,
    /// which QEMU derives from the guest's page size. Aligning to 512 MiB on
    /// arm64 — where 64 KiB-page guests push the block size that high — is safe
    /// on smaller-block hosts too, since block sizes are powers of two and a
    /// multiple of the larger is a multiple of the smaller.
    public static func blockBytes(architecture: CPUArchitecture) -> Int64 {
        switch architecture {
        case .arm64: return 512 * 1024 * 1024
        case .x86_64: return 2 * 1024 * 1024
        }
    }

    /// The block-aligned hot-pluggable region a spec asks for.
    ///
    /// Zero when the VM was sized without headroom *and* when the headroom is
    /// smaller than a single block — a sub-block request cannot be realized, so
    /// the VM gets no memory device at all rather than one it can never grow
    /// into.
    public static func alignedHotplugBytes(spec: VMSpec, architecture: CPUArchitecture) -> Int64 {
        let requested = spec.maxMemoryBytes - spec.memoryBytes
        guard requested > 0 else { return 0 }
        let block = blockBytes(architecture: architecture)
        return requested - (requested % block)
    }
}
