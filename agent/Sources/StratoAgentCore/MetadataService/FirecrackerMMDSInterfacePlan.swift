import StratoShared

/// Maps Strato NIC order to the Firecracker interface ids admitted to MMDS.
///
/// Firecracker's MMDS configuration is an allow-list, not a VM-wide flag. The
/// `ethN` id comes from the same array position `FirecrackerService` uses while
/// configuring NICs, so disabled interfaces remain individually excluded.
public enum FirecrackerMMDSInterfacePlan {
    /// Firecracker's per-process HTTP and MMDS ceiling for Strato VMs.
    ///
    /// The control plane admits 64 authorized keys and 64 tags with values up
    /// to 4,096 characters, plus 64 KiB of arbitrary UTF-8 user data. Keys are
    /// deliberately present twice in the EC2 projection: once under
    /// `public-keys` and once in cloud-init's generated `user-data`. JSON and
    /// YAML escaping can expand all three collections at their maxima at the
    /// same time. Eight MiB covers that complete accepted projection, the
    /// eight-NIC EC2 tree, and fixed identity overhead while retaining a finite
    /// per-VMM request bound.
    public static let payloadLimitBytes = 8 * 1024 * 1024

    public static func interfaceIDs(
        for attachments: [ResolvedNetworkAttachment],
        metadataServiceEnabled: Bool = true
    ) -> [String] {
        guard metadataServiceEnabled else { return [] }
        return attachments.enumerated().compactMap { index, attachment in
            attachment.metadataEnabled ? "eth\(index)" : nil
        }
    }

    /// Adoption has the durable specs rather than resolved attachments. A
    /// Firecracker VM can only have TAP NICs, so their array positions remain
    /// the ids used when its process was configured.
    public static func interfaceIDs(
        for networks: [NetworkSpec],
        metadataServiceEnabled: Bool = true
    ) -> [String] {
        guard metadataServiceEnabled else { return [] }
        return networks.enumerated().compactMap { index, network in
            network.metadataEnabled == true ? "eth\(index)" : nil
        }
    }
}
