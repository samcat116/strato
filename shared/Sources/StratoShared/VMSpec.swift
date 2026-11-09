import Foundation
import SwiftProtobuf

// MARK: - Hypervisor-Neutral VM Specification

/// Where a VM reads its first-boot guest configuration.
///
/// The ISO path is the compatibility fallback: the seed carries the complete
/// NoCloud payload. The IMDS path keeps only the addressing bootstrap on the
/// ISO, then follows a NoCloud `seedfrom` URL to the agent's link-local
/// metadata service for mutable meta-data and user-data.
public typealias MetadataSource = Strato_Agent_V1_MetadataSource
extension Strato_Agent_V1_MetadataSource: Codable {

    public var protocolValue: String {
        switch self {
        case .iso: return "iso"
        case .imds: return "imds"
        case .unspecified, .UNRECOGNIZED: return ""
        }
    }

    public init?(rawValue: String) {
        switch rawValue {
        case "iso": self = .iso
        case "imds": self = .imds
        default: return nil
        }
    }

    public static var knownCases: [Self] { [.iso, .imds] }

    public init(from decoder: any Swift.Decoder) throws {
        let container = try decoder.singleValueContainer()
        guard let value = Self(rawValue: try container.decode(String.self)) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unknown enum value")
        }
        self = value
    }

    public func encode(to encoder: any Swift.Encoder) throws {
        guard !protocolValue.isEmpty else {
            throw EncodingError.invalidValue(
                self, .init(codingPath: encoder.codingPath, debugDescription: "Unknown enum value"))
        }
        var container = encoder.singleValueContainer()
        try container.encode(protocolValue)
    }
}

/// Hypervisor-neutral description of a VM, sent from the control plane to an agent.
///
/// The spec carries only what the control plane can legitimately know: resource
/// sizing, the boot source, volumes and networks by reference, and a console
/// preference. All device-level realization — host paths, tap interface names,
/// sockets, machine types, queue sizing — is derived by each agent-side
/// `HypervisorService` when it translates the spec into its driver-native form
/// (QEMU arguments, Firecracker API calls, ...).
public typealias VMSpec = Strato_Agent_V1_VMSpec
extension Strato_Agent_V1_VMSpec: Codable {
    /// Nil is the historical immutable guaranteed policy.

    /// Number of vCPUs the VM boots with.
    /// Maximum number of vCPUs (for hotplug on backends that support it).
    /// Guest memory size in bytes.
    /// Maximum guest memory in bytes (for hot-add on backends that support
    /// it), mirroring how `maxCpus` bounds vCPU hot-add. Equal to
    /// `memoryBytes` when the VM was created without headroom, in which case
    /// no hot-pluggable memory device is realized at all.
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
    /// Disk requirement in bytes — the figure the scheduler gated placement on
    /// (`vm.disk`), carried so agents can account committed disk without
    /// deriving it from volumes (which don't carry sizes). Nil means the caller
    /// has no disk reservation to report.
    /// Whether guest memory should be file-backed/shared (required by e.g. vhost-user backends).
    /// Whether guest memory should be backed by huge pages.
    /// How the VM boots.
    /// Guest machine features that are not resource sizing: Secure Boot and a
    /// vTPM (issue #565). Nil selects `MachineProfile.default` (both off).
    /// Whether Strato's in-guest agent is enabled for this VM. The flag is
    /// default-off and fixes whether the domain gets a virtio-vsock device at
    /// creation; it is distinct from QEMU's conventional qga channel.
    /// Managed volumes to attach, in boot order. Every VM has exactly one boot
    /// volume; image materialization belongs to that volume's desired state.
    /// Network interfaces, each referencing a logical network by name.
    /// Console preference. Drivers may realize this however their backend allows.
    /// SSH public keys to authorize for the guest's default user. Injected via
    /// the backend's guest-provisioning mechanism (cloud-init `ssh_authorized_keys`
    /// for QEMU disk boot). Empty when the caller provided none.
    /// Caller-supplied cloud-init user data, verbatim (any format cloud-init
    /// dispatches on: `#cloud-config`, `#!` scripts, `#include`, MIME
    /// multipart, ...). The agent combines it with Strato's own provisioning
    /// config when it builds the guest-bootstrap media. Nil when the caller
    /// provided none.
    /// Where cloud-init reads the VM's guest-bootstrap documents. The
    /// initializer retains the historical full seed ISO default for low-level
    /// compatibility; the control plane explicitly supplies each persisted
    /// VM's choice. `.imds` leaves only `network-config` and a `seedfrom`
    /// meta-data stub on that ISO.

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
        metadataSource: MetadataSource = .iso,
        resourceClass: WorkloadResourceClassSnapshot? = nil,
        admittedReservation: WorkloadAdmittedReservation? = nil
    ) {
        self.init()
        self._jsonAdmittedReservation = admittedReservation
        self._jsonResourceClass = resourceClass
        self._jsonCpus = cpus
        self._jsonMaxCpus = maxCpus ?? cpus
        self._jsonMemoryBytes = memoryBytes
        self._jsonMaxMemoryBytes = max(maxMemoryBytes ?? memoryBytes, memoryBytes)
        self._jsonBalloonTargetBytes = balloonTargetBytes.map { min($0, memoryBytes) }
        self._jsonDiskBytes = diskBytes
        self._jsonSharedMemory = sharedMemory
        self._jsonHugepages = hugepages
        self._jsonBoot = boot
        self._jsonMachine = machine
        self._jsonGuestAgentEnabled = guestAgentEnabled
        self._jsonVolumes = volumes
        self._jsonNetworks = networks
        self._jsonConsole = console
        self._jsonSshAuthorizedKeys = sshAuthorizedKeys
        self._jsonUserData = userData
        self._jsonMetadataSource = metadataSource
    }

    private enum CodingKeys: String, CodingKey {
        case cpus, maxCpus, memoryBytes, maxMemoryBytes, balloonTargetBytes, diskBytes
        case sharedMemory, hugepages, boot, machine, guestAgentEnabled
        case volumes, networks, console, sshAuthorizedKeys, userData, metadataSource, resourceClass, admittedReservation
    }

    /// `guestAgentEnabled` and `metadataSource` were added after VMSpec became
    /// durable in the agent manifest. Their missing values preserve the old,
    /// safe behavior: no Strato guest agent and a complete seed ISO. Every
    /// pre-existing required field remains strict rather than acquiring a
    /// compatibility default here.
    public init(from decoder: any Swift.Decoder) throws {
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
            metadataSource: try c.decodeIfPresent(MetadataSource.self, forKey: .metadataSource) ?? .iso,
            resourceClass: try c.decodeIfPresent(WorkloadResourceClassSnapshot.self, forKey: .resourceClass),
            admittedReservation: try c.decodeIfPresent(WorkloadAdmittedReservation.self, forKey: .admittedReservation))
    }

    /// The machine profile to realize. Nil selects the explicit both-off
    /// default.
    public var effectiveMachine: MachineProfile { _jsonMachine ?? .default }

    /// A copy whose volume list records the attachments this agent has realized.
    public func withVolumes(_ volumes: [VolumeSpec]) -> VMSpec {
        var copy = self
        copy._jsonVolumes = volumes
        return copy
    }

    /// A copy whose network list records the interfaces this agent has realized.
    public func withNetworks(_ networks: [NetworkSpec]) -> VMSpec {
        var copy = self
        copy._jsonNetworks = networks
        return copy
    }

    /// A copy with the desired resource-sizing fields while retaining the
    /// attachment lists already realized by this agent.
    public func withSizing(from desired: VMSpec) -> VMSpec {
        var copy = self
        copy._jsonAdmittedReservation = desired._jsonAdmittedReservation
        copy._jsonResourceClass = desired._jsonResourceClass
        copy._jsonCpus = desired._jsonCpus
        copy._jsonMaxCpus = desired._jsonMaxCpus
        copy._jsonMemoryBytes = desired._jsonMemoryBytes
        copy._jsonMaxMemoryBytes = desired._jsonMaxMemoryBytes
        copy._jsonBalloonTargetBytes = desired._jsonBalloonTargetBytes
        copy._jsonDiskBytes = desired._jsonDiskBytes
        return copy
    }

    public func encode(to encoder: any Swift.Encoder) throws {
        try validateProtocol()
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(_jsonAdmittedReservation, forKey: .admittedReservation)
        try container.encodeIfPresent(_jsonResourceClass, forKey: .resourceClass)
        try container.encode(_jsonCpus, forKey: .cpus)
        try container.encode(_jsonMaxCpus, forKey: .maxCpus)
        try container.encode(_jsonMemoryBytes, forKey: .memoryBytes)
        try container.encode(_jsonMaxMemoryBytes, forKey: .maxMemoryBytes)
        try container.encodeIfPresent(_jsonBalloonTargetBytes, forKey: .balloonTargetBytes)
        try container.encodeIfPresent(_jsonDiskBytes, forKey: .diskBytes)
        try container.encode(_jsonSharedMemory, forKey: .sharedMemory)
        try container.encode(_jsonHugepages, forKey: .hugepages)
        try container.encode(_jsonBoot, forKey: .boot)
        try container.encodeIfPresent(_jsonMachine, forKey: .machine)
        try container.encode(_jsonGuestAgentEnabled, forKey: .guestAgentEnabled)
        try container.encode(_jsonVolumes, forKey: .volumes)
        try container.encode(_jsonNetworks, forKey: .networks)
        try container.encodeIfPresent(_jsonConsole, forKey: .console)
        try container.encode(_jsonSshAuthorizedKeys, forKey: .sshAuthorizedKeys)
        try container.encodeIfPresent(_jsonUserData, forKey: .userData)
        try container.encode(_jsonMetadataSource, forKey: .metadataSource)
    }

    var _jsonAdmittedReservation: WorkloadAdmittedReservation? {
        get { hasAdmittedReservation ? (admittedReservation) : nil }
        set { if let value = newValue { admittedReservation = value } else { clearAdmittedReservation() } }
    }
    var _jsonResourceClass: WorkloadResourceClassSnapshot? {
        get { hasResourceClass ? (resourceClass) : nil }
        set { if let value = newValue { resourceClass = value } else { clearResourceClass() } }
    }
    var _jsonCpus: Int {
        get { Int(cpus) }
        set { let value = newValue; cpus = Int64(value) }
    }
    var _jsonMaxCpus: Int {
        get { Int(maxCpus) }
        set { let value = newValue; maxCpus = Int64(value) }
    }
    var _jsonMemoryBytes: Int64 {
        get { memoryBytes }
        set { let value = newValue; memoryBytes = value }
    }
    var _jsonMaxMemoryBytes: Int64 {
        get { maxMemoryBytes }
        set { let value = newValue; maxMemoryBytes = value }
    }
    var _jsonBalloonTargetBytes: Int64? {
        get { hasBalloonTargetBytes ? (balloonTargetBytes) : nil }
        set { if let value = newValue { balloonTargetBytes = value } else { clearBalloonTargetBytes() } }
    }
    var _jsonDiskBytes: Int64? {
        get { hasDiskBytes ? (diskBytes) : nil }
        set { if let value = newValue { diskBytes = value } else { clearDiskBytes() } }
    }
    var _jsonSharedMemory: Bool {
        get { sharedMemory }
        set { let value = newValue; sharedMemory = value }
    }
    var _jsonHugepages: Bool {
        get { hugepages }
        set { let value = newValue; hugepages = value }
    }
    var _jsonBoot: BootSource {
        get { boot }
        set { let value = newValue; boot = value }
    }
    var _jsonMachine: MachineProfile? {
        get { hasMachine ? (machine) : nil }
        set { if let value = newValue { machine = value } else { clearMachine() } }
    }
    var _jsonGuestAgentEnabled: Bool {
        get { guestAgentEnabled }
        set { let value = newValue; guestAgentEnabled = value }
    }
    var _jsonVolumes: [VolumeSpec] {
        get { volumes.values }
        set { let value = newValue; volumes = Strato_Agent_V1_VMSpecVolumesSection.with { $0.values = value } }
    }
    var _jsonNetworks: [NetworkSpec] {
        get { networks.values }
        set { let value = newValue; networks = Strato_Agent_V1_VMSpecNetworksSection.with { $0.values = value } }
    }
    var _jsonConsole: ConsoleSpec? {
        get { hasConsole ? (console) : nil }
        set { if let value = newValue { console = value } else { clearConsole() } }
    }
    var _jsonSshAuthorizedKeys: [String] {
        get { sshAuthorizedKeys.values }
        set {
            let value = newValue;
            sshAuthorizedKeys = Strato_Agent_V1_VMSpecSshAuthorizedKeysSection.with { $0.values = value }
        }
    }
    var _jsonUserData: String? {
        get { hasUserData ? (userData) : nil }
        set { if let value = newValue { userData = value } else { clearUserData() } }
    }
    var _jsonMetadataSource: MetadataSource {
        get { metadataSource }
        set { let value = newValue; metadataSource = value }
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
public typealias MachineProfile = Strato_Agent_V1_MachineProfile
extension Strato_Agent_V1_MachineProfile: Codable {
    /// Whether the guest boots with UEFI Secure Boot enabled. Requires a
    /// firmware set whose variable store ships Microsoft's KEK/db enrolled;
    /// agents that cannot resolve one fail the create rather than booting the
    /// guest insecurely under a name that promises otherwise.
    /// Whether the guest gets an emulated TPM 2.0. Requires `swtpm` on the
    /// host, which agents advertise as a capability so the scheduler never
    /// places a TPM VM where it cannot be realized.

    /// Today's behavior: no Secure Boot, no vTPM.
    public static let `default` = MachineProfile(secureBoot: false, tpm: false)

    public init(secureBoot: Bool = false, tpm: Bool = false) {
        self.init()
        self._jsonSecureBoot = secureBoot
        self._jsonTpm = tpm
    }

    private enum CodingKeys: String, CodingKey { case secureBoot; case tpm }

    public init(from decoder: any Swift.Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self._jsonSecureBoot = try container.decode(Bool.self, forKey: .secureBoot)
        self._jsonTpm = try container.decode(Bool.self, forKey: .tpm)
    }

    public func encode(to encoder: any Swift.Encoder) throws {
        try validateProtocol()
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(_jsonSecureBoot, forKey: .secureBoot)
        try container.encode(_jsonTpm, forKey: .tpm)
    }

    var _jsonSecureBoot: Bool {
        get { secureBoot }
        set { let value = newValue; secureBoot = value }
    }
    var _jsonTpm: Bool {
        get { tpm }
        set { let value = newValue; tpm = value }
    }
}

// MARK: - Boot Source

/// How a VM boots. Neutral between firmware (disk image) boot and direct kernel boot.
public typealias BootSource = Strato_Agent_V1_BootSource

// MARK: - Volume Specification

/// A volume to attach, referenced by identity rather than device realization.
public typealias VolumeSpec = Strato_Agent_V1_VolumeSpec
extension Strato_Agent_V1_VolumeSpec: Codable {
    /// Stable identity of the managed volume this attachment realizes.
    /// Stable device identifier within the VM (e.g. "disk0", "vdb"). Validated
    /// by its type, so a spec cannot carry a name a hypervisor would refuse
    /// (STR-129); unique per VM, enforced by the control plane's
    /// `(vm_id, device_name)` index.
    /// Storage descriptor previously reported by the owning agent. Nil while
    /// the volume has not been realized; the receiving agent remains the
    /// authority and resolves the identity against its current inventory.
    /// Explicit boot order; volumes are sent pre-sorted, this is informational.
    /// Absolute I/O ceilings for this disk (STR-19), so a VM realized from its
    /// own spec boots with the same caps the volume lane would apply.
    ///
    /// This list and `DesiredVolumeState` are two projections of one fact, and
    /// reading a property off only one of them is how they start to disagree —
    /// the same reason the attachment itself appears in both.
    /// Requested host-cache behavior. Existing callers and manifests decode to
    /// the conservative mode, so neither optimized mode becomes a default as a
    /// side effect of introducing the policy.
    /// Agent-selected policy persisted in the VM manifest. Control-plane specs
    /// leave this nil; a QEMU agent fills it after probing the concrete disk.

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
        self.init()
        self._jsonVolumeId = volumeId
        self._jsonDeviceName = deviceName
        self._jsonAttachment = attachment
        self._jsonReadonly = readonly
        self._jsonBootOrder = bootOrder
        self._jsonIoLimits = ioLimits
        self._jsonBlockMode = blockMode
        self._jsonAppliedBlockPolicy = appliedBlockPolicy
    }

    private enum CodingKeys: String, CodingKey {
        case volumeId, deviceName, attachment, readonly, bootOrder, ioLimits
        case blockMode, appliedBlockPolicy
    }

    public init(from decoder: any Swift.Decoder) throws {
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
            volumeId: _jsonVolumeId,
            deviceName: _jsonDeviceName,
            attachment: _jsonAttachment,
            readonly: _jsonReadonly,
            bootOrder: _jsonBootOrder,
            ioLimits: _jsonIoLimits,
            blockMode: _jsonBlockMode,
            appliedBlockPolicy: policy)
    }

    public func encode(to encoder: any Swift.Encoder) throws {
        try validateProtocol()
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(_jsonVolumeId, forKey: .volumeId)
        try container.encode(_jsonDeviceName, forKey: .deviceName)
        try container.encodeIfPresent(_jsonAttachment, forKey: .attachment)
        try container.encode(_jsonReadonly, forKey: .readonly)
        try container.encodeIfPresent(_jsonBootOrder, forKey: .bootOrder)
        try container.encodeIfPresent(_jsonIoLimits, forKey: .ioLimits)
        try container.encode(_jsonBlockMode, forKey: .blockMode)
        try container.encodeIfPresent(_jsonAppliedBlockPolicy, forKey: .appliedBlockPolicy)
    }

    var _jsonVolumeId: UUID {
        get { UUID(uuidString: volumeID) ?? UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)) }
        set { let value = newValue; volumeID = value.uuidString }
    }
    var _jsonDeviceName: VolumeDeviceName {
        get { VolumeDeviceName(deviceName) ?? .disk(0) }
        set { let value = newValue; deviceName = value.rawValue }
    }
    var _jsonAttachment: DiskAttachment? {
        get { hasAttachment ? (attachment) : nil }
        set { if let value = newValue { attachment = value } else { clearAttachment() } }
    }
    var _jsonReadonly: Bool {
        get { readonly }
        set { let value = newValue; readonly = value }
    }
    var _jsonBootOrder: Int? {
        get { hasBootOrder ? (Int(bootOrder)) : nil }
        set { if let value = newValue { bootOrder = Int64(value) } else { clearBootOrder() } }
    }
    var _jsonIoLimits: VolumeIOLimits? {
        get { hasIoLimits ? (ioLimits) : nil }
        set { if let value = newValue { ioLimits = value } else { clearIoLimits() } }
    }
    var _jsonBlockMode: VolumeBlockMode {
        get { blockMode }
        set { let value = newValue; blockMode = value }
    }
    var _jsonAppliedBlockPolicy: AppliedBlockDevicePolicy? {
        get { hasAppliedBlockPolicy ? (appliedBlockPolicy) : nil }
        set { if let value = newValue { appliedBlockPolicy = value } else { clearAppliedBlockPolicy() } }
    }
}

// MARK: - Network Specification

/// A NIC attached to a logical network, referenced by id. The agent realizes
/// the attachment (tap interface, user-mode SLIRP, ...) according to its platform.
public typealias NetworkSpec = Strato_Agent_V1_NetworkSpec
extension Strato_Agent_V1_NetworkSpec: Codable {
    /// Stable control-plane identity of this interface (wire v40). Current wire
    /// producers supply it; it remains optional while the agent can hydrate
    /// persisted pre-v40 manifests.
    /// Stable guest-facing device label assigned by the control plane.
    /// Stable host-resource slot. New agents use this instead of the NIC's
    /// compact array position, so removing a middle interface cannot rename the
    /// TAP and OVN port belonging to every interface after it.
    /// Logical network name — a *human label only*, used for the OVN
    /// `network-name` external-id and logging. Never an identifier: names are
    /// unique per project, so two networks on one chassis may share one
    /// (issue #765). Nothing may be matched or keyed on it.
    /// The network's stable id: the only thing that identifies it. Agents derive
    /// every OVN object name from it (`OVNNaming.switchName`, the DHCP row's
    /// `network-id` external-id), matching what the network reconciler creates.
    /// Static IP assignment, when the control plane has allocated one.
    /// Gateway of the logical network, when the control plane knows it.
    /// Static IPv6 assignment on a dual-stack network, canonical RFC 5952
    /// form. Nil for an IPv4-only or not-yet-addressed interface.
    /// Prefix length for `ipv6Address` (64 for tenant networks). IPv6 has no
    /// dotted-netmask form, so the prefix travels as an integer.
    /// IPv6 gateway of the logical network, when dual-stack.

    /// When true, the agent programs OVN's native DHCP responder to hand the
    /// control-plane-allocated `ipAddress` (plus `dnsServers`/`gateway`/`mtu`) to
    /// the guest, and cloud-init omits static L3 config. When false (or on
    /// platforms without OVN), the guest is configured statically via cloud-init.
    /// The network's DNS resolvers. What they are depends on
    /// `resolverEnabled`: with it off these are advertised to the guest over
    /// DHCP (`dns_server` option), which is all they ever were; with it on the
    /// guest is told `NetworkResolverEndpoint.address` and these become the
    /// upstream forwarders the network's CoreDNS sends misses to (wire v37).
    /// DNS search domain advertised over DHCP (`domain_name` option), if set.
    /// DHCP lease time in seconds (`lease_time` option), if set.
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
    /// This network's own resolver addresses, v4 first — distinct per network,
    /// which is what lets the host serve every one of them from a single
    /// namespace and forward through its own egress (STR-40). Non-nil exactly
    /// when `resolverEnabled` is true.

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
        self.init()
        self._jsonInterfaceId = interfaceId
        self._jsonDeviceName = deviceName
        self._jsonOrderIndex = orderIndex
        self._jsonNetwork = network
        self._jsonNetworkId = networkId
        self._jsonMacAddress = macAddress
        self._jsonIpAddress = ipAddress
        self._jsonNetmask = netmask
        self._jsonGateway = gateway
        self._jsonIpv6Address = ipv6Address
        self._jsonIpv6PrefixLength = ipv6PrefixLength
        self._jsonGateway6 = gateway6
        self._jsonMtu = mtu
        self._jsonDhcpEnabled = dhcpEnabled
        self._jsonDnsServers = dnsServers
        self._jsonDomainName = domainName
        self._jsonLeaseTime = leaseTime
        self._jsonSecurityGroupIds = securityGroupIds
        self._jsonMetadataEnabled = metadataEnabled
        self._jsonResolverEnabled = resolverEnabled
        self._jsonResolverAddresses = resolverAddresses
    }

    private enum CodingKeys: String, CodingKey {
        case interfaceId; case deviceName; case orderIndex; case network; case networkId; case macAddress;
        case ipAddress; case netmask; case gateway; case ipv6Address; case ipv6PrefixLength; case gateway6; case mtu;
        case dhcpEnabled; case dnsServers; case domainName; case leaseTime; case securityGroupIds; case metadataEnabled;
        case resolverEnabled; case resolverAddresses
    }

    public init(from decoder: any Swift.Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self._jsonInterfaceId = try container.decodeIfPresent(UUID.self, forKey: .interfaceId)
        self._jsonDeviceName = try container.decodeIfPresent(String.self, forKey: .deviceName)
        self._jsonOrderIndex = try container.decodeIfPresent(Int.self, forKey: .orderIndex)
        self._jsonNetwork = try container.decode(String.self, forKey: .network)
        self._jsonNetworkId = try container.decode(UUID.self, forKey: .networkId)
        self._jsonMacAddress = try container.decodeIfPresent(String.self, forKey: .macAddress)
        self._jsonIpAddress = try container.decodeIfPresent(String.self, forKey: .ipAddress)
        self._jsonNetmask = try container.decodeIfPresent(String.self, forKey: .netmask)
        self._jsonGateway = try container.decodeIfPresent(String.self, forKey: .gateway)
        self._jsonIpv6Address = try container.decodeIfPresent(String.self, forKey: .ipv6Address)
        self._jsonIpv6PrefixLength = try container.decodeIfPresent(Int.self, forKey: .ipv6PrefixLength)
        self._jsonGateway6 = try container.decodeIfPresent(String.self, forKey: .gateway6)
        self._jsonMtu = try container.decodeIfPresent(Int.self, forKey: .mtu)
        self._jsonDhcpEnabled = try container.decode(Bool.self, forKey: .dhcpEnabled)
        self._jsonDnsServers = try container.decode([String].self, forKey: .dnsServers)
        self._jsonDomainName = try container.decodeIfPresent(String.self, forKey: .domainName)
        self._jsonLeaseTime = try container.decodeIfPresent(Int.self, forKey: .leaseTime)
        self._jsonSecurityGroupIds = try container.decodeIfPresent([UUID].self, forKey: .securityGroupIds)
        self._jsonMetadataEnabled = try container.decode(Bool.self, forKey: .metadataEnabled)
        self._jsonResolverEnabled = try container.decodeIfPresent(Bool.self, forKey: .resolverEnabled)
        self._jsonResolverAddresses = try container.decodeIfPresent([String].self, forKey: .resolverAddresses)
    }

    public func encode(to encoder: any Swift.Encoder) throws {
        try validateProtocol()
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(_jsonInterfaceId, forKey: .interfaceId)
        try container.encodeIfPresent(_jsonDeviceName, forKey: .deviceName)
        try container.encodeIfPresent(_jsonOrderIndex, forKey: .orderIndex)
        try container.encode(_jsonNetwork, forKey: .network)
        try container.encode(_jsonNetworkId, forKey: .networkId)
        try container.encodeIfPresent(_jsonMacAddress, forKey: .macAddress)
        try container.encodeIfPresent(_jsonIpAddress, forKey: .ipAddress)
        try container.encodeIfPresent(_jsonNetmask, forKey: .netmask)
        try container.encodeIfPresent(_jsonGateway, forKey: .gateway)
        try container.encodeIfPresent(_jsonIpv6Address, forKey: .ipv6Address)
        try container.encodeIfPresent(_jsonIpv6PrefixLength, forKey: .ipv6PrefixLength)
        try container.encodeIfPresent(_jsonGateway6, forKey: .gateway6)
        try container.encodeIfPresent(_jsonMtu, forKey: .mtu)
        try container.encode(_jsonDhcpEnabled, forKey: .dhcpEnabled)
        try container.encode(_jsonDnsServers, forKey: .dnsServers)
        try container.encodeIfPresent(_jsonDomainName, forKey: .domainName)
        try container.encodeIfPresent(_jsonLeaseTime, forKey: .leaseTime)
        try container.encodeIfPresent(_jsonSecurityGroupIds, forKey: .securityGroupIds)
        try container.encode(_jsonMetadataEnabled, forKey: .metadataEnabled)
        try container.encodeIfPresent(_jsonResolverEnabled, forKey: .resolverEnabled)
        try container.encodeIfPresent(_jsonResolverAddresses, forKey: .resolverAddresses)
    }

    var _jsonInterfaceId: UUID? {
        get {
            hasInterfaceID
                ? (UUID(uuidString: interfaceID) ?? UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))) : nil
        }
        set { if let value = newValue { interfaceID = value.uuidString } else { clearInterfaceID() } }
    }
    var _jsonDeviceName: String? {
        get { hasDeviceName ? (deviceName) : nil }
        set { if let value = newValue { deviceName = value } else { clearDeviceName() } }
    }
    var _jsonOrderIndex: Int? {
        get { hasOrderIndex ? (Int(orderIndex)) : nil }
        set { if let value = newValue { orderIndex = Int64(value) } else { clearOrderIndex() } }
    }
    var _jsonNetwork: String {
        get { network }
        set { let value = newValue; network = value }
    }
    var _jsonNetworkId: UUID {
        get { UUID(uuidString: networkID) ?? UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)) }
        set { let value = newValue; networkID = value.uuidString }
    }
    var _jsonMacAddress: String? {
        get { hasMacAddress ? (macAddress) : nil }
        set { if let value = newValue { macAddress = value } else { clearMacAddress() } }
    }
    var _jsonIpAddress: String? {
        get { hasIpAddress ? (ipAddress) : nil }
        set { if let value = newValue { ipAddress = value } else { clearIpAddress() } }
    }
    var _jsonNetmask: String? {
        get { hasNetmask ? (netmask) : nil }
        set { if let value = newValue { netmask = value } else { clearNetmask() } }
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
    var _jsonDhcpEnabled: Bool {
        get { dhcpEnabled }
        set { let value = newValue; dhcpEnabled = value }
    }
    var _jsonDnsServers: [String] {
        get { dnsServers.values }
        set {
            let value = newValue; dnsServers = Strato_Agent_V1_NetworkSpecDnsServersSection.with { $0.values = value }
        }
    }
    var _jsonDomainName: String? {
        get { hasDomainName ? (domainName) : nil }
        set { if let value = newValue { domainName = value } else { clearDomainName() } }
    }
    var _jsonLeaseTime: Int? {
        get { hasLeaseTime ? (Int(leaseTime)) : nil }
        set { if let value = newValue { leaseTime = Int64(value) } else { clearLeaseTime() } }
    }
    var _jsonSecurityGroupIds: [UUID]? {
        get {
            hasSecurityGroupIds
                ? (securityGroupIds.values.map {
                    UUID(uuidString: $0) ?? UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
                }) : nil
        }
        set {
            if let value = newValue {
                securityGroupIds = Strato_Agent_V1_NetworkSpecSecurityGroupIdsSection.with {
                    $0.values = value.map { $0.uuidString }
                }
            } else {
                clearSecurityGroupIds()
            }
        }
    }
    var _jsonMetadataEnabled: Bool {
        get { metadataEnabled }
        set { let value = newValue; metadataEnabled = value }
    }
    var _jsonResolverEnabled: Bool? {
        get { hasResolverEnabled ? (resolverEnabled) : nil }
        set { if let value = newValue { resolverEnabled = value } else { clearResolverEnabled() } }
    }
    var _jsonResolverAddresses: [String]? {
        get { hasResolverAddresses ? (resolverAddresses.values) : nil }
        set {
            if let value = newValue {
                resolverAddresses = Strato_Agent_V1_NetworkSpecResolverAddressesSection.with { $0.values = value }
            } else {
                clearResolverAddresses()
            }
        }
    }
}

// MARK: - Console Specification

/// Console preference for the VM. Drivers decide how (and whether) to realize it.
public typealias ConsoleSpec = Strato_Agent_V1_ConsoleSpec
extension Strato_Agent_V1_ConsoleSpec: Codable {
    /// Whether the guest also gets a framebuffer, and over which protocol
    /// (issue #566). Nil from callers that want today's headless behavior;
    /// consumers read nil through `effectiveGraphics`.

    public init(graphics: GraphicsMode? = nil) {
        self.init()
        self._jsonGraphics = graphics
    }

    /// The graphics mode to realize, defaulting to headless when unset.
    public var effectiveGraphics: GraphicsMode { _jsonGraphics ?? .headless }

    private enum CodingKeys: String, CodingKey { case graphics }

    public init(from decoder: any Swift.Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self._jsonGraphics = try container.decodeIfPresent(GraphicsMode.self, forKey: .graphics)
    }

    public func encode(to encoder: any Swift.Encoder) throws {
        try validateProtocol()
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(_jsonGraphics, forKey: .graphics)
    }

    var _jsonGraphics: GraphicsMode? {
        get { hasGraphics ? (graphics) : nil }
        set { if let value = newValue { graphics = value } else { clearGraphics() } }
    }
}
