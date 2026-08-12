import Foundation
import StratoShared
import Testing

@testable import StratoAgentCore

@Suite("EC2 metadata renderer")
struct EC2MetadataRendererTests {
    private static let vmID = UUID(uuidString: "0F6AFCDE-2F3A-4F1C-B704-F8F9AAE2E17B")!
    private static let projectID = UUID(uuidString: "81DE421A-DA51-4324-BF76-28B411F744E7")!
    private static let frontendNetworkID = UUID(uuidString: "25E79DAA-A776-4196-ADAE-32B5B3823D74")!
    private static let backendNetworkID = UUID(uuidString: "91DE5827-A80F-4646-B447-BF08A205D82B")!

    private static let metadata = InstanceMetadata(
        instanceId: vmID,
        hostname: "web-01",
        projectId: projectID,
        environment: "production",
        region: "iad",
        availabilityZone: "hv-03",
        nics: [
            MetadataNIC(
                deviceName: "net0", macAddress: "52:54:00:12:34:56",
                networkId: frontendNetworkID, networkName: "frontend",
                ipAddress: "10.20.30.45", prefixLength: 24, gateway: "10.20.30.1",
                ipv6Address: "fd12:3456:789a::45", ipv6PrefixLength: 64,
                gateway6: "fd12:3456:789a::1", mtu: 1450,
                dnsServers: ["10.20.30.2"], domainName: "frontend.example",
                dhcpEnabled: true, metadataEnabled: true),
            MetadataNIC(
                deviceName: "net1", macAddress: "52:54:00:AB:CD:EF",
                networkId: backendNetworkID, networkName: "backend",
                ipAddress: "192.168.50.9", prefixLength: 27),
        ],
        sshAuthorizedKeys: [
            "ssh-ed25519 AAAA-primary operator@example",
            "  ssh-rsa AAAA-secondary automation@example\n",
        ],
        userData: "#cloud-config\nruncmd:\n  - echo caller\n",
        vendorData: "#cloud-config\npackages: [qemu-guest-agent]\n",
        tags: [
            "Role": "frontend",
            "team:name": "platform",
            "release..channel": "hidden",
            "not/a/path": "hidden",
            "_index": "reserved",
        ],
        serviceEnabled: true)

    private static func render(_ path: EC2MetadataPath) -> String? {
        EC2MetadataRenderer.render(path, for: metadata)
    }

    private static func value(at path: [String], in document: JSONValue) -> JSONValue? {
        path.reduce(Optional(document)) { value, component in
            guard let value, case .object(let object) = value else { return nil }
            return object[component]
        }
    }

    @Test("the Firecracker limit accepts worst-case maximum user data")
    func maximumUserDataFitsFirecrackerPayloadLimit() throws {
        let header = "#cloud-config\n"
        let userData =
            header
            + String(
                repeating: "\0",
                count: CloudInitUserDataFormat.maxBytes - header.utf8.count)
        let metadata = InstanceMetadata(
            instanceId: Self.vmID,
            projectId: Self.projectID,
            userData: userData,
            serviceEnabled: true)

        let payload = try JSONEncoder().encode(
            EC2MetadataRenderer.mmdsDocument(for: metadata))

        #expect(userData.utf8.count == CloudInitUserDataFormat.maxBytes)
        #expect(payload.count > 51_200)
        #expect(payload.count <= FirecrackerMMDSInterfacePlan.payloadLimitBytes)
    }

    @Test("the root advertises exactly the servable EC2 categories")
    func rootListingGolden() {
        #expect(
            Self.render(.index)
                == """
                hostname
                instance-id
                ipv6
                local-hostname
                local-ipv4
                mac
                network/
                public-keys/
                tags/
                """)
        #expect(Self.render(.hostname) == "web-01")
        #expect(Self.render(.localHostname) == "web-01")
        #expect(Self.render(.localIPv4) == "10.20.30.45")
        #expect(Self.render(.ipv6) == "fd12:3456:789a::45")
        #expect(Self.render(.mac) == "52:54:00:12:34:56")
    }

    @Test("the network tree is keyed by MAC and derives truthful subnet CIDRs")
    func networkTreeGolden() {
        #expect(Self.render(.network) == "interfaces/")
        #expect(Self.render(.networkInterfaces) == "macs/")
        #expect(
            Self.render(.networkMACs)
                == "52:54:00:12:34:56/\n52:54:00:ab:cd:ef/")

        let primary = "52:54:00:12:34:56"
        #expect(
            Self.render(.networkInterface(macAddress: primary))
                == """
                device-number
                ipv6s
                local-hostname
                local-ipv4s
                mac
                owner-id
                subnet-id
                subnet-ipv4-cidr-block
                subnet-ipv6-cidr-blocks
                """)
        #expect(
            Self.render(.networkInterfaceLeaf(macAddress: primary, leaf: .deviceNumber)) == "0")
        #expect(
            Self.render(.networkInterfaceLeaf(macAddress: primary, leaf: .localIPv4s)) == "10.20.30.45")
        #expect(
            Self.render(.networkInterfaceLeaf(macAddress: primary, leaf: .subnetIPv4CIDRBlock))
                == "10.20.30.0/24")
        #expect(
            Self.render(.networkInterfaceLeaf(macAddress: primary, leaf: .subnetIPv6CIDRBlocks))
                == "fd12:3456:789a::/64")
        #expect(
            Self.render(.networkInterfaceLeaf(macAddress: primary, leaf: .ownerID))
                == Self.projectID.uuidString)
        #expect(
            Self.render(.networkInterfaceLeaf(macAddress: primary, leaf: .subnetID))
                == Self.frontendNetworkID.uuidString)

        let secondary = "52:54:00:ab:cd:ef"
        #expect(
            Self.render(.networkInterfaceLeaf(macAddress: secondary, leaf: .deviceNumber)) == "1")
        #expect(
            Self.render(.networkInterfaceLeaf(macAddress: secondary, leaf: .subnetIPv4CIDRBlock))
                == "192.168.50.0/27")
    }

    @Test("SSH key indexes use EC2's index-equals-name directory protocol")
    func publicKeysGolden() {
        #expect(Self.render(.publicKeys) == "0=strato-key-0\n1=strato-key-1")
        #expect(Self.render(.publicKey(index: 0)) == "openssh-key")
        #expect(Self.render(.publicKeyOpenSSH(index: 0)) == "ssh-ed25519 AAAA-primary operator@example")
        #expect(Self.render(.publicKeyOpenSSH(index: 1)) == "ssh-rsa AAAA-secondary automation@example")
        #expect(Self.render(.publicKeyOpenSSH(index: 2)) == nil)
    }

    @Test("only tag keys representable in EC2 IMDS are advertised")
    func tagsGolden() {
        #expect(Self.render(.tags) == "instance/")
        #expect(Self.render(.instanceTags) == "Role\nteam:name")
        #expect(Self.render(.instanceTag(key: "Role")) == "frontend")
        #expect(Self.render(.instanceTag(key: "release..channel")) == nil)
        #expect(Self.render(.instanceTag(key: "not/a/path")) == nil)
        #expect(Self.render(.instanceTag(key: "_index")) == nil)
    }

    @Test("placement is hidden by default and can be disclosed as one policy")
    func placementPolicy() {
        #expect(Self.render(.placement) == nil)
        #expect(Self.render(.availabilityZone) == nil)
        #expect(Self.render(.region) == nil)

        let options = EC2MetadataRenderOptions(disclosePlacement: true)
        #expect(
            EC2MetadataRenderer.render(.placement, for: Self.metadata, options: options)
                == "availability-zone\nregion")
        #expect(
            EC2MetadataRenderer.render(.availabilityZone, for: Self.metadata, options: options) == "hv-03")
        #expect(EC2MetadataRenderer.render(.region, for: Self.metadata, options: options) == "iad")
    }

    @Test("the identity document is EC2 JSON without default placement disclosure")
    func identityDocumentGolden() throws {
        let body = try #require(EC2MetadataRenderer.render(.instanceIdentityDocument, for: Self.metadata))
        #expect(
            body
                == """
                {
                  "accountId" : "81DE421A-DA51-4324-BF76-28B411F744E7",
                  "instanceId" : "0F6AFCDE-2F3A-4F1C-B704-F8F9AAE2E17B",
                  "privateIp" : "10.20.30.45",
                  "version" : "2017-09-30"
                }
                """)

        let options = EC2MetadataRenderOptions(disclosePlacement: true)
        let disclosed = try #require(
            EC2MetadataRenderer.render(.instanceIdentityDocument, for: Self.metadata, options: options))
        let json = try #require(JSONSerialization.jsonObject(with: Data(disclosed.utf8)) as? [String: String])
        #expect(json["availabilityZone"] == "hv-03")
        #expect(json["region"] == "iad")
    }

    @Test("absent optional values are neither advertised nor invented")
    func optionalValues() {
        let minimal = InstanceMetadata(
            instanceId: Self.vmID, projectId: Self.projectID, serviceEnabled: true)
        #expect(EC2MetadataRenderer.render(EC2MetadataPath.index, for: minimal) == "instance-id")
        #expect(EC2MetadataRenderer.render(.hostname, for: minimal) == nil)
        #expect(EC2MetadataRenderer.render(.network, for: minimal) == nil)
        #expect(EC2MetadataRenderer.render(.publicKeys, for: minimal) == nil)
        #expect(EC2MetadataRenderer.render(.tags, for: minimal) == nil)
    }

    @Test("the Firecracker MMDS snapshot carries the same EC2 leaves")
    func mmdsSnapshotParity() throws {
        let document = EC2MetadataRenderer.mmdsDocument(for: Self.metadata)

        #expect(
            Self.value(at: ["latest", "meta-data", "instance-id"], in: document)
                == .string(try #require(Self.render(.instanceID))))
        #expect(
            Self.value(
                at: [
                    "latest", "meta-data", "network", "interfaces", "macs",
                    "52:54:00:12:34:56", "subnet-ipv4-cidr-block",
                ],
                in: document)
                == .string("10.20.30.0/24"))
        #expect(
            Self.value(
                at: ["latest", "meta-data", "public-keys", "0", "openssh-key"],
                in: document)
                == .string("ssh-ed25519 AAAA-primary operator@example"))
        #expect(
            Self.value(at: ["latest", "meta-data", "tags", "instance", "Role"], in: document)
                == .string("frontend"))
        #expect(
            Self.value(
                at: ["latest", "meta-data", "tags", "instance", "not/a/path"],
                in: document) == nil)
        #expect(
            Self.value(at: ["latest", "meta-data", "placement"], in: document) == nil)
        #expect(
            Self.value(at: ["latest", "user-data"], in: document)
                == .string(CloudInitProvisioner.userDataDocument(for: Self.metadata)))

        let identity = try #require(
            Self.value(
                at: ["latest", "dynamic", "instance-identity", "document"],
                in: document))
        guard case .string(let identityJSON) = identity else {
            Issue.record("MMDS identity document was not a string leaf")
            return
        }
        let identityObject = try #require(
            JSONSerialization.jsonObject(with: Data(identityJSON.utf8)) as? [String: String])
        #expect(identityObject["instanceId"] == Self.vmID.uuidString)

        // The store is JSON-encodable without an Any-typed translation layer.
        let encoded = try JSONEncoder().encode(document)
        #expect(try JSONDecoder().decode(JSONValue.self, from: encoded) == document)
    }

    @Test("disabled metadata replaces MMDS with an empty snapshot")
    func disabledMMDSSnapshot() {
        let disabled = InstanceMetadata(
            instanceId: Self.vmID, projectId: Self.projectID, serviceEnabled: false)
        #expect(EC2MetadataRenderer.mmdsDocument(for: disabled) == .object([:]))
    }
}
