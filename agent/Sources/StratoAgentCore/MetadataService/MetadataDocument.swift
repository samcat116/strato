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
    public static func render(
        _ path: MetadataDocumentPath,
        for metadata: InstanceMetadata,
        ec2Options: EC2MetadataRenderOptions = .init()
    ) -> String? {
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
        case .ec2MetaData(let path):
            return EC2MetadataRenderer.render(path, for: metadata, options: ec2Options)
        case .ec2Dynamic(let path):
            return EC2MetadataRenderer.render(path, for: metadata, options: ec2Options)
        }
    }
}
