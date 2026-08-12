import StratoShared

/// Maps Strato NIC order to the Firecracker interface ids admitted to MMDS.
///
/// Firecracker's MMDS configuration is an allow-list, not a VM-wide flag. The
/// `ethN` id comes from the same array position `FirecrackerService` uses while
/// configuring NICs, so disabled interfaces remain individually excluded.
public enum FirecrackerMMDSInterfacePlan {
    /// Firecracker's per-process HTTP and MMDS ceiling for Strato VMs.
    ///
    /// User data alone may contain 64 KiB of arbitrary UTF-8. Its JSON string
    /// representation can be substantially larger after control-character
    /// escaping, and the MMDS tree also carries Strato's cloud-init wrapper,
    /// network facts, tags, and keys. One MiB covers the worst-case accepted
    /// user-data encoding with ample document overhead while retaining a
    /// finite VMM-side request bound.
    public static let payloadLimitBytes = 1024 * 1024

    public static func interfaceIDs(
        for attachments: [ResolvedNetworkAttachment]
    ) -> [String] {
        attachments.enumerated().compactMap { index, attachment in
            attachment.metadataEnabled ? "eth\(index)" : nil
        }
    }

    /// Adoption has the durable specs rather than resolved attachments. A
    /// Firecracker VM can only have TAP NICs, so their array positions remain
    /// the ids used when its process was configured.
    public static func interfaceIDs(for networks: [NetworkSpec]) -> [String] {
        networks.enumerated().compactMap { index, network in
            network.metadataEnabled == true ? "eth\(index)" : nil
        }
    }
}
