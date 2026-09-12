import Foundation

// MARK: - Hypervisor-Neutral VM Specification

/// Where a VM reads its first-boot guest configuration.
///
/// The ISO path is the compatibility fallback: the seed carries the complete
/// NoCloud payload. The IMDS path keeps only the addressing bootstrap on the
/// ISO, then follows a NoCloud `seedfrom` URL to the agent's link-local
/// metadata service for mutable meta-data and user-data.
public enum MetadataSource: String, Codable, CaseIterable, Sendable {
    case iso
    case imds
}

/// Hypervisor-neutral description of a VM, sent from the control plane to an agent.
///
/// The spec carries only what the control plane can legitimately know: resource
/// sizing, the boot source, volumes and networks by reference, and a console
/// preference. All device-level realization — host paths, tap interface names,
/// sockets, machine types, queue sizing — is derived by each agent-side
/// `HypervisorService` when it translates the spec into its driver-native form
/// (QEMU arguments, Firecracker API calls, ...).
public struct VMSpec: Codable, Sendable {
    /// Number of vCPUs the VM boots with.
    public private(set) var cpus: Int
    /// Maximum number of vCPUs (for hotplug on backends that support it).
    public private(set) var maxCpus: Int
    /// Guest memory size in bytes.
    public private(set) var memoryBytes: Int64
    /// Maximum guest memory in bytes (for hot-add on backends that support
    /// it), mirroring how `maxCpus` bounds vCPU hot-add. Equal to
    /// `memoryBytes` when the VM was created without headroom, in which case
    /// no hot-pluggable memory device is realized at all.
    public private(set) var maxMemoryBytes: Int64
    /// Memory the guest may keep, in bytes, when an operator has asked for
    /// some of its grant back (issue #567 phase 2). Realized by inflating the
    /// VM's virtio-balloon device to `memoryBytes - balloonTargetBytes`, which
    /// lets the host reclaim the difference while the grant — and so the
    /// quota and scheduler reservation — stays exactly as committed.
    ///
    /// Nil means no target: the balloon stays deflated and the guest keeps
    /// everything. Always at most `memoryBytes`; ballooning cannot hand a guest
    /// more memory than it was granted (that is `maxMemoryBytes` and
    /// virtio-mem).
    public private(set) var balloonTargetBytes: Int64?
    /// Disk requirement in bytes — the figure the scheduler gated placement on
    /// (`vm.disk`), carried so agents can account committed disk without
    /// deriving it from volumes (which don't carry sizes). Nil means the caller
    /// has no disk reservation to report.
    public private(set) var diskBytes: Int64?
    /// Whether guest memory should be file-backed/shared (required by e.g. vhost-user backends).
    public let sharedMemory: Bool
    /// Whether guest memory should be backed by huge pages.
    public let hugepages: Bool
    /// How the VM boots.
    public let boot: BootSource
    /// Guest machine features that are not resource sizing: Secure Boot and a
    /// vTPM (issue #565). Nil selects `MachineProfile.default` (both off).
    public let machine: MachineProfile?
    /// Whether Strato's in-guest agent is enabled for this VM. The flag is
    /// default-off and fixes whether the domain gets a virtio-vsock device at
    /// creation; it is distinct from QEMU's conventional qga channel.
    public let guestAgentEnabled: Bool
    /// Managed volumes to attach, in boot order. Every VM has exactly one boot
    /// volume; image materialization belongs to that volume's desired state.
    public private(set) var volumes: [VolumeSpec]
    /// Network interfaces, each referencing a logical network by name.
    public private(set) var networks: [NetworkSpec]
    /// Console preference. Drivers may realize this however their backend allows.
    public let console: ConsoleSpec?
    /// SSH public keys to authorize for the guest's default user. Injected via
    /// the backend's guest-provisioning mechanism (cloud-init `ssh_authorized_keys`
    /// for QEMU disk boot). Empty when the caller provided none.
    public let sshAuthorizedKeys: [String]
    /// Caller-supplied cloud-init user data, verbatim (any format cloud-init
    /// dispatches on: `#cloud-config`, `#!` scripts, `#include`, MIME
    /// multipart, ...). The agent combines it with Strato's own provisioning
    /// config when it builds the guest-bootstrap media. Nil when the caller
    /// provided none.
    public let userData: String?
    /// Where cloud-init reads the VM's guest-bootstrap documents. The
    /// initializer retains the historical full seed ISO default for low-level
    /// compatibility; the control plane explicitly supplies each persisted
    /// VM's choice. `.imds` leaves only `network-config` and a `seedfrom`
    /// meta-data stub on that ISO.
    public let metadataSource: MetadataSource

    public init(
        cpus: Int,
        maxCpus: Int? = nil,
        memoryBytes: Int64,
        maxMemoryBytes: Int64? = nil,
        balloonTargetBytes: Int64? = nil,
        diskBytes: Int64? = nil,
        sharedMemory: Bool = false,
        hugepages: Bool = false,
        boot: BootSource,
        machine: MachineProfile? = nil,
        guestAgentEnabled: Bool = false,
        volumes: [VolumeSpec] = [],
        networks: [NetworkSpec] = [],
        console: ConsoleSpec? = nil,
        sshAuthorizedKeys: [String] = [],
        userData: String? = nil,
        metadataSource: MetadataSource = .iso
    ) {
        self.cpus = cpus
        self.maxCpus = maxCpus ?? cpus
        self.memoryBytes = memoryBytes
        self.maxMemoryBytes = max(maxMemoryBytes ?? memoryBytes, memoryBytes)
        self.balloonTargetBytes = balloonTargetBytes.map { min($0, memoryBytes) }
        self.diskBytes = diskBytes
        self.sharedMemory = sharedMemory
        self.hugepages = hugepages
        self.boot = boot
        self.machine = machine
        self.guestAgentEnabled = guestAgentEnabled
        self.volumes = volumes
        self.networks = networks
        self.console = console
        self.sshAuthorizedKeys = sshAuthorizedKeys
        self.userData = userData
        self.metadataSource = metadataSource
    }

    private enum CodingKeys: String, CodingKey {
        case cpus, maxCpus, memoryBytes, maxMemoryBytes, balloonTargetBytes, diskBytes
        case sharedMemory, hugepages, boot, machine, guestAgentEnabled
        case volumes, networks, console, sshAuthorizedKeys, userData, metadataSource
    }

    /// `guestAgentEnabled` and `metadataSource` were added after VMSpec became
    /// durable in the agent manifest. Their missing values preserve the old,
    /// safe behavior: no Strato guest agent and a complete seed ISO. Every
    /// pre-existing required field remains strict rather than acquiring a
    /// compatibility default here.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            cpus: try c.decode(Int.self, forKey: .cpus),
            maxCpus: try c.decode(Int.self, forKey: .maxCpus),
            memoryBytes: try c.decode(Int64.self, forKey: .memoryBytes),
            maxMemoryBytes: try c.decode(Int64.self, forKey: .maxMemoryBytes),
            balloonTargetBytes: try c.decodeIfPresent(Int64.self, forKey: .balloonTargetBytes),
            diskBytes: try c.decodeIfPresent(Int64.self, forKey: .diskBytes),
            sharedMemory: try c.decode(Bool.self, forKey: .sharedMemory),
            hugepages: try c.decode(Bool.self, forKey: .hugepages),
            boot: try c.decode(BootSource.self, forKey: .boot),
            machine: try c.decodeIfPresent(MachineProfile.self, forKey: .machine),
            guestAgentEnabled: try c.decodeIfPresent(Bool.self, forKey: .guestAgentEnabled) ?? false,
            volumes: try c.decode([VolumeSpec].self, forKey: .volumes),
            networks: try c.decode([NetworkSpec].self, forKey: .networks),
            console: try c.decodeIfPresent(ConsoleSpec.self, forKey: .console),
            sshAuthorizedKeys: try c.decode([String].self, forKey: .sshAuthorizedKeys),
            userData: try c.decodeIfPresent(String.self, forKey: .userData),
            metadataSource: try c.decodeIfPresent(MetadataSource.self, forKey: .metadataSource) ?? .iso)
    }

    /// The machine profile to realize. Nil selects the explicit both-off
    /// default.
    public var effectiveMachine: MachineProfile { machine ?? .default }

    /// A copy whose volume list records the attachments this agent has realized.
    public func withVolumes(_ volumes: [VolumeSpec]) -> VMSpec {
        var copy = self
        copy.volumes = volumes
        return copy
    }

    /// A copy whose network list records the interfaces this agent has realized.
    public func withNetworks(_ networks: [NetworkSpec]) -> VMSpec {
        var copy = self
        copy.networks = networks
        return copy
    }

    /// A copy with the desired resource-sizing fields while retaining the
    /// attachment lists already realized by this agent.
    public func withSizing(from desired: VMSpec) -> VMSpec {
        var copy = self
        copy.cpus = desired.cpus
        copy.maxCpus = desired.maxCpus
        copy.memoryBytes = desired.memoryBytes
        copy.maxMemoryBytes = desired.maxMemoryBytes
        copy.balloonTargetBytes = desired.balloonTargetBytes
        copy.diskBytes = desired.diskBytes
        return copy
    }

}

// MARK: - Machine Profile

/// Guest machine features beyond resource sizing (issue #565).
///
/// Both flags are what Windows 11 / Server 2025 refuse to install without, and
/// both are realized entirely agent-side: Secure Boot selects the firmware set
/// (the `.secboot` EDK2 build plus a pre-enrolled variable store) and `tpm`
/// makes the agent run a per-VM `swtpm` alongside the guest. The control plane
/// only records the *intent*; it never names a firmware file or a socket.
///
/// Defaults are both-off, so a VM that says nothing boots exactly as it did
/// before this existed.
public struct MachineProfile: Codable, Equatable, Sendable {
    /// Whether the guest boots with UEFI Secure Boot enabled. Requires a
    /// firmware set whose variable store ships Microsoft's KEK/db enrolled;
    /// agents that cannot resolve one fail the create rather than booting the
    /// guest insecurely under a name that promises otherwise.
    public let secureBoot: Bool
    /// Whether the guest gets an emulated TPM 2.0. Requires `swtpm` on the
    /// host, which agents advertise as a capability so the scheduler never
    /// places a TPM VM where it cannot be realized.
    public let tpm: Bool

    /// Today's behavior: no Secure Boot, no vTPM.
    public static let `default` = MachineProfile(secureBoot: false, tpm: false)

    public init(secureBoot: Bool = false, tpm: Bool = false) {
        self.secureBoot = secureBoot
        self.tpm = tpm
    }

}

// MARK: - Boot Source

/// How a VM boots. Neutral between firmware (disk image) boot and direct kernel boot.
public enum BootSource: Codable, Sendable {
    /// Boot from the first volume via firmware (UEFI). `firmware` optionally names a
    /// specific firmware image; when nil the agent resolves a platform default.
    case disk(firmware: String?)
    /// Direct kernel boot. Required by Firecracker; optional for QEMU.
    case directKernel(kernel: String, initramfs: String?, cmdline: String?)
}

// MARK: - Volume Specification

/// A volume to attach, referenced by identity rather than device realization.
public struct VolumeSpec: Codable, Sendable {
    /// Stable identity of the managed volume this attachment realizes.
    public let volumeId: UUID
    /// Stable device identifier within the VM (e.g. "disk0", "vdb"). Validated
    /// by its type, so a spec cannot carry a name a hypervisor would refuse
    /// (STR-129); unique per VM, enforced by the control plane's
    /// `(vm_id, device_name)` index.
    public let deviceName: VolumeDeviceName
    /// Storage descriptor previously reported by the owning agent. Nil while
    /// the volume has not been realized; the receiving agent remains the
    /// authority and resolves the identity against its current inventory.
    public let attachment: DiskAttachment?
    public let readonly: Bool
    /// Explicit boot order; volumes are sent pre-sorted, this is informational.
    public let bootOrder: Int?
    /// Absolute I/O ceilings for this disk (STR-19), so a VM realized from its
    /// own spec boots with the same caps the volume lane would apply.
    ///
    /// This list and `DesiredVolumeState` are two projections of one fact, and
    /// reading a property off only one of them is how they start to disagree —
    /// the same reason the attachment itself appears in both.
    public let ioLimits: VolumeIOLimits?
    /// Requested host-cache behavior. Existing callers and manifests decode to
    /// the conservative mode, so neither optimized mode becomes a default as a
    /// side effect of introducing the policy.
    public let blockMode: VolumeBlockMode
    /// Agent-selected policy persisted in the VM manifest. Control-plane specs
    /// leave this nil; a QEMU agent fills it after probing the concrete disk.
    public let appliedBlockPolicy: AppliedBlockDevicePolicy?

    public init(
        volumeId: UUID,
        deviceName: VolumeDeviceName,
        attachment: DiskAttachment? = nil,
        readonly: Bool = false,
        bootOrder: Int? = nil,
        ioLimits: VolumeIOLimits? = nil,
        blockMode: VolumeBlockMode = .conservative,
        appliedBlockPolicy: AppliedBlockDevicePolicy? = nil
    ) {
        self.volumeId = volumeId
        self.deviceName = deviceName
        self.attachment = attachment
        self.readonly = readonly
        self.bootOrder = bootOrder
        self.ioLimits = ioLimits
        self.blockMode = blockMode
        self.appliedBlockPolicy = appliedBlockPolicy
    }

    private enum CodingKeys: String, CodingKey {
        case volumeId, deviceName, attachment, readonly, bootOrder, ioLimits
        case blockMode, appliedBlockPolicy
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            volumeId: try c.decode(UUID.self, forKey: .volumeId),
            deviceName: try c.decode(VolumeDeviceName.self, forKey: .deviceName),
            attachment: try c.decodeIfPresent(DiskAttachment.self, forKey: .attachment),
            readonly: try c.decode(Bool.self, forKey: .readonly),
            bootOrder: try c.decodeIfPresent(Int.self, forKey: .bootOrder),
            ioLimits: try c.decodeIfPresent(VolumeIOLimits.self, forKey: .ioLimits),
            blockMode: try c.decodeIfPresent(VolumeBlockMode.self, forKey: .blockMode) ?? .conservative,
            appliedBlockPolicy: try c.decodeIfPresent(
                AppliedBlockDevicePolicy.self, forKey: .appliedBlockPolicy))
    }

    /// A copy carrying the policy this agent actually installed. Used only by
    /// the agent manifest/adoption path; desired-state producers leave it nil.
    public func withAppliedBlockPolicy(
        _ policy: AppliedBlockDevicePolicy?
    ) -> VolumeSpec {
        VolumeSpec(
            volumeId: volumeId,
            deviceName: deviceName,
            attachment: attachment,
            readonly: readonly,
            bootOrder: bootOrder,
            ioLimits: ioLimits,
            blockMode: blockMode,
            appliedBlockPolicy: policy)
    }
}

// MARK: - Network Specification

/// A NIC attached to a logical network, referenced by id. The agent realizes
/// the attachment (tap interface, user-mode SLIRP, ...) according to its platform.
public struct NetworkSpec: Codable, Equatable, Sendable {
    /// Stable control-plane identity of this interface (wire v40). Current wire
    /// producers supply it; it remains optional while the agent can hydrate
    /// persisted pre-v40 manifests.
    public let interfaceId: UUID?
    /// Stable guest-facing device label assigned by the control plane.
    public let deviceName: String?
    /// Stable host-resource slot. New agents use this instead of the NIC's
    /// compact array position, so removing a middle interface cannot rename the
    /// TAP and OVN port belonging to every interface after it.
    public let orderIndex: Int?
    /// Logical network name — a *human label only*, used for the OVN
    /// `network-name` external-id and logging. Never an identifier: names are
    /// unique per project, so two networks on one chassis may share one
    /// (issue #765). Nothing may be matched or keyed on it.
    public let network: String
    /// The network's stable id: the only thing that identifies it. Agents derive
    /// every OVN object name from it (`OVNNaming.switchName`, the DHCP row's
    /// `network-id` external-id), matching what the network reconciler creates.
    public let networkId: UUID
    public let macAddress: String?
    /// Static IP assignment, when the control plane has allocated one.
    public let ipAddress: String?
    public let netmask: String?
    /// Gateway of the logical network, when the control plane knows it.
    public let gateway: String?
    /// Static IPv6 assignment on a dual-stack network, canonical RFC 5952
    /// form. Nil for an IPv4-only or not-yet-addressed interface.
    public let ipv6Address: String?
    /// Prefix length for `ipv6Address` (64 for tenant networks). IPv6 has no
    /// dotted-netmask form, so the prefix travels as an integer.
    public let ipv6PrefixLength: Int?
    /// IPv6 gateway of the logical network, when dual-stack.
    public let gateway6: String?
    public let mtu: Int?

    /// When true, the agent programs OVN's native DHCP responder to hand the
    /// control-plane-allocated `ipAddress` (plus `dnsServers`/`gateway`/`mtu`) to
    /// the guest, and cloud-init omits static L3 config. When false (or on
    /// platforms without OVN), the guest is configured statically via cloud-init.
    public let dhcpEnabled: Bool
    /// The network's DNS resolvers. What they are depends on
    /// `resolverEnabled`: with it off these are advertised to the guest over
    /// DHCP (`dns_server` option), which is all they ever were; with it on the
    /// guest is told `NetworkResolverEndpoint.address` and these become the
    /// upstream forwarders the network's CoreDNS sends misses to (wire v37).
    public let dnsServers: [String]
    /// DNS search domain advertised over DHCP (`domain_name` option), if set.
    public let domainName: String?
    /// DHCP lease time in seconds (`lease_time` option), if set.
    public let leaseTime: Int?
    /// Security groups this NIC belongs to. The agent adds the NIC's logical
    /// switch port to each group's OVN port group (and to the global drop
    /// group) — port-group *membership* is per-workload and owned by the
    /// hosting agent, while the groups' ACLs are authored by the topology
    /// authority from `DesiredStateMessage.securityGroups`. Nil means the NIC
    /// is unmanaged: the port joins no groups, including the drop group. When
    /// present the list is never empty — the control plane enforces the
    /// ≥1-group invariant.
    ///
    /// VM and sandbox NICs carry membership on identical terms (STR-102);
    /// nothing here distinguishes them. A sandbox's NIC reaches the wire only
    /// on an agent that advertised `sandboxNetworkingCapable` (STR-103), so a
    /// sandbox's membership is always *authored* but only sometimes *sent*.
    public let securityGroupIds: [UUID]?
    /// Whether this NIC's network publishes the instance metadata service.
    ///
    /// The same setting travels on `DesiredNetworkState.metadataEnabled`, which
    /// is what authors the OVN `localport`; this per-NIC copy is what reaches
    /// the *chassis* side. A sited agent that is not its site's network
    /// controller receives an empty `networks` list (it may not author
    /// topology), yet it still has to materialize the metadata address in a
    /// local namespace for its own guests — so the only input it has is its own
    /// workloads' specs. Same shape as `securityGroupIds`, which is per-NIC for
    /// the same "this host owns it even without topology authority" reason.
    ///
    public let metadataEnabled: Bool
    /// Whether this NIC's network publishes the per-network DNS resolver
    /// (STR-40, wire v37).
    ///
    /// Here for exactly `metadataEnabled`'s reason:
    /// `DesiredNetworkState.resolverEnabled` authors the OVN `localport` and the
    /// DHCP row, and this per-NIC copy is what reaches a sited non-authority
    /// agent, whose `networks` list is empty because it may not author topology
    /// but which still has to materialize the resolver address — in its *host*
    /// namespace, on that port's own OVS interface — and serve it from the
    /// host's CoreDNS, for its own guests.
    ///
    /// The forwarders and search domain that CoreDNS needs are already on this
    /// spec as `dnsServers` and `domainName`, so this flag is the only addition.
    ///
    /// Nil means the sender has no service opinion; the agent converges nothing
    /// rather than reading silence as "tear down".
    public let resolverEnabled: Bool?
    /// This network's own resolver addresses, v4 first — distinct per network,
    /// which is what lets the host serve every one of them from a single
    /// namespace and forward through its own egress (STR-40). Non-nil exactly
    /// when `resolverEnabled` is true.
    public let resolverAddresses: [String]?

    public init(
        interfaceId: UUID? = nil,
        deviceName: String? = nil,
        orderIndex: Int? = nil,
        network: String,
        networkId: UUID,
        macAddress: String? = nil,
        ipAddress: String? = nil,
        netmask: String? = nil,
        gateway: String? = nil,
        ipv6Address: String? = nil,
        ipv6PrefixLength: Int? = nil,
        gateway6: String? = nil,
        mtu: Int? = nil,
        dhcpEnabled: Bool = false,
        dnsServers: [String] = [],
        domainName: String? = nil,
        leaseTime: Int? = nil,
        securityGroupIds: [UUID]? = nil,
        metadataEnabled: Bool = false,
        resolverEnabled: Bool? = nil,
        resolverAddresses: [String]? = nil
    ) {
        self.interfaceId = interfaceId
        self.deviceName = deviceName
        self.orderIndex = orderIndex
        self.network = network
        self.networkId = networkId
        self.macAddress = macAddress
        self.ipAddress = ipAddress
        self.netmask = netmask
        self.gateway = gateway
        self.ipv6Address = ipv6Address
        self.ipv6PrefixLength = ipv6PrefixLength
        self.gateway6 = gateway6
        self.mtu = mtu
        self.dhcpEnabled = dhcpEnabled
        self.dnsServers = dnsServers
        self.domainName = domainName
        self.leaseTime = leaseTime
        self.securityGroupIds = securityGroupIds
        self.metadataEnabled = metadataEnabled
        self.resolverEnabled = resolverEnabled
        self.resolverAddresses = resolverAddresses
    }

}

// MARK: - Console Specification

/// Console preference for the VM. Drivers decide how (and whether) to realize it.
public struct ConsoleSpec: Codable, Sendable {
    /// Whether the guest also gets a framebuffer, and over which protocol
    /// (issue #566). Nil from callers that want today's headless behavior;
    /// consumers read nil through `effectiveGraphics`.
    public let graphics: GraphicsMode?

    public init(graphics: GraphicsMode? = nil) {
        self.graphics = graphics
    }

    /// The graphics mode to realize, defaulting to headless when unset.
    public var effectiveGraphics: GraphicsMode { graphics ?? .headless }
}
