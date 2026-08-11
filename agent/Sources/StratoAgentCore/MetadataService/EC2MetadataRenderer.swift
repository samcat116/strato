import Foundation
import StratoShared

/// One address in the EC2 `meta-data/` tree.
///
/// Keeping the parsed path as a value makes the router responsible only for
/// syntax. The renderer remains the single authority on which keys one
/// `InstanceMetadata` snapshot can actually answer.
public enum EC2MetadataPath: Sendable, Equatable, Hashable {
    public enum NetworkInterfaceLeaf: Sendable, Equatable, Hashable {
        case deviceNumber
        case ipv6s
        case localHostname
        case localIPv4s
        case mac
        case ownerID
        case subnetID
        case subnetIPv4CIDRBlock
        case subnetIPv6CIDRBlocks
    }

    case index
    case hostname
    case instanceID
    case ipv6
    case localHostname
    case localIPv4
    case mac
    case network
    case networkInterfaces
    case networkMACs
    case networkInterface(macAddress: String)
    case networkInterfaceLeaf(macAddress: String, leaf: NetworkInterfaceLeaf)
    case placement
    case availabilityZone
    case region
    case publicKeys
    case publicKey(index: Int)
    case publicKeyOpenSSH(index: Int)
    case tags
    case instanceTags
    case instanceTag(key: String)

    /// Parses path components below `/latest/meta-data/`.
    public static func parse(_ components: [String]) -> EC2MetadataPath? {
        switch components {
        case []: return .index
        case ["hostname"]: return .hostname
        case ["instance-id"]: return .instanceID
        case ["ipv6"]: return .ipv6
        case ["local-hostname"]: return .localHostname
        case ["local-ipv4"]: return .localIPv4
        case ["mac"]: return .mac
        case ["network"]: return .network
        case ["network", "interfaces"]: return .networkInterfaces
        case ["network", "interfaces", "macs"]: return .networkMACs
        case ["placement"]: return .placement
        case ["placement", "availability-zone"]: return .availabilityZone
        case ["placement", "region"]: return .region
        case ["public-keys"]: return .publicKeys
        case ["tags"]: return .tags
        case ["tags", "instance"]: return .instanceTags
        default:
            break
        }

        if components.count == 3, components[0] == "tags", components[1] == "instance" {
            return .instanceTag(key: components[2])
        }
        if components.count == 2, components[0] == "public-keys",
            let index = canonicalIndex(components[1])
        {
            return .publicKey(index: index)
        }
        if components.count == 3, components[0] == "public-keys", components[2] == "openssh-key",
            let index = canonicalIndex(components[1])
        {
            return .publicKeyOpenSSH(index: index)
        }
        if components.count == 4, components.starts(with: ["network", "interfaces", "macs"]) {
            return .networkInterface(macAddress: components[3])
        }
        if components.count == 5, components.starts(with: ["network", "interfaces", "macs"]),
            let leaf = NetworkInterfaceLeaf(rawValue: components[4])
        {
            return .networkInterfaceLeaf(macAddress: components[3], leaf: leaf)
        }
        return nil
    }

    private static func canonicalIndex(_ raw: String) -> Int? {
        guard let index = Int(raw), index >= 0, String(index) == raw else { return nil }
        return index
    }
}

extension EC2MetadataPath.NetworkInterfaceLeaf {
    fileprivate init?(rawValue: String) {
        switch rawValue {
        case "device-number": self = .deviceNumber
        case "ipv6s": self = .ipv6s
        case "local-hostname": self = .localHostname
        case "local-ipv4s": self = .localIPv4s
        case "mac": self = .mac
        case "owner-id": self = .ownerID
        case "subnet-id": self = .subnetID
        case "subnet-ipv4-cidr-block": self = .subnetIPv4CIDRBlock
        case "subnet-ipv6-cidr-blocks": self = .subnetIPv6CIDRBlocks
        default: return nil
        }
    }

    fileprivate var rawValue: String {
        switch self {
        case .deviceNumber: return "device-number"
        case .ipv6s: return "ipv6s"
        case .localHostname: return "local-hostname"
        case .localIPv4s: return "local-ipv4s"
        case .mac: return "mac"
        case .ownerID: return "owner-id"
        case .subnetID: return "subnet-id"
        case .subnetIPv4CIDRBlock: return "subnet-ipv4-cidr-block"
        case .subnetIPv6CIDRBlocks: return "subnet-ipv6-cidr-blocks"
        }
    }
}

/// One address in EC2's `dynamic/` tree.
public enum EC2DynamicPath: Sendable, Equatable, Hashable {
    case index
    case instanceIdentity
    case instanceIdentityDocument

    /// Parses path components below `/latest/dynamic/`.
    public static func parse(_ components: [String]) -> EC2DynamicPath? {
        switch components {
        case []: return .index
        case ["instance-identity"]: return .instanceIdentity
        case ["instance-identity", "document"]: return .instanceIdentityDocument
        default: return nil
        }
    }
}

/// Guest-disclosure policy that is not itself instance metadata.
///
/// Placement defaults off because it exposes the site and receiving agent. A
/// future per-project setting can opt in by passing this policy without
/// changing the EC2 document shape or the shared `InstanceMetadata` model.
public struct EC2MetadataRenderOptions: Sendable, Equatable {
    public let disclosePlacement: Bool

    public init(disclosePlacement: Bool = false) {
        self.disclosePlacement = disclosePlacement
    }
}

/// Renders the EC2 projection of one `InstanceMetadata` value.
public enum EC2MetadataRenderer {
    public static func render(
        _ path: EC2MetadataPath,
        for metadata: InstanceMetadata,
        options: EC2MetadataRenderOptions = .init()
    ) -> String? {
        let primaryNIC = metadata.nics.first

        switch path {
        case .index:
            var keys = ["instance-id"]
            if metadata.hostname != nil { keys += ["hostname", "local-hostname"] }
            if primaryNIC?.ipAddress != nil { keys.append("local-ipv4") }
            if primaryNIC?.ipv6Address != nil { keys.append("ipv6") }
            if primaryNIC != nil { keys.append("mac") }
            if !metadata.nics.isEmpty { keys.append("network/") }
            if options.disclosePlacement && (metadata.availabilityZone != nil || metadata.region != nil) {
                keys.append("placement/")
            }
            if !servableSSHKeys(metadata).isEmpty { keys.append("public-keys/") }
            if !servableTags(metadata.tags).isEmpty { keys.append("tags/") }
            return listing(keys)

        case .hostname, .localHostname:
            return metadata.hostname
        case .instanceID:
            return metadata.instanceId.uuidString
        case .ipv6:
            return primaryNIC?.ipv6Address
        case .localIPv4:
            return primaryNIC?.ipAddress
        case .mac:
            return primaryNIC?.macAddress.lowercased()

        case .network:
            guard !metadata.nics.isEmpty else { return nil }
            return "interfaces/"
        case .networkInterfaces:
            guard !metadata.nics.isEmpty else { return nil }
            return "macs/"
        case .networkMACs:
            guard !metadata.nics.isEmpty else { return nil }
            return listing(Set(metadata.nics.map { "\($0.macAddress.lowercased())/" }))
        case .networkInterface(let macAddress):
            guard let match = interface(macAddress, in: metadata) else { return nil }
            return listing(interfaceKeys(for: match.nic, metadata: metadata))
        case .networkInterfaceLeaf(let macAddress, let leaf):
            guard let match = interface(macAddress, in: metadata) else { return nil }
            return render(leaf, nic: match.nic, index: match.index, metadata: metadata)

        case .placement:
            guard options.disclosePlacement else { return nil }
            var keys: [String] = []
            if metadata.availabilityZone != nil { keys.append("availability-zone") }
            if metadata.region != nil { keys.append("region") }
            guard !keys.isEmpty else { return nil }
            return listing(keys)
        case .availabilityZone:
            guard options.disclosePlacement else { return nil }
            return metadata.availabilityZone
        case .region:
            guard options.disclosePlacement else { return nil }
            return metadata.region

        case .publicKeys:
            let keys = servableSSHKeys(metadata)
            guard !keys.isEmpty else { return nil }
            // EC2's listing is `index=key-name`, not a directory entry. The
            // crawler turns each line back into `index/openssh-key`.
            return keys.indices
                .map { "\($0)=strato-key-\($0)" }
                .joined(separator: "\n")
        case .publicKey(let index):
            guard servableSSHKeys(metadata).indices.contains(index) else { return nil }
            return "openssh-key"
        case .publicKeyOpenSSH(let index):
            let keys = servableSSHKeys(metadata)
            guard keys.indices.contains(index) else { return nil }
            return keys[index]

        case .tags:
            guard !servableTags(metadata.tags).isEmpty else { return nil }
            return "instance/"
        case .instanceTags:
            let tags = servableTags(metadata.tags)
            guard !tags.isEmpty else { return nil }
            return listing(tags.keys)
        case .instanceTag(let key):
            return servableTags(metadata.tags)[key]
        }
    }

    public static func render(
        _ path: EC2DynamicPath,
        for metadata: InstanceMetadata,
        options: EC2MetadataRenderOptions = .init()
    ) -> String? {
        switch path {
        case .index:
            return "instance-identity/"
        case .instanceIdentity:
            return "document"
        case .instanceIdentityDocument:
            let document = InstanceIdentityDocument(
                accountId: metadata.projectId.uuidString,
                availabilityZone: options.disclosePlacement ? metadata.availabilityZone : nil,
                instanceId: metadata.instanceId.uuidString,
                privateIp: metadata.nics.first.flatMap { $0.ipAddress ?? $0.ipv6Address },
                region: options.disclosePlacement ? metadata.region : nil,
                version: "2017-09-30")
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            guard let data = try? encoder.encode(document) else { return nil }
            return String(decoding: data, as: UTF8.self)
        }
    }

    private struct InstanceIdentityDocument: Encodable {
        let accountId: String
        let availabilityZone: String?
        let instanceId: String
        let privateIp: String?
        let region: String?
        let version: String
    }

    private static func interface(
        _ macAddress: String, in metadata: InstanceMetadata
    ) -> (index: Int, nic: MetadataNIC)? {
        metadata.nics.enumerated().first {
            $0.element.macAddress.caseInsensitiveCompare(macAddress) == .orderedSame
        }.map { (index: $0.offset, nic: $0.element) }
    }

    private static func interfaceKeys(for nic: MetadataNIC, metadata: InstanceMetadata) -> [String] {
        var keys = [
            EC2MetadataPath.NetworkInterfaceLeaf.deviceNumber.rawValue,
            EC2MetadataPath.NetworkInterfaceLeaf.mac.rawValue,
            EC2MetadataPath.NetworkInterfaceLeaf.ownerID.rawValue,
            EC2MetadataPath.NetworkInterfaceLeaf.subnetID.rawValue,
        ]
        if nic.ipAddress != nil { keys.append(EC2MetadataPath.NetworkInterfaceLeaf.localIPv4s.rawValue) }
        if nic.ipv6Address != nil { keys.append(EC2MetadataPath.NetworkInterfaceLeaf.ipv6s.rawValue) }
        if metadata.hostname != nil, nic.ipAddress != nil || nic.ipv6Address != nil {
            keys.append(EC2MetadataPath.NetworkInterfaceLeaf.localHostname.rawValue)
        }
        if ipv4Subnet(of: nic) != nil {
            keys.append(EC2MetadataPath.NetworkInterfaceLeaf.subnetIPv4CIDRBlock.rawValue)
        }
        if ipv6Subnet(of: nic) != nil {
            keys.append(EC2MetadataPath.NetworkInterfaceLeaf.subnetIPv6CIDRBlocks.rawValue)
        }
        return keys
    }

    private static func render(
        _ leaf: EC2MetadataPath.NetworkInterfaceLeaf,
        nic: MetadataNIC,
        index: Int,
        metadata: InstanceMetadata
    ) -> String? {
        switch leaf {
        case .deviceNumber:
            let suffix = nic.deviceName.hasPrefix("net") ? String(nic.deviceName.dropFirst(3)) : ""
            guard let number = Int(suffix), suffix == String(number) else { return String(index) }
            return String(number)
        case .ipv6s: return nic.ipv6Address
        case .localHostname:
            guard nic.ipAddress != nil || nic.ipv6Address != nil else { return nil }
            return metadata.hostname
        case .localIPv4s: return nic.ipAddress
        case .mac: return nic.macAddress.lowercased()
        case .ownerID: return metadata.projectId.uuidString
        case .subnetID: return nic.networkId.uuidString
        case .subnetIPv4CIDRBlock: return ipv4Subnet(of: nic)
        case .subnetIPv6CIDRBlocks: return ipv6Subnet(of: nic)
        }
    }

    private static func ipv4Subnet(of nic: MetadataNIC) -> String? {
        guard let address = nic.ipAddress.flatMap(IPv4Address.init), let prefix = nic.prefixLength,
            (0...32).contains(prefix)
        else { return nil }
        let cidr = IPv4CIDR(base: address, prefix: prefix)
        return "\(cidr.networkAddress)/\(cidr.prefix)"
    }

    private static func ipv6Subnet(of nic: MetadataNIC) -> String? {
        guard let address = nic.ipv6Address.flatMap(IPv6Address.init), let prefix = nic.ipv6PrefixLength,
            (0...128).contains(prefix)
        else { return nil }
        return IPv6CIDR(base: address, prefix: prefix).description
    }

    /// EC2 restricts tag keys exposed through IMDS to a single safe path
    /// segment. Strato tags are freer-form, so incompatible keys stay in the
    /// shared value but are not advertised as paths that cannot be fetched.
    private static func servableTags(_ tags: [String: String]) -> [String: String] {
        tags.filter { isServableTagKey($0.key) }
    }

    private static func servableSSHKeys(_ metadata: InstanceMetadata) -> [String] {
        metadata.sshAuthorizedKeys
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func isServableTagKey(_ key: String) -> Bool {
        guard !key.isEmpty, key.utf8.count <= 128, !key.contains(".."), key != "_index" else {
            return false
        }
        let punctuation = Set("+-=.,_:@".utf8)
        return key.utf8.allSatisfy { byte in
            switch byte {
            case 48...57, 65...90, 97...122: return true
            default: return punctuation.contains(byte)
            }
        }
    }

    private static func listing<S: Sequence>(_ values: S) -> String where S.Element == String {
        values.sorted().joined(separator: "\n")
    }
}
