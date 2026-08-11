import Foundation

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
/// `serviceEnabled` is the one deliberate exception, and it earns the exception
/// by being the field that decides whether any of the rest is disclosed at all
/// — see its own doc for why it rides here rather than beside `metadata` on
/// `DesiredVMState`.
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
public struct InstanceMetadata: Codable, Sendable, Equatable {
    /// The VM's id — the same UUID as `DesiredVMState.vmId`, restated here so a
    /// renderer never has to reach outside the metadata it was handed.
    public let instanceId: UUID
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
    public let hostname: String?
    /// The project owning the VM. Renderers expose it as the tenancy
    /// identifier (EC2's account/owner slot); it is never an authorization
    /// input — the IMDS serves whichever guest can reach it.
    public let projectId: UUID
    /// The VM's environment within its project (`production`, `staging`, ...),
    /// when the project defines environments. Nil rather than the project's
    /// default: the renderer decides what an unset environment looks like.
    public let environment: String?
    /// Placement, coarse: conventionally the VM's site name. One of the EC2
    /// renderer's two placement keys.
    ///
    /// Populated here regardless of policy — whether a guest is *told* where it
    /// runs is the renderer's call, not the model's, so that the decision lives
    /// in one place instead of being baked into every assembler.
    public let region: String?
    /// Placement, fine: conventionally the name of the agent hosting the VM.
    /// The other EC2 placement key, with the same disclosure caveat as
    /// `region` — it names a specific host, so a renderer that emits it is
    /// telling the guest which machine it shares.
    public let availabilityZone: String?
    /// The VM's NICs, in the order the control plane realized them (`net0`,
    /// `net1`, ...). Empty for a VM with no interfaces; never partially
    /// populated — a NIC the control plane knows about appears here even if the
    /// guest has not configured it.
    public let nics: [MetadataNIC]
    /// SSH public keys to authorize for the guest's default user, the same set
    /// carried on `VMSpec.sshAuthorizedKeys`. Duplicated deliberately: the spec
    /// copy is what a *boot-time* provisioner consumes, this copy is what the
    /// running guest can re-read after an operator rotates a key.
    public let sshAuthorizedKeys: [String]
    /// Caller-supplied cloud-init user data, verbatim and unvalidated beyond
    /// what the create request already checked (see `CloudInitUserDataFormat`).
    /// Nil when the caller supplied none — which is not the same as empty, and
    /// renderers must keep the distinction: cloud-init treats a zero-length
    /// user-data document as "provided, and does nothing".
    public let userData: String?
    /// Vendor data — Strato's own provisioning document, distinct from the
    /// caller's `userData` so that platform config and tenant config never
    /// have to be merged into one payload (cloud-init consumes them as
    /// separate sources with separate precedence). Nil when the platform has
    /// nothing to say.
    public let vendorData: String?
    /// Free-form key/value labels from the VM's tags. Ordinary metadata, not
    /// identity: nothing may authorize on a tag, because a guest reads its own
    /// tags and an operator can set them to anything.
    public let tags: [String: String]
    /// How, and whether, the IMDS may vend this instance a SPIFFE identity
    /// (phase 3). Nil means it may not — the conservative reading, and the one
    /// every VM gets until identity ships.
    public let identity: IdentityPolicy?

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
    public let serviceEnabled: Bool

    /// Whether the service should answer this instance.
    public var isServiceEnabled: Bool { serviceEnabled }

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
        tags: [String: String] = [:],
        identity: IdentityPolicy? = nil,
        serviceEnabled: Bool
    ) {
        self.instanceId = instanceId
        self.hostname = hostname
        self.projectId = projectId
        self.environment = environment
        self.region = region
        self.availabilityZone = availabilityZone
        self.nics = nics
        self.sshAuthorizedKeys = sshAuthorizedKeys
        self.userData = userData
        self.vendorData = vendorData
        self.tags = tags
        self.identity = identity
        self.serviceEnabled = serviceEnabled
    }

    // Custom decode so the collections tolerate absence, matching `VMSpec`:
    // a control plane that omits an empty list yields []/[:] rather than
    // failing the whole sync for that agent. Everything else is `Optional` and
    // so tolerates absence already. `encode(to:)` stays synthesized.
    //
    // The identity fields and service policy are required current-contract
    // invariants. A missing service policy must fail the sync instead of
    // silently enabling metadata for a VM whose operator disabled it.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        instanceId = try c.decode(UUID.self, forKey: .instanceId)
        hostname = try c.decodeIfPresent(String.self, forKey: .hostname)
        projectId = try c.decode(UUID.self, forKey: .projectId)
        environment = try c.decodeIfPresent(String.self, forKey: .environment)
        region = try c.decodeIfPresent(String.self, forKey: .region)
        availabilityZone = try c.decodeIfPresent(String.self, forKey: .availabilityZone)
        nics = try c.decodeIfPresent([MetadataNIC].self, forKey: .nics) ?? []
        sshAuthorizedKeys = try c.decodeIfPresent([String].self, forKey: .sshAuthorizedKeys) ?? []
        userData = try c.decodeIfPresent(String.self, forKey: .userData)
        vendorData = try c.decodeIfPresent(String.self, forKey: .vendorData)
        tags = try c.decodeIfPresent([String: String].self, forKey: .tags) ?? [:]
        identity = try c.decodeIfPresent(IdentityPolicy.self, forKey: .identity)
        serviceEnabled = try c.decode(Bool.self, forKey: .serviceEnabled)
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
public struct MetadataNIC: Codable, Sendable, Equatable {
    /// Stable device name (`net0`, `net1`, ...) from the interface's
    /// `deviceName`, ordered by `orderIndex`. Stable across reboots and
    /// re-realization, which the guest-visible kernel name is not.
    public let deviceName: String
    /// The NIC's MAC address. The EC2 renderer keys its whole interface tree on
    /// this (`network/interfaces/macs/<mac>/`), and it is how a guest matches an
    /// entry here to one of its own links.
    public let macAddress: String
    /// The logical network the NIC attaches to.
    public let networkId: UUID
    /// The network's name — a human label for the guest, exactly as on
    /// `NetworkSpec.network`. Names are unique only within a project, so
    /// nothing may key on it.
    public let networkName: String
    /// The allocated IPv4 address, or nil on a NIC with no v4 assignment.
    public let ipAddress: String?
    /// Prefix length of `ipAddress` within its subnet (24 for a /24).
    public let prefixLength: Int?
    /// The network's IPv4 gateway, when it has L3.
    public let gateway: String?
    /// The allocated IPv6 address in canonical RFC 5952 form, on a dual-stack
    /// network.
    public let ipv6Address: String?
    /// Prefix length of `ipv6Address` (64 for tenant networks).
    public let ipv6PrefixLength: Int?
    /// The network's IPv6 gateway, when dual-stack.
    public let gateway6: String?
    /// Link MTU, when the network sets one.
    public let mtu: Int?
    /// Resolvers for this NIC's network; may be mixed-family, like
    /// `DesiredNetworkState.dnsServers`. Carried because the IMDS has to be
    /// able to tell a guest everything the seed ISO's static network config
    /// used to, on networks where DHCP is off.
    public let dnsServers: [String]
    /// DNS search domain for this NIC's network, when set.
    public let domainName: String?
    /// Whether this NIC should ask the network's DHCP responder for its guest
    /// configuration. The NoCloud-net renderer needs the same decision the
    /// seed ISO renderer receives on `NetworkSpec`; an allocated address alone
    /// cannot distinguish DHCP from static configuration.
    public let dhcpEnabled: Bool
    /// Whether this NIC's network publishes the link-local metadata endpoint.
    /// Used only to render the on-link routes the existing seed ISO carries.
    public let metadataEnabled: Bool
    /// This network's link-local resolver addresses, or an empty list when the
    /// resolver is unavailable. When present these replace `dnsServers` in
    /// static guest configuration, exactly as in the seed ISO renderer.
    public let resolverAddresses: [String]

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
        self.deviceName = deviceName
        self.macAddress = macAddress
        self.networkId = networkId
        self.networkName = networkName
        self.ipAddress = ipAddress
        self.prefixLength = prefixLength
        self.gateway = gateway
        self.ipv6Address = ipv6Address
        self.ipv6PrefixLength = ipv6PrefixLength
        self.gateway6 = gateway6
        self.mtu = mtu
        self.dnsServers = dnsServers
        self.domainName = domainName
        self.dhcpEnabled = dhcpEnabled
        self.metadataEnabled = metadataEnabled
        self.resolverAddresses = resolverAddresses
    }

    // `dnsServers` tolerates absence for the same reason the collections on
    // `InstanceMetadata` do — a sender with nothing to put in a list may omit
    // it rather than fail the receiving agent's whole sync. Everything else is
    // either identifying (and required) or already `Optional`.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        deviceName = try c.decode(String.self, forKey: .deviceName)
        macAddress = try c.decode(String.self, forKey: .macAddress)
        networkId = try c.decode(UUID.self, forKey: .networkId)
        networkName = try c.decode(String.self, forKey: .networkName)
        ipAddress = try c.decodeIfPresent(String.self, forKey: .ipAddress)
        prefixLength = try c.decodeIfPresent(Int.self, forKey: .prefixLength)
        gateway = try c.decodeIfPresent(String.self, forKey: .gateway)
        ipv6Address = try c.decodeIfPresent(String.self, forKey: .ipv6Address)
        ipv6PrefixLength = try c.decodeIfPresent(Int.self, forKey: .ipv6PrefixLength)
        gateway6 = try c.decodeIfPresent(String.self, forKey: .gateway6)
        mtu = try c.decodeIfPresent(Int.self, forKey: .mtu)
        dnsServers = try c.decodeIfPresent([String].self, forKey: .dnsServers) ?? []
        domainName = try c.decodeIfPresent(String.self, forKey: .domainName)
        dhcpEnabled = try c.decodeIfPresent(Bool.self, forKey: .dhcpEnabled) ?? false
        metadataEnabled = try c.decodeIfPresent(Bool.self, forKey: .metadataEnabled) ?? false
        resolverAddresses = try c.decodeIfPresent([String].self, forKey: .resolverAddresses) ?? []
    }

    /// `ipAddress` with its prefix, e.g. `10.0.0.5/24` — the form cloud-init's
    /// network-config v2 wants. Nil unless both halves are present, since a
    /// half-known address is worse than none.
    public var ipv4CIDR: String? {
        guard let ipAddress, let prefixLength else { return nil }
        return "\(ipAddress)/\(prefixLength)"
    }

    /// `ipv6Address` with its prefix, e.g. `fd12:3456:789a::5/64`.
    public var ipv6CIDR: String? {
        guard let ipv6Address, let ipv6PrefixLength else { return nil }
        return "\(ipv6Address)/\(ipv6PrefixLength)"
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
public struct IdentityPolicy: Codable, Sendable, Equatable {
    /// The SPIFFE ID the instance may be issued documents for:
    /// `spiffe://<trust-domain>/vm/<vm-uuid>`, the key the VM's workload
    /// registration is filed under (STR-55). Authored by the control plane; the
    /// agent never derives or extends it.
    public let spiffeId: String
    /// Audiences the IMDS may mint JWT-SVIDs for. Empty means none — a guest
    /// asking for an audience outside this list is refused rather than served
    /// a token nothing will accept.
    public let audiences: [String]
    /// Upper bound, in seconds, on the lifetime of a document handed to the
    /// guest. Nil defers to the issuer's own default rather than meaning
    /// "unbounded"; an identity document with no expiry is never the intent.
    public let ttlSeconds: Int?

    public init(spiffeId: String, audiences: [String] = [], ttlSeconds: Int? = nil) {
        self.spiffeId = spiffeId
        self.audiences = audiences
        self.ttlSeconds = ttlSeconds
    }

    // Tolerates an absent `audiences`, matching the rest of the metadata
    // collections; `spiffeId` stays required, since a policy that names no
    // identity authorizes nothing.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        spiffeId = try c.decode(String.self, forKey: .spiffeId)
        audiences = try c.decodeIfPresent([String].self, forKey: .audiences) ?? []
        ttlSeconds = try c.decodeIfPresent(Int.self, forKey: .ttlSeconds)
    }
}
