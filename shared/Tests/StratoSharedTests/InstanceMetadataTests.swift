import Foundation
import Testing

@testable import StratoShared

@Suite("Instance Metadata Tests")
struct InstanceMetadataTests {

    private static let metadata = InstanceMetadata(
        instanceId: Fixtures.uuidA,
        hostname: "web-01",
        projectId: Fixtures.uuidB,
        environment: "production",
        region: "sfo-1",
        availabilityZone: "hv-03",
        nics: [
            MetadataNIC(
                deviceName: "net0",
                macAddress: "52:54:00:12:34:56",
                networkId: Fixtures.uuidA,
                networkName: "default",
                ipAddress: "10.0.0.5",
                prefixLength: 24,
                gateway: "10.0.0.1",
                ipv6Address: "fd12:3456:789a::5",
                ipv6PrefixLength: 64,
                gateway6: "fd12:3456:789a::1",
                mtu: 1442,
                dnsServers: ["10.0.0.1", "fd12:3456:789a::1"],
                domainName: "corp.example.com",
                dhcpEnabled: true,
                metadataEnabled: true,
                resolverAddresses: ["169.254.1.0", "fd00:ec2:1::100"]
            ),
            MetadataNIC(
                deviceName: "net1",
                macAddress: "52:54:00:ab:cd:ef",
                networkId: Fixtures.uuidB,
                networkName: "isolated"
            ),
        ],
        sshAuthorizedKeys: ["ssh-ed25519 AAAAC3Nz test@example"],
        userData: "#cloud-config\npackages: [htop]\n",
        vendorData: "#cloud-config\nruncmd: [echo strato]\n",
        tags: ["role": "web", "tier": "frontend"],
        identity: IdentityPolicy(
            spiffeId: "spiffe://strato/project/\(Fixtures.uuidB)/vm/\(Fixtures.uuidA)",
            audiences: ["strato", "vault"],
            ttlSeconds: 3600
        ),
        noCloudSeedToken: UUID(uuidString: "11111111-2222-4333-8444-555555555555"),
        serviceEnabled: true
    )

    private func desiredState(metadata: InstanceMetadata?) -> DesiredVMState {
        DesiredVMState(
            vmId: Fixtures.uuidA,
            hypervisorType: .qemu,
            spec: VMSpec(cpus: 2, memoryBytes: 2 << 30, boot: .disk(firmware: nil)),
            desiredStatus: .running,
            generation: 9,
            imageInfo: Fixtures.imageInfo,
            metadata: metadata
        )
    }

    @Test("Instance metadata round-trips on a DesiredVMState through the envelope")
    func metadataRoundTrip() throws {
        let message = DesiredStateMessage(syncId: "sync-imds", vms: [desiredState(metadata: Self.metadata)])
        let decoded = try throughEnvelope(message)

        let metadata = try #require(decoded.vms.first?.metadata)
        #expect(metadata == Self.metadata)
        #expect(metadata.instanceId == Fixtures.uuidA)
        #expect(metadata.hostname == "web-01")
        #expect(metadata.projectId == Fixtures.uuidB)
        #expect(metadata.environment == "production")
        #expect(metadata.region == "sfo-1")
        #expect(metadata.availabilityZone == "hv-03")
        #expect(metadata.sshAuthorizedKeys == ["ssh-ed25519 AAAAC3Nz test@example"])
        #expect(metadata.userData == "#cloud-config\npackages: [htop]\n")
        #expect(metadata.vendorData == "#cloud-config\nruncmd: [echo strato]\n")
        #expect(metadata.tags == ["role": "web", "tier": "frontend"])
        #expect(metadata.noCloudSeedToken?.uuidString == "11111111-2222-4333-8444-555555555555")

        // The rest of the desired entry is unaffected by riding alongside it.
        #expect(decoded.vms.first?.generation == 9)
        #expect(
            decoded.vms.first?.imageInfo?.artifact(ofKind: .diskImage)?.filename
                == "debian-12.qcow2")
    }

    @Test("Metadata NICs survive the round trip in order, dual-stack and bare alike")
    func metadataNICRoundTrip() throws {
        let decoded = try roundTrip(Self.metadata)
        #expect(decoded.nics.count == 2)

        let primary = decoded.nics[0]
        #expect(primary.deviceName == "net0")
        #expect(primary.macAddress == "52:54:00:12:34:56")
        #expect(primary.networkId == Fixtures.uuidA)
        #expect(primary.networkName == "default")
        #expect(primary.ipAddress == "10.0.0.5")
        #expect(primary.prefixLength == 24)
        #expect(primary.gateway == "10.0.0.1")
        #expect(primary.ipv6Address == "fd12:3456:789a::5")
        #expect(primary.ipv6PrefixLength == 64)
        #expect(primary.gateway6 == "fd12:3456:789a::1")
        #expect(primary.mtu == 1442)
        #expect(primary.dnsServers == ["10.0.0.1", "fd12:3456:789a::1"])
        #expect(primary.domainName == "corp.example.com")
        #expect(primary.dhcpEnabled)
        #expect(primary.metadataEnabled)
        #expect(primary.resolverAddresses == ["169.254.1.0", "fd00:ec2:1::100"])

        // A NIC IPAM has not addressed keeps nils rather than fabricated
        // empties — the guest must be able to tell "unassigned" from "0.0.0.0".
        let secondary = decoded.nics[1]
        #expect(secondary.deviceName == "net1")
        #expect(secondary.ipAddress == nil)
        #expect(secondary.prefixLength == nil)
        #expect(secondary.ipv6Address == nil)
        #expect(secondary.mtu == nil)
        #expect(secondary.dnsServers.isEmpty)
        #expect(secondary.domainName == nil)
        #expect(!secondary.dhcpEnabled)
        #expect(!secondary.metadataEnabled)
        #expect(secondary.resolverAddresses.isEmpty)
    }

    @Test("Identity policy round-trips (phase 3 shape)")
    func identityPolicyRoundTrip() throws {
        let identity = try #require(roundTrip(Self.metadata).identity)
        #expect(identity.spiffeId == "spiffe://strato/project/\(Fixtures.uuidB)/vm/\(Fixtures.uuidA)")
        #expect(identity.audiences == ["strato", "vault"])
        #expect(identity.ttlSeconds == 3600)
    }

    @Test("Metadata NIC exposes cloud-init style CIDRs, and only when fully known")
    func metadataNICCIDRs() {
        let addressed = Self.metadata.nics[0]
        #expect(addressed.ipv4CIDR == "10.0.0.5/24")
        #expect(addressed.ipv6CIDR == "fd12:3456:789a::5/64")

        // Half an address is worse than none: a renderer must not emit
        // "10.0.0.5/nil" or guess a prefix.
        let halfKnown = MetadataNIC(
            deviceName: "net0",
            macAddress: "52:54:00:12:34:56",
            networkId: Fixtures.uuidA,
            networkName: "default",
            ipAddress: "10.0.0.5"
        )
        #expect(halfKnown.ipv4CIDR == nil)
        #expect(halfKnown.ipv6CIDR == nil)
    }

    @Test("A payload with no metadata key — what a pre-v26 control plane sends — decodes to nil")
    func desiredVMStateMetadataBackwardCompatible() throws {
        // A pre-v26 control plane's desired entry differs from this build's
        // only by the absent key, so the encoding of a metadata-less VM *is*
        // the legacy payload. Assert the absence first, or the decode below
        // would pass just as happily against an explicit null.
        let withoutMetadata = desiredState(metadata: nil)
        let keys = try encodedKeys(withoutMetadata)
        #expect(!keys.contains("metadata"))

        let decoded = try decodeJSON(DesiredVMState.self, from: encodeJSON(withoutMetadata))
        #expect(decoded.metadata == nil)
        #expect(decoded.generation == 9)
        #expect(decoded.desiredStatus == .running)

        // And the key is there — not silently dropped — when there is metadata.
        #expect(try encodedKeys(desiredState(metadata: Self.metadata)).contains("metadata"))
    }

    @Test("An explicit null metadata decodes to nil, like an absent key")
    func desiredVMStateExplicitNullMetadata() throws {
        // The mirror image of the case above: a producer that writes the key
        // with a null must not fail the decode and take the whole sync — and
        // with it every VM on the receiving agent — down with it.
        let object = try JSONSerialization.jsonObject(with: encodeJSON(desiredState(metadata: nil)))
        var fields = try #require(object as? [String: Any])
        fields["metadata"] = NSNull()
        let withNull = try JSONSerialization.data(withJSONObject: fields)

        let reparsed = try #require(JSONSerialization.jsonObject(with: withNull) as? [String: Any])
        #expect(reparsed["metadata"] is NSNull)
        #expect(try decodeJSON(DesiredVMState.self, from: withNull).metadata == nil)
    }

    @Test("Metadata carrying its required keys decodes optional collections as empty")
    func metadataTolerantCollectionDecoding() throws {
        // Forward tolerance within the type: a sender that omits collections it
        // has nothing to put in must not fail the whole sync for that agent.
        let minimal = """
            {"instanceId":"\(Fixtures.uuidA.uuidString)","projectId":"\(Fixtures.uuidB.uuidString)","serviceEnabled":true}
            """
        let decoded = try decodeJSON(InstanceMetadata.self, from: minimal)
        #expect(decoded.nics.isEmpty)
        #expect(decoded.sshAuthorizedKeys.isEmpty)
        #expect(decoded.tags.isEmpty)
        #expect(decoded.noCloudSeedToken == nil)
        // A VM predating `VM.hostname` (issue #770) has none, and nothing here
        // may invent one — it would disagree with the VM's DNS zone.
        #expect(decoded.hostname == nil)
        #expect(decoded.environment == nil)
        #expect(decoded.region == nil)
        #expect(decoded.availabilityZone == nil)
        // Nil, not "": cloud-init treats an empty user-data document as
        // "provided, and does nothing", which is a different instruction.
        #expect(decoded.userData == nil)
        #expect(decoded.vendorData == nil)
        // No policy means no identity is vended — the conservative reading.
        #expect(decoded.identity == nil)
        #expect(decoded.serviceEnabled)
        #expect(decoded.isServiceEnabled)
    }

    @Test("The kill switch round-trips, and only an explicit false switches the service off")
    func serviceEnabledRoundTrip() throws {
        for (json, enabled) in [("false", false), ("true", true)] {
            let payload = """
                {"instanceId":"\(Fixtures.uuidA.uuidString)","projectId":"\(Fixtures.uuidB.uuidString)",\
                "serviceEnabled":\(json)}
                """
            let decoded = try decodeJSON(InstanceMetadata.self, from: payload)
            #expect(decoded.serviceEnabled == enabled)
            #expect(decoded.isServiceEnabled == enabled)
        }

        // …and it survives the encoder both sides share, so a switch thrown in
        // the control plane is a switch the agent reads.
        let off = InstanceMetadata(
            instanceId: Fixtures.uuidA, projectId: Fixtures.uuidB, serviceEnabled: false)
        let encoded = try WireProtocol.makeEncoder().encode(off)
        let round = try WireProtocol.makeDecoder().decode(InstanceMetadata.self, from: encoded)
        #expect(round.serviceEnabled == false)
        #expect(!round.isServiceEnabled)
    }

    @Test("Metadata requires an explicit service policy")
    func metadataRequiresServiceEnabled() {
        let missing =
            #"{"instanceId":"\#(Fixtures.uuidA.uuidString)","projectId":"\#(Fixtures.uuidB.uuidString)"}"#
        #expect(throws: DecodingError.self) {
            try decodeJSON(InstanceMetadata.self, from: missing)
        }
    }

    @Test("Metadata without an identifying id fails rather than describing nothing")
    func metadataRequiresIdentifyingKeys() {
        // The required set is deliberately just the two ids — a missing one
        // throws out of the whole DesiredStateMessage — but metadata that
        // cannot say which instance or project it describes is not metadata.
        for incomplete in [
            #"{"projectId":"\#(Fixtures.uuidB.uuidString)"}"#,
            #"{"instanceId":"\#(Fixtures.uuidA.uuidString)"}"#,
        ] {
            #expect(throws: (any Error).self) {
                _ = try decodeJSON(InstanceMetadata.self, from: incomplete)
            }
        }
    }

    @Test("A metadata NIC carrying only its identifying keys decodes safe network defaults")
    func metadataNICTolerantDecoding() throws {
        // The `dnsServers` branch of the hand-written decoder: a round trip
        // encodes the key as `[]`, so only JSON that genuinely omits it
        // exercises the fallback the custom `init(from:)` exists for.
        let minimal = """
            {"deviceName":"net0","macAddress":"52:54:00:12:34:56",
             "networkId":"\(Fixtures.uuidA.uuidString)","networkName":"default"}
            """
        let decoded = try decodeJSON(MetadataNIC.self, from: minimal)
        #expect(decoded.deviceName == "net0")
        #expect(decoded.dnsServers.isEmpty)
        #expect(decoded.resolverAddresses.isEmpty)
        #expect(!decoded.dhcpEnabled)
        #expect(!decoded.metadataEnabled)
        #expect(decoded.domainName == nil)
        #expect(decoded.ipAddress == nil)
        #expect(decoded.ipv4CIDR == nil)
        #expect(decoded.mtu == nil)
    }

    @Test("An identity policy carrying only its SPIFFE ID decodes to no audiences")
    func identityPolicyTolerantDecoding() throws {
        let decoded = try decodeJSON(
            IdentityPolicy.self, from: #"{"spiffeId":"spiffe://strato/vm/1"}"#)
        #expect(decoded.spiffeId == "spiffe://strato/vm/1")
        // Empty means none: a guest asking for an audience outside the list is
        // refused, so the fallback must not be mistaken for "any".
        #expect(decoded.audiences.isEmpty)
        #expect(decoded.ttlSeconds == nil)
    }

    @Test("An identity policy naming no SPIFFE ID fails rather than authorizing nothing")
    func identityPolicyRequiresSpiffeId() {
        #expect(throws: (any Error).self) {
            _ = try decodeJSON(IdentityPolicy.self, from: #"{"audiences":["strato"]}"#)
        }
    }

    @Test("The metadata endpoints are the ones guest tooling already probes")
    func metadataEndpointAddresses() {
        // cloud-init's Ec2 datasource tries both without configuration; that is
        // the entire reason for adopting these numbers rather than our own.
        #expect(InstanceMetadataEndpoint.address == "169.254.169.254")
        #expect(InstanceMetadataEndpoint.addressV6 == "fd00:ec2::254")
        #expect(InstanceMetadataEndpoint.cidr == "169.254.169.254/32")
        #expect(InstanceMetadataEndpoint.cidrV6 == "fd00:ec2::254/128")
        // v4 first, the order the OVN addresses column and the namespace
        // interface both use.
        #expect(
            InstanceMetadataEndpoint.addresses == [
                InstanceMetadataEndpoint.address, InstanceMetadataEndpoint.addressV6,
            ])
    }
}
