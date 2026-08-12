import StratoShared

/// Maps Strato NIC order to the Firecracker interface ids admitted to MMDS.
///
/// Firecracker's MMDS configuration is an allow-list, not a VM-wide flag. The
/// `ethN` id comes from the same array position `FirecrackerService` uses while
/// configuring NICs, so disabled interfaces remain individually excluded.
public enum FirecrackerMMDSInterfacePlan {
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
