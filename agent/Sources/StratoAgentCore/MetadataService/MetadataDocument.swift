import Foundation
import StratoShared

/// Renders the documents STR-56 serves, and only those.
///
/// Isolated in one small file so the downstream renderers replace it wholesale
/// rather than surgically: the NoCloud-net document (STR-60), the EC2 tree
/// (STR-65) and the identity endpoint (STR-62) each own a much larger surface,
/// and each will want to decide its own shape without unpicking choices made
/// here for a probe.
public enum MetadataDocument {
    /// The document at `path` for `metadata`, or nil when this instance has no
    /// value for a key that does exist in the tree.
    ///
    /// Nil is a 404, not an empty 200. `InstanceMetadata.hostname` is optional
    /// because `VM.hostname` is, and its doc is explicit that nothing on this
    /// side may invent one — serving an empty string would be the invention,
    /// and a guest that read it would configure itself with a blank name.
    public static func render(_ path: MetadataDocumentPath, for metadata: InstanceMetadata) -> String? {
        switch path {
        case .root:
            return "meta-data"
        case .metaDataIndex:
            // Listings name only what is actually servable, so a guest that
            // walks the tree never gets a 404 from a key this very document
            // advertised.
            return keys(of: metadata).joined(separator: "\n")
        case .instanceID:
            // Foundation's canonical uppercase form — the same spelling the
            // control-plane API returns for the VM, so an operator can match
            // what a guest reports against what the API shows without
            // case-folding.
            return metadata.instanceId.uuidString
        case .hostname:
            return metadata.hostname
        }
    }

    /// The `meta-data/` keys this instance can answer, in the order EC2 lists
    /// them (lexical).
    private static func keys(of metadata: InstanceMetadata) -> [String] {
        var keys = ["instance-id"]
        if metadata.hostname != nil { keys.append("hostname") }
        return keys.sorted()
    }
}
