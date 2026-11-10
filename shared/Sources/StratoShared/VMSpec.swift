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

}

// MARK: - Boot Source

/// How a VM boots. Neutral between firmware (disk image) boot and direct kernel boot.
public typealias BootSource = Strato_Agent_V1_BootSource

// MARK: - Volume Specification

/// A volume to attach, referenced by identity rather than device realization.
public typealias VolumeSpec = Strato_Agent_V1_VolumeSpec
extension Strato_Agent_V1_VolumeSpec: Codable {

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

}

// MARK: - Network Specification

/// A NIC attached to a logical network, referenced by id. The agent realizes
/// the attachment (tap interface, user-mode SLIRP, ...) according to its platform.
public typealias NetworkSpec = Strato_Agent_V1_NetworkSpec
extension Strato_Agent_V1_NetworkSpec: Codable {

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

}

// MARK: - Console Specification

/// Console preference for the VM. Drivers decide how (and whether) to realize it.
public typealias ConsoleSpec = Strato_Agent_V1_ConsoleSpec
extension Strato_Agent_V1_ConsoleSpec: Codable {

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

}
