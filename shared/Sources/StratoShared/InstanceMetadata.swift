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
    /// The VM's id — the same UUID as `DesiredVMState.vmId`, restated here so a
    /// renderer never has to reach outside the metadata it was handed.
    /// The VM's DNS label, when it has one — also the name it registers under
    /// in its network's primary DNS zone (see `docs/architecture/dns.md`), so
    /// the two must not drift.
    ///
    /// Optional because `VM.hostname` is (issue #770): VMs predating the column
    /// have none, and nothing on this side may invent one. A slugified `name`
    /// is precisely the lossy derivation the stored column exists to avoid, and
    /// a hostname fabricated here would disagree with the zone — breaking the
    /// no-drift invariant above in the one case it was written for. So the
    /// renderer decides what an unset hostname looks like, exactly as with
    /// `environment`, and a hostname-less VM still gets all the rest of this.
    /// The project owning the VM. Renderers expose it as the tenancy
    /// identifier (EC2's account/owner slot); it is never an authorization
    /// input — the IMDS serves whichever guest can reach it.
    /// The VM's environment within its project (`production`, `staging`, ...),
    /// when the project defines environments. Nil rather than the project's
    /// default: the renderer decides what an unset environment looks like.
    /// Placement, coarse: conventionally the VM's site name. One of the EC2
    /// renderer's two placement keys.
    ///
    /// Populated here regardless of policy — whether a guest is *told* where it
    /// runs is the renderer's call, not the model's, so that the decision lives
    /// in one place instead of being baked into every assembler.
    /// Placement, fine: conventionally the name of the agent hosting the VM.
    /// The other EC2 placement key, with the same disclosure caveat as
    /// `region` — it names a specific host, so a renderer that emits it is
    /// telling the guest which machine it shares.
    /// The VM's NICs, in the order the control plane realized them (`net0`,
    /// `net1`, ...). Empty for a VM with no interfaces; never partially
    /// populated — a NIC the control plane knows about appears here even if the
    /// guest has not configured it.
    /// SSH public keys to authorize for the guest's default user, the same set
    /// carried on `VMSpec.sshAuthorizedKeys`. Duplicated deliberately: the spec
    /// copy is what a *boot-time* provisioner consumes, this copy is what the
    /// running guest can re-read after an operator rotates a key.
    /// Caller-supplied cloud-init user data, verbatim and unvalidated beyond
    /// what the create request already checked (see `CloudInitUserDataFormat`).
    /// Nil when the caller supplied none — which is not the same as empty, and
    /// renderers must keep the distinction: cloud-init treats a zero-length
    /// user-data document as "provided, and does nothing".
    /// Vendor data — Strato's own provisioning document, distinct from the
    /// caller's `userData` so that platform config and tenant config never
    /// have to be merged into one payload (cloud-init consumes them as
    /// separate sources with separate precedence). Nil when the platform has
    /// nothing to say.
    /// Nil disables the Strato root daemon bootstrap; a release tag pins first-boot installation.
    /// Free-form key/value labels from the VM's tags. Ordinary metadata, not
    /// identity: nothing may authorize on a tag, because a guest reads its own
    /// tags and an operator can set them to anything.
    /// How, and whether, the IMDS may vend this instance a SPIFFE identity
    /// (phase 3). Nil means it may not — the conservative reading, and the one
    /// every VM gets until identity ships.

    /// The per-VM capability carried by an IMDS-backed NoCloud seed URL.
    ///
    /// Stock NoCloud follows `seedfrom` with ordinary GETs and cannot perform
    /// the IMDSv2 token handshake. This value lets the agent authenticate only
    /// those three bootstrap document reads without weakening the ordinary
    /// `/latest/*` tree. It is deliberately not rendered into any metadata
    /// document; the agent copies it only into the VM's local seed ISO.
    ///
    /// Nil for an ISO-backed VM and for desired-state payloads produced before
    /// STR-64. Although it rides the durable desired-state snapshot so agent
    /// restarts do not invalidate an already-created ISO, it is a credential:
    /// callers must never log this value or the seed URL containing it.

    /// Whether the metadata service answers this instance at all — Strato's
    /// per-instance kill switch, `VM.metadataEnabled`, and the equivalent of
    /// EC2's `MetadataOptions.HttpEndpoint` (STR-185).
    ///
    /// Distinct from `NetworkSpec.metadataEnabled` / `DesiredNetworkState`'s,
    /// which is per **network** and decides whether the link-local endpoint is
    /// published on that switch at all. The two compose as an AND from the
    /// guest's side, and neither is derived from the other: the network switch
    /// is realized by the localport, this one by the listener refusing the
    /// caller and by an ACL that denies its port the address.
    ///
    /// ## Why it lives on the document rather than beside it
    ///
    /// It could as easily have been a sibling of `metadata` on `DesiredVMState`.
    /// Carrying it *inside* buys two things that separate fields cannot:
    ///
    /// - **It cannot drift from the payload it governs.** The agent's store,
    ///   its durable copy and the snapshot pushed to a listener all move one
    ///   value, so there is no second field to arrive late, be dropped by an
    ///   older persisted record, or survive a restore without its policy.
    /// - **It survives the fail-static path.** `MetadataStore` restores what the
    ///   last sync said when the control plane is unreachable. A policy stored
    ///   anywhere but next to the document would be the one thing that restore
    ///   did not bring back — and an agent that comes up serving a VM its
    ///   operator switched off is the exact failure this field exists to
    ///   prevent.
    ///
    /// It is never rendered into a document: a disabled service publishes
    /// nothing, so there is nothing for a guest to read this out of.

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

    var _jsonInstanceId: UUID {
        get { UUID(uuidString: instanceID) ?? UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)) }
        set { let value = newValue; instanceID = value.uuidString }
    }
    var _jsonHostname: String? {
        get { hasHostname ? (hostname) : nil }
        set { if let value = newValue { hostname = value } else { clearHostname() } }
    }
    var _jsonProjectId: UUID {
        get { UUID(uuidString: projectID) ?? UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)) }
        set { let value = newValue; projectID = value.uuidString }
    }
    var _jsonEnvironment: String? {
        get { hasEnvironment ? (environment) : nil }
        set { if let value = newValue { environment = value } else { clearEnvironment() } }
    }
    var _jsonRegion: String? {
        get { hasRegion ? (region) : nil }
        set { if let value = newValue { region = value } else { clearRegion() } }
    }
    var _jsonAvailabilityZone: String? {
        get { hasAvailabilityZone ? (availabilityZone) : nil }
        set { if let value = newValue { availabilityZone = value } else { clearAvailabilityZone() } }
    }
    var _jsonNics: [MetadataNIC] {
        get { nics.values }
        set { let value = newValue; nics = Strato_Agent_V1_InstanceMetadataNicsSection.with { $0.values = value } }
    }
    var _jsonSshAuthorizedKeys: [String] {
        get { sshAuthorizedKeys.values }
        set {
            let value = newValue;
            sshAuthorizedKeys = Strato_Agent_V1_InstanceMetadataSshAuthorizedKeysSection.with { $0.values = value }
        }
    }
    var _jsonUserData: String? {
        get { hasUserData ? (userData) : nil }
        set { if let value = newValue { userData = value } else { clearUserData() } }
    }
    var _jsonVendorData: String? {
        get { hasVendorData ? (vendorData) : nil }
        set { if let value = newValue { vendorData = value } else { clearVendorData() } }
    }
    var _jsonGuestAgentRelease: String? {
        get { hasGuestAgentRelease ? (guestAgentRelease) : nil }
        set { if let value = newValue { guestAgentRelease = value } else { clearGuestAgentRelease() } }
    }
    var _jsonTags: [String: String] {
        get { tags.values }
        set { let value = newValue; tags = Strato_Agent_V1_InstanceMetadataTagsSection.with { $0.values = value } }
    }
    var _jsonIdentity: IdentityPolicy? {
        get { hasIdentity ? (identity) : nil }
        set { if let value = newValue { identity = value } else { clearIdentity() } }
    }
    var _jsonNoCloudSeedToken: UUID? {
        get {
            hasNoCloudSeedToken
                ? (UUID(uuidString: noCloudSeedToken) ?? UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)))
                : nil
        }
        set { if let value = newValue { noCloudSeedToken = value.uuidString } else { clearNoCloudSeedToken() } }
    }
    var _jsonServiceEnabled: Bool {
        get { serviceEnabled }
        set { let value = newValue; serviceEnabled = value }
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
    /// Stable device name (`net0`, `net1`, ...) from the interface's
    /// `deviceName`, ordered by `orderIndex`. Stable across reboots and
    /// re-realization, which the guest-visible kernel name is not.
    /// The NIC's MAC address. The EC2 renderer keys its whole interface tree on
    /// this (`network/interfaces/macs/<mac>/`), and it is how a guest matches an
    /// entry here to one of its own links.
    /// The logical network the NIC attaches to.
    /// The network's name — a human label for the guest, exactly as on
    /// `NetworkSpec.network`. Names are unique only within a project, so
    /// nothing may key on it.
    /// The allocated IPv4 address, or nil on a NIC with no v4 assignment.
    /// Prefix length of `ipAddress` within its subnet (24 for a /24).
    /// The network's IPv4 gateway, when it has L3.
    /// The allocated IPv6 address in canonical RFC 5952 form, on a dual-stack
    /// network.
    /// Prefix length of `ipv6Address` (64 for tenant networks).
    /// The network's IPv6 gateway, when dual-stack.
    /// Link MTU, when the network sets one.
    /// Resolvers for this NIC's network; may be mixed-family, like
    /// `DesiredNetworkState.dnsServers`. Carried because the IMDS has to be
    /// able to tell a guest everything the seed ISO's static network config
    /// used to, on networks where DHCP is off.
    /// DNS search domain for this NIC's network, when set.
    /// Whether this NIC should ask the network's DHCP responder for its guest
    /// configuration. The NoCloud-net renderer needs the same decision the
    /// seed ISO renderer receives on `NetworkSpec`; an allocated address alone
    /// cannot distinguish DHCP from static configuration.
    /// Whether this NIC's network publishes the link-local metadata endpoint.
    /// Used only to render the on-link routes the existing seed ISO carries.
    /// This network's link-local resolver addresses, or an empty list when the
    /// resolver is unavailable. When present these replace `dnsServers` in
    /// static guest configuration, exactly as in the seed ISO renderer.

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

    var _jsonDeviceName: String {
        get { deviceName }
        set { let value = newValue; deviceName = value }
    }
    var _jsonMacAddress: String {
        get { macAddress }
        set { let value = newValue; macAddress = value }
    }
    var _jsonNetworkId: UUID {
        get { UUID(uuidString: networkID) ?? UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)) }
        set { let value = newValue; networkID = value.uuidString }
    }
    var _jsonNetworkName: String {
        get { networkName }
        set { let value = newValue; networkName = value }
    }
    var _jsonIpAddress: String? {
        get { hasIpAddress ? (ipAddress) : nil }
        set { if let value = newValue { ipAddress = value } else { clearIpAddress() } }
    }
    var _jsonPrefixLength: Int? {
        get { hasPrefixLength ? (Int(prefixLength)) : nil }
        set { if let value = newValue { prefixLength = Int64(value) } else { clearPrefixLength() } }
    }
    var _jsonGateway: String? {
        get { hasGateway ? (gateway) : nil }
        set { if let value = newValue { gateway = value } else { clearGateway() } }
    }
    var _jsonIpv6Address: String? {
        get { hasIpv6Address ? (ipv6Address) : nil }
        set { if let value = newValue { ipv6Address = value } else { clearIpv6Address() } }
    }
    var _jsonIpv6PrefixLength: Int? {
        get { hasIpv6PrefixLength ? (Int(ipv6PrefixLength)) : nil }
        set { if let value = newValue { ipv6PrefixLength = Int64(value) } else { clearIpv6PrefixLength() } }
    }
    var _jsonGateway6: String? {
        get { hasGateway6 ? (gateway6) : nil }
        set { if let value = newValue { gateway6 = value } else { clearGateway6() } }
    }
    var _jsonMtu: Int? {
        get { hasMtu ? (Int(mtu)) : nil }
        set { if let value = newValue { mtu = Int64(value) } else { clearMtu() } }
    }
    var _jsonDnsServers: [String] {
        get { dnsServers.values }
        set {
            let value = newValue; dnsServers = Strato_Agent_V1_MetadataNICDnsServersSection.with { $0.values = value }
        }
    }
    var _jsonDomainName: String? {
        get { hasDomainName ? (domainName) : nil }
        set { if let value = newValue { domainName = value } else { clearDomainName() } }
    }
    var _jsonDhcpEnabled: Bool {
        get { dhcpEnabled }
        set { let value = newValue; dhcpEnabled = value }
    }
    var _jsonMetadataEnabled: Bool {
        get { metadataEnabled }
        set { let value = newValue; metadataEnabled = value }
    }
    var _jsonResolverAddresses: [String] {
        get { resolverAddresses.values }
        set {
            let value = newValue;
            resolverAddresses = Strato_Agent_V1_MetadataNICResolverAddressesSection.with { $0.values = value }
        }
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
    /// The SPIFFE ID the instance may be issued documents for:
    /// `spiffe://<trust-domain>/vm/<vm-uuid>`, the key the VM's workload
    /// registration is filed under (STR-55). Authored by the control plane; the
    /// agent never derives or extends it.
    /// Audiences the IMDS may mint JWT-SVIDs for. Empty means none — a guest
    /// asking for an audience outside this list is refused rather than served
    /// a token nothing will accept.
    /// Upper bound, in seconds, on the lifetime of a document handed to the
    /// guest. Nil defers to the issuer's own default rather than meaning
    /// "unbounded"; an identity document with no expiry is never the intent.

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

    var _jsonSpiffeId: String {
        get { spiffeID }
        set { let value = newValue; spiffeID = value }
    }
    var _jsonAudiences: [String] {
        get { audiences.values }
        set {
            let value = newValue; audiences = Strato_Agent_V1_IdentityPolicyAudiencesSection.with { $0.values = value }
        }
    }
    var _jsonTtlSeconds: Int? {
        get { hasTtlSeconds ? (Int(ttlSeconds)) : nil }
        set { if let value = newValue { ttlSeconds = Int64(value) } else { clearTtlSeconds() } }
    }
}
