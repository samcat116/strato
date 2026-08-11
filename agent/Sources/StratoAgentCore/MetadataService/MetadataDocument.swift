import Foundation
import StratoShared

/// Renders the metadata documents from one `InstanceMetadata` snapshot.
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
            var documents = ["meta-data"]
            if CloudInitProvisioner.networkConfigYAML(for: metadata) != nil {
                documents.append("network-config")
            }
            documents.append("user-data")
            return documents.joined(separator: "\n")
        case .noCloudMetaData:
            return CloudInitProvisioner.metaDataDocument(for: metadata)
        case .userData:
            return CloudInitProvisioner.userDataDocument(for: metadata)
        case .networkConfig:
            return CloudInitProvisioner.networkConfigYAML(for: metadata)
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
