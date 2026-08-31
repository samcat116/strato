import Foundation

// MARK: - Snapshot tags

/// How a control-plane snapshot id becomes a QEMU snapshot tag.
///
/// The letter prefix makes UUIDs valid QEMU identifiers. The reversible mapping
/// lets the agent enumerate Strato-owned checkpoints without a side manifest.
public enum VMSnapshotTag {
    public static let prefix = "strato-"

    /// The qcow2 internal snapshot tag for a control-plane snapshot id.
    public static func tag(for snapshotId: String) -> String {
        prefix + snapshotId.lowercased()
    }

    /// The snapshot id in a Strato tag, or nil for a tag Strato did not write.
    public static func snapshotId(fromTag tag: String) -> UUID? {
        guard tag.hasPrefix(prefix) else { return nil }
        return UUID(uuidString: String(tag.dropFirst(prefix.count)))
    }
}
