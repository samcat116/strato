import StratoShared

/// Pure selection of the QEMU disk attributes that may be emitted after the
/// storage probe has answered for the concrete attachment.
public enum QEMUBlockDevicePolicy {
    /// A practical ceiling below QEMU's much larger numeric maximum. Each
    /// virtqueue consumes guest and host resources; matching hundreds of vCPUs
    /// is useful, matching an accidental unbounded input is not.
    public static let maximumQueueCount = 256

    public static func select(
        requestedMode: VolumeBlockMode,
        vCPUCount: Int,
        capabilities: StorageBlockDeviceCapabilities
    ) -> AppliedBlockDevicePolicy {
        var reasons: [String] = []
        if !capabilities.discardSupported {
            reasons.append(
                "discard disabled: "
                    + (capabilities.discardUnavailableReason
                        ?? "safe backend deallocation was not confirmed"))
        } else {
            // QEMU has a virtio-blk rotation-rate property, but libvirt's
            // supported disk XML still rejects rotation_rate on the virtio
            // bus. Its qemu:override escape hatch applies only at cold boot,
            // so using it would also make hot attach disagree with cold boot.
            reasons.append(
                "non-rotational model disabled: libvirt cannot express rotation_rate for virtio-blk")
        }

        let cacheMode: BlockDeviceCacheMode?
        let ioMode: BlockDeviceIOMode?
        switch requestedMode {
        case .conservative:
            cacheMode = nil
            ioMode = nil
        case .cachedShared:
            cacheMode = .writeback
            ioMode = nil
        case .direct:
            if capabilities.directIOSupported {
                cacheMode = BlockDeviceCacheMode.none
                ioMode = .ioUring
            } else {
                cacheMode = nil
                ioMode = nil
                reasons.append(
                    "direct I/O disabled: "
                        + (capabilities.directIOUnavailableReason
                            ?? "the cache-none/io_uring probe did not succeed"))
            }
        }

        return AppliedBlockDevicePolicy(
            active: true,
            requestedMode: requestedMode,
            cacheMode: cacheMode,
            ioMode: ioMode,
            discard: capabilities.discardSupported,
            nonRotational: false,
            queueCount: min(max(vCPUCount, 1), maximumQueueCount),
            fallbackReason: reasons.isEmpty ? nil : reasons.joined(separator: "; "))
    }
}
