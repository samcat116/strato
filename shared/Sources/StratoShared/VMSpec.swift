import Foundation

// MARK: - Hypervisor-Neutral VM Specification

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
    public let cpus: Int
    /// Maximum number of vCPUs (for hotplug on backends that support it).
    public let maxCpus: Int
    /// Guest memory size in bytes.
    public let memoryBytes: Int64
    /// Whether guest memory should be file-backed/shared (required by e.g. vhost-user backends).
    public let sharedMemory: Bool
    /// Whether guest memory should be backed by huge pages.
    public let hugepages: Bool
    /// How the VM boots.
    public let boot: BootSource
    /// Volumes to attach, in boot order. May be empty when the boot volume is
    /// materialized agent-side from an image (see `ImageInfo`).
    public let volumes: [VolumeSpec]
    /// Network interfaces, each referencing a logical network by name.
    public let networks: [NetworkSpec]
    /// Console preference. Drivers may realize this however their backend allows.
    public let console: ConsoleSpec?
    /// SSH public keys to authorize for the guest's default user. Injected via
    /// the backend's guest-provisioning mechanism (cloud-init `ssh_authorized_keys`
    /// for QEMU disk boot). Empty when the caller provided none.
    public let sshAuthorizedKeys: [String]

    public init(
        cpus: Int,
        maxCpus: Int? = nil,
        memoryBytes: Int64,
        sharedMemory: Bool = false,
        hugepages: Bool = false,
        boot: BootSource,
        volumes: [VolumeSpec] = [],
        networks: [NetworkSpec] = [],
        console: ConsoleSpec? = nil,
        sshAuthorizedKeys: [String] = []
    ) {
        self.cpus = cpus
        self.maxCpus = maxCpus ?? cpus
        self.memoryBytes = memoryBytes
        self.sharedMemory = sharedMemory
        self.hugepages = hugepages
        self.boot = boot
        self.volumes = volumes
        self.networks = networks
        self.console = console
        self.sshAuthorizedKeys = sshAuthorizedKeys
    }

    // Custom decode so `sshAuthorizedKeys` tolerates absence: a spec produced by
    // an older control plane (before this field existed) decodes to [] rather
    // than throwing, keeping agent↔control-plane compatible across version skew.
    // `encode(to:)` stays synthesized. All other keys remain required, matching
    // the existing wire contract.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        cpus = try c.decode(Int.self, forKey: .cpus)
        maxCpus = try c.decode(Int.self, forKey: .maxCpus)
        memoryBytes = try c.decode(Int64.self, forKey: .memoryBytes)
        sharedMemory = try c.decode(Bool.self, forKey: .sharedMemory)
        hugepages = try c.decode(Bool.self, forKey: .hugepages)
        boot = try c.decode(BootSource.self, forKey: .boot)
        volumes = try c.decode([VolumeSpec].self, forKey: .volumes)
        networks = try c.decode([NetworkSpec].self, forKey: .networks)
        console = try c.decodeIfPresent(ConsoleSpec.self, forKey: .console)
        sshAuthorizedKeys = try c.decodeIfPresent([String].self, forKey: .sshAuthorizedKeys) ?? []
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
    /// The managed volume this refers to, when it is one (nil for legacy single-disk VMs).
    public let volumeId: UUID?
    /// Stable device identifier within the VM (e.g. "disk0", "vdb").
    public let deviceName: String
    /// Host path of the volume as previously reported by the owning agent.
    /// Nil when the agent materializes the volume itself (e.g. boot volume from an
    /// image); the agent is the authority on paths and may ignore this hint.
    public let storagePath: String?
    public let readonly: Bool
    /// Explicit boot order; volumes are sent pre-sorted, this is informational.
    public let bootOrder: Int?

    public init(
        volumeId: UUID? = nil,
        deviceName: String,
        storagePath: String? = nil,
        readonly: Bool = false,
        bootOrder: Int? = nil
    ) {
        self.volumeId = volumeId
        self.deviceName = deviceName
        self.storagePath = storagePath
        self.readonly = readonly
        self.bootOrder = bootOrder
    }
}

// MARK: - Network Specification

/// A NIC attached to a logical network, referenced by name. The agent realizes
/// the attachment (tap interface, user-mode SLIRP, ...) according to its platform.
public struct NetworkSpec: Codable, Sendable {
    /// Logical network name — a human reference used for the OVN `network-name`
    /// external-id, DHCP labeling, and logging. NOT the OVN switch name: agents
    /// derive that from `networkId` so user-chosen names never enter the OVN
    /// namespace (issue #342).
    public let network: String
    /// The network's stable id. Agents derive the OVN logical switch name from it
    /// (`OVNNaming.switchName`), matching the switch the network reconciler
    /// creates. Optional so specs from a control plane that predates it still
    /// decode; the agent then falls back to naming the switch after `network`.
    public let networkId: UUID?
    public let macAddress: String?
    /// Static IP assignment, when the control plane has allocated one.
    public let ipAddress: String?
    public let netmask: String?
    /// Gateway of the logical network, when the control plane knows it.
    public let gateway: String?
    public let mtu: Int?

    /// When true, the agent programs OVN's native DHCP responder to hand the
    /// control-plane-allocated `ipAddress` (plus `dnsServers`/`gateway`/`mtu`) to
    /// the guest, and cloud-init omits static L3 config. When false (or on
    /// platforms without OVN), the guest is configured statically via cloud-init.
    /// Defaults false so older agents and non-OVN paths keep today's behavior.
    public let dhcpEnabled: Bool
    /// DNS resolvers advertised to the guest over DHCP (`dns_server` option).
    public let dnsServers: [String]
    /// DNS search domain advertised over DHCP (`domain_name` option), if set.
    public let domainName: String?
    /// DHCP lease time in seconds (`lease_time` option), if set.
    public let leaseTime: Int?

    public init(
        network: String,
        networkId: UUID? = nil,
        macAddress: String? = nil,
        ipAddress: String? = nil,
        netmask: String? = nil,
        gateway: String? = nil,
        mtu: Int? = nil,
        dhcpEnabled: Bool = false,
        dnsServers: [String] = [],
        domainName: String? = nil,
        leaseTime: Int? = nil
    ) {
        self.network = network
        self.networkId = networkId
        self.macAddress = macAddress
        self.ipAddress = ipAddress
        self.netmask = netmask
        self.gateway = gateway
        self.mtu = mtu
        self.dhcpEnabled = dhcpEnabled
        self.dnsServers = dnsServers
        self.domainName = domainName
        self.leaseTime = leaseTime
    }

    private enum CodingKeys: String, CodingKey {
        case network, networkId, macAddress, ipAddress, netmask, gateway, mtu
        case dhcpEnabled, dnsServers, domainName, leaseTime
    }

    /// Tolerates specs from an older control plane that predates the DHCP fields:
    /// missing keys fall back to the static-config defaults rather than failing
    /// the whole decode.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.network = try container.decode(String.self, forKey: .network)
        self.networkId = try container.decodeIfPresent(UUID.self, forKey: .networkId)
        self.macAddress = try container.decodeIfPresent(String.self, forKey: .macAddress)
        self.ipAddress = try container.decodeIfPresent(String.self, forKey: .ipAddress)
        self.netmask = try container.decodeIfPresent(String.self, forKey: .netmask)
        self.gateway = try container.decodeIfPresent(String.self, forKey: .gateway)
        self.mtu = try container.decodeIfPresent(Int.self, forKey: .mtu)
        self.dhcpEnabled = try container.decodeIfPresent(Bool.self, forKey: .dhcpEnabled) ?? false
        self.dnsServers = try container.decodeIfPresent([String].self, forKey: .dnsServers) ?? []
        self.domainName = try container.decodeIfPresent(String.self, forKey: .domainName)
        self.leaseTime = try container.decodeIfPresent(Int.self, forKey: .leaseTime)
    }
}

// MARK: - Console Specification

/// Console preference for the VM. Drivers decide how (and whether) to realize each.
public struct ConsoleSpec: Codable, Sendable {
    public let console: ConsoleMode
    public let serial: ConsoleMode

    public init(console: ConsoleMode, serial: ConsoleMode) {
        self.console = console
        self.serial = serial
    }
}

// MARK: - VM Info Response

/// Agent → control plane response describing a VM's spec and runtime state.
public struct VmInfo: Codable, Sendable {
    public let spec: VMSpec
    public let state: String
    public let memoryActualSize: Int64?

    public init(
        spec: VMSpec,
        state: String,
        memoryActualSize: Int64? = nil
    ) {
        self.spec = spec
        self.state = state
        self.memoryActualSize = memoryActualSize
    }
}
