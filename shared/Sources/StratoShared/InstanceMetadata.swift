import Foundation
import SwiftProtobuf

// MARK: - Instance Metadata

/// Everything a VM's link-local metadata service (169.254.169.254) may tell the
/// guest about itself — the IMDS's replacement for the boot-time NoCloud seed
/// ISO.
///
/// ## Why this rides the desired-state sync
///
/// A seed ISO is written once, at create, and is a lie from the first edit
/// afterwards: changing an SSH key or a tag means rebuilding the disk and
/// rebooting the guest. Carrying the same content on `DesiredVMState` instead
/// makes it level-triggered, generation-guarded, and safe to drop or replay,
/// with no second control loop and no second transport. An operator's metadata
/// edit propagates on the next sync — which is the entire reason the IMDS beats
/// a seed ISO.
///
/// It follows that this is **desired** state like everything else in the sync:
/// the agent stores the latest version it applied and serves that (STR-52), and
/// a replayed older sync is rejected by the VM's `generation`, not by anything
/// in here. Nothing in this value may expire, for the same reason no image URL
/// in a sync may — a sync must stay valid however long it takes to arrive.
///
/// ## What may go in here
///
/// Only what the control plane can legitimately know and is willing to disclose
/// *to the guest*. Every field is readable by any process inside the VM that
/// can reach the link-local address, so this is a publication boundary, not an
/// internal DTO: adding a field here hands it to unprivileged guest code.
///
/// `serviceEnabled` and `noCloudSeedToken` are deliberate transport controls.
/// The first decides whether any of the rest is disclosed at all; the second is
/// copied into the local seed ISO so stock NoCloud can authenticate the three
/// bootstrap GETs it makes before an IMDSv2-aware client exists. Neither is
/// rendered as metadata. See their own docs for why they ride here rather than
/// beside `metadata` on `DesiredVMState`.
///
/// ## Size on the wire
///
/// `userData`/`vendorData` are carried inline, which is the one place this
/// value cuts against the grain of `DesiredVMState`: `imageInfo` deliberately
/// carries *paths* the agent fetches rather than content, to keep the sync
/// small. Inline is the deliberate call here, and the bound is worth stating,
/// because a sync is a full snapshot re-pushed on a timer (~60s to dirty
/// agents, ~10 minutes to all) rather than a one-shot create payload.
///
/// The sync already carries a `CloudInitUserDataFormat.maxBytes`-capped
/// `VMSpec.userData` per VM — that is what the agent builds the seed ISO from.
/// This value duplicates it (and `sshAuthorizedKeys`) for the length of the
/// migration, taking the per-VM worst case from ~64 KiB to ~128 KiB before
/// JSON escaping inflates it further; retiring the seed ISO deletes the spec
/// copy and returns it to ~64 KiB. The hard ceiling is the 16 MiB frame both
/// ends set, which a sync must fit in whole — an oversized frame does not
/// degrade partially, it stops that agent converging on everything it hosts.
/// Reaching it takes on the order of 130 VMs on one host all at the user-data
/// cap, or ~250 once the spec copy is gone.
///
/// Making these references would not move that ceiling while the spec copy
/// exists, and it would cost the property the whole design rests on — the
/// agent serves exactly what the last sync said, with no fetch that can fail
/// after a sync was applied. If the ceiling ever does need moving, the lever
/// is an IMDS-specific limit below `maxBytes`, not a second transport.
public typealias InstanceMetadata = Strato_Agent_V1_InstanceMetadata
extension Strato_Agent_V1_InstanceMetadata: Codable {

    /// Whether the service should answer this instance.
    public var isServiceEnabled: Bool { _jsonServiceEnabled }

    public init(
        instanceId: UUID,
        hostname: String? = nil,
        projectId: UUID,
        environment: String? = nil,
        region: String? = nil,
        availabilityZone: String? = nil,
        nics: [MetadataNIC] = [],
        sshAuthorizedKeys: [String] = [],
        userData: String? = nil,
        vendorData: String? = nil,
        guestAgentRelease: String? = nil,
        tags: [String: String] = [:],
        identity: IdentityPolicy? = nil,
        noCloudSeedToken: UUID? = nil,
        serviceEnabled: Bool
    ) {
        self.init()
        self._jsonInstanceId = instanceId
        self._jsonHostname = hostname
        self._jsonProjectId = projectId
        self._jsonEnvironment = environment
        self._jsonRegion = region
        self._jsonAvailabilityZone = availabilityZone
        self._jsonNics = nics
        self._jsonSshAuthorizedKeys = sshAuthorizedKeys
        self._jsonUserData = userData
        self._jsonVendorData = vendorData
        self._jsonGuestAgentRelease = guestAgentRelease
        self._jsonTags = tags
        self._jsonIdentity = identity
        self._jsonNoCloudSeedToken = noCloudSeedToken
        self._jsonServiceEnabled = serviceEnabled
    }

    // Custom decode so the collections tolerate absence, matching `VMSpec`:
    // a control plane that omits an empty list yields []/[:] rather than
    // failing the whole sync for that agent. Everything else is `Optional` and
    // so tolerates absence already. `encode(to:)` stays synthesized.
    //
    // The identity fields and service policy are required current-contract
    // invariants. A missing service policy must fail the sync instead of
    // silently enabling metadata for a VM whose operator disabled it.
    public init(from decoder: any Swift.Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        _jsonInstanceId = try c.decode(UUID.self, forKey: .instanceId)
        _jsonHostname = try c.decodeIfPresent(String.self, forKey: .hostname)
        _jsonProjectId = try c.decode(UUID.self, forKey: .projectId)
        _jsonEnvironment = try c.decodeIfPresent(String.self, forKey: .environment)
        _jsonRegion = try c.decodeIfPresent(String.self, forKey: .region)
        _jsonAvailabilityZone = try c.decodeIfPresent(String.self, forKey: .availabilityZone)
        _jsonNics = try c.decodeIfPresent([MetadataNIC].self, forKey: .nics) ?? []
        _jsonSshAuthorizedKeys = try c.decodeIfPresent([String].self, forKey: .sshAuthorizedKeys) ?? []
        _jsonUserData = try c.decodeIfPresent(String.self, forKey: .userData)
        _jsonVendorData = try c.decodeIfPresent(String.self, forKey: .vendorData)
        _jsonGuestAgentRelease = try c.decodeIfPresent(String.self, forKey: .guestAgentRelease)
        _jsonTags = try c.decodeIfPresent([String: String].self, forKey: .tags) ?? [:]
        _jsonIdentity = try c.decodeIfPresent(IdentityPolicy.self, forKey: .identity)
        _jsonNoCloudSeedToken = try c.decodeIfPresent(UUID.self, forKey: .noCloudSeedToken)
        _jsonServiceEnabled = try c.decode(Bool.self, forKey: .serviceEnabled)
    }

    private enum CodingKeys: String, CodingKey {
        case instanceId; case hostname; case projectId; case environment; case region; case availabilityZone; case nics;
        case sshAuthorizedKeys; case userData; case vendorData; case guestAgentRelease; case tags; case identity;
        case noCloudSeedToken; case serviceEnabled
    }

    public func encode(to encoder: any Swift.Encoder) throws {
        try validateProtocol()
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(_jsonInstanceId, forKey: .instanceId)
        try container.encodeIfPresent(_jsonHostname, forKey: .hostname)
        try container.encode(_jsonProjectId, forKey: .projectId)
        try container.encodeIfPresent(_jsonEnvironment, forKey: .environment)
        try container.encodeIfPresent(_jsonRegion, forKey: .region)
        try container.encodeIfPresent(_jsonAvailabilityZone, forKey: .availabilityZone)
        try container.encode(_jsonNics, forKey: .nics)
        try container.encode(_jsonSshAuthorizedKeys, forKey: .sshAuthorizedKeys)
        try container.encodeIfPresent(_jsonUserData, forKey: .userData)
        try container.encodeIfPresent(_jsonVendorData, forKey: .vendorData)
        try container.encodeIfPresent(_jsonGuestAgentRelease, forKey: .guestAgentRelease)
        try container.encode(_jsonTags, forKey: .tags)
        try container.encodeIfPresent(_jsonIdentity, forKey: .identity)
        try container.encodeIfPresent(_jsonNoCloudSeedToken, forKey: .noCloudSeedToken)
        try container.encode(_jsonServiceEnabled, forKey: .serviceEnabled)
    }

}

// MARK: - Metadata NIC

/// One of a VM's network interfaces as the guest is told about it.
///
/// This is the *control plane's* view — what IPAM allocated and what the
/// network reconciler realized — not what the guest currently has configured
/// (that is `GuestNetworkInterface`, reported the other way by the QEMU guest
/// agent). The two can legitimately disagree: a guest that has not renewed its
/// lease still has an entry here.
///
/// Addressing is carried as address + prefix length rather than a dotted
/// netmask, because that is the form both renderer targets want — cloud-init's
/// network-config v2 (`addresses: [10.0.0.5/24]`) and EC2's CIDR-block keys.
/// The dotted form is derivable; the reverse needs a validity check.
public typealias MetadataNIC = Strato_Agent_V1_MetadataNIC
extension Strato_Agent_V1_MetadataNIC: Codable {

    public init(
        deviceName: String,
        macAddress: String,
        networkId: UUID,
        networkName: String,
        ipAddress: String? = nil,
        prefixLength: Int? = nil,
        gateway: String? = nil,
        ipv6Address: String? = nil,
        ipv6PrefixLength: Int? = nil,
        gateway6: String? = nil,
        mtu: Int? = nil,
        dnsServers: [String] = [],
        domainName: String? = nil,
        dhcpEnabled: Bool = false,
        metadataEnabled: Bool = false,
        resolverAddresses: [String] = []
    ) {
        self.init()
        self._jsonDeviceName = deviceName
        self._jsonMacAddress = macAddress
        self._jsonNetworkId = networkId
        self._jsonNetworkName = networkName
        self._jsonIpAddress = ipAddress
        self._jsonPrefixLength = prefixLength
        self._jsonGateway = gateway
        self._jsonIpv6Address = ipv6Address
        self._jsonIpv6PrefixLength = ipv6PrefixLength
        self._jsonGateway6 = gateway6
        self._jsonMtu = mtu
        self._jsonDnsServers = dnsServers
        self._jsonDomainName = domainName
        self._jsonDhcpEnabled = dhcpEnabled
        self._jsonMetadataEnabled = metadataEnabled
        self._jsonResolverAddresses = resolverAddresses
    }

    // `dnsServers` tolerates absence for the same reason the collections on
    // `InstanceMetadata` do — a sender with nothing to put in a list may omit
    // it rather than fail the receiving agent's whole sync. Everything else is
    // either identifying (and required) or already `Optional`.
    public init(from decoder: any Swift.Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        _jsonDeviceName = try c.decode(String.self, forKey: .deviceName)
        _jsonMacAddress = try c.decode(String.self, forKey: .macAddress)
        _jsonNetworkId = try c.decode(UUID.self, forKey: .networkId)
        _jsonNetworkName = try c.decode(String.self, forKey: .networkName)
        _jsonIpAddress = try c.decodeIfPresent(String.self, forKey: .ipAddress)
        _jsonPrefixLength = try c.decodeIfPresent(Int.self, forKey: .prefixLength)
        _jsonGateway = try c.decodeIfPresent(String.self, forKey: .gateway)
        _jsonIpv6Address = try c.decodeIfPresent(String.self, forKey: .ipv6Address)
        _jsonIpv6PrefixLength = try c.decodeIfPresent(Int.self, forKey: .ipv6PrefixLength)
        _jsonGateway6 = try c.decodeIfPresent(String.self, forKey: .gateway6)
        _jsonMtu = try c.decodeIfPresent(Int.self, forKey: .mtu)
        _jsonDnsServers = try c.decodeIfPresent([String].self, forKey: .dnsServers) ?? []
        _jsonDomainName = try c.decodeIfPresent(String.self, forKey: .domainName)
        _jsonDhcpEnabled = try c.decodeIfPresent(Bool.self, forKey: .dhcpEnabled) ?? false
        _jsonMetadataEnabled = try c.decodeIfPresent(Bool.self, forKey: .metadataEnabled) ?? false
        _jsonResolverAddresses = try c.decodeIfPresent([String].self, forKey: .resolverAddresses) ?? []
    }

    private enum CodingKeys: String, CodingKey {
        case deviceName; case macAddress; case networkId; case networkName; case ipAddress; case prefixLength;
        case gateway; case ipv6Address; case ipv6PrefixLength; case gateway6; case mtu; case dnsServers;
        case domainName; case dhcpEnabled; case metadataEnabled; case resolverAddresses
    }

    public func encode(to encoder: any Swift.Encoder) throws {
        try validateProtocol()
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(_jsonDeviceName, forKey: .deviceName)
        try container.encode(_jsonMacAddress, forKey: .macAddress)
        try container.encode(_jsonNetworkId, forKey: .networkId)
        try container.encode(_jsonNetworkName, forKey: .networkName)
        try container.encodeIfPresent(_jsonIpAddress, forKey: .ipAddress)
        try container.encodeIfPresent(_jsonPrefixLength, forKey: .prefixLength)
        try container.encodeIfPresent(_jsonGateway, forKey: .gateway)
        try container.encodeIfPresent(_jsonIpv6Address, forKey: .ipv6Address)
        try container.encodeIfPresent(_jsonIpv6PrefixLength, forKey: .ipv6PrefixLength)
        try container.encodeIfPresent(_jsonGateway6, forKey: .gateway6)
        try container.encodeIfPresent(_jsonMtu, forKey: .mtu)
        try container.encode(_jsonDnsServers, forKey: .dnsServers)
        try container.encodeIfPresent(_jsonDomainName, forKey: .domainName)
        try container.encode(_jsonDhcpEnabled, forKey: .dhcpEnabled)
        try container.encode(_jsonMetadataEnabled, forKey: .metadataEnabled)
        try container.encode(_jsonResolverAddresses, forKey: .resolverAddresses)
    }

}

// MARK: - Identity Policy

/// Whether — and as what — the IMDS may vend this instance a SPIFFE identity
/// (phase 3 of the IMDS work; nothing consumes this yet).
///
/// It exists on `InstanceMetadata` from the start so instance identity arrives
/// as a *policy the control plane already decided*, delivered on the sync like
/// everything else, rather than as a second channel the agent has to be taught
/// about later. The agent's job stays "serve what the last sync said"; deciding
/// which VM may hold which SPIFFE ID stays entirely control-plane side, where
/// the org hierarchy and the policy engine are.
///
/// Nil on `InstanceMetadata` is the conservative reading and the only one
/// available today: no identity is vended.
public typealias IdentityPolicy = Strato_Agent_V1_IdentityPolicy
extension Strato_Agent_V1_IdentityPolicy: Codable {

    public init(spiffeId: String, audiences: [String] = [], ttlSeconds: Int? = nil) {
        self.init()
        self._jsonSpiffeId = spiffeId
        self._jsonAudiences = audiences
        self._jsonTtlSeconds = ttlSeconds
    }

    // Tolerates an absent `audiences`, matching the rest of the metadata
    // collections; `spiffeId` stays required, since a policy that names no
    // identity authorizes nothing.
    public init(from decoder: any Swift.Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        _jsonSpiffeId = try c.decode(String.self, forKey: .spiffeId)
        _jsonAudiences = try c.decodeIfPresent([String].self, forKey: .audiences) ?? []
        _jsonTtlSeconds = try c.decodeIfPresent(Int.self, forKey: .ttlSeconds)
    }

    private enum CodingKeys: String, CodingKey { case spiffeId; case audiences; case ttlSeconds }

    public func encode(to encoder: any Swift.Encoder) throws {
        try validateProtocol()
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(_jsonSpiffeId, forKey: .spiffeId)
        try container.encode(_jsonAudiences, forKey: .audiences)
        try container.encodeIfPresent(_jsonTtlSeconds, forKey: .ttlSeconds)
    }

}
