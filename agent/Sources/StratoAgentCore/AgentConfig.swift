import Foundation
import Configuration
import Logging
import StratoShared
import Toml
import TomlConfiguration

public struct AgentConfig {
    public let controlPlaneURL: String
    public let logLevel: AgentLogLevel?
    public let networkMode: NetworkMode?
    public let ovnEncapIP: String?
    public let ovnEncapType: String?
    public let ovnRemote: String?
    public let ovnBootstrapChassis: Bool?
    /// OVN northbound DB connection string in OVN syntax: `unix:<path>`,
    /// `tcp:<host>:<port>`, or `ssl:<host>:<port>`. Nil means the legacy
    /// per-node local socket. Point every agent in a site at the site's
    /// shared ovn-central (`tcp:<central-host>:6641`) for multi-node
    /// networks (issue #343); `ovn_remote` is the southbound counterpart
    /// consumed by ovn-controller.
    public let ovnNorthbound: String?
    /// TLS material for an `ssl:` `ovn_northbound` endpoint. Requires
    /// `ovn_northbound` to actually be `ssl:` — rejected at load time
    /// otherwise, so TLS settings can never be silently ignored.
    public let ovnNorthboundTLS: OVNNorthboundTLSConfig?
    public let enableHVF: Bool?
    public let enableKVM: Bool?
    /// Fixed QEMU process allowance above current guest RAM. This only sizes
    /// libvirt's cgroup ceiling; it is not a placement reservation.
    public let qemuMemoryOverheadMB: Int?
    public let vmStoragePath: String?
    /// Where managed volume disks and their snapshots live. Nil means the
    /// platform default (`/var/lib/strato/volumes` on Linux) — see
    /// `FileSystemStorageBackend.defaultStoragePath`.
    public let volumeStoragePath: String?
    /// Where downloaded VM images (disk images, kernels, rootfs artifacts)
    /// are cached between VM launches. Nil means the platform default
    /// (`/var/cache/strato/images` on Linux).
    public let imageCacheDir: String?
    /// Size budget for the VM image cache in GB. When set, least-recently-
    /// used images are evicted to keep the cache under this budget; unset
    /// means unbounded.
    public let imageCacheMaxSizeGB: Int?
    /// Where materialized sandbox rootfs images are cached. Nil means the
    /// platform default (`/var/cache/strato/sandbox-images` on Linux).
    public let sandboxImageCacheDir: String?
    /// Size budget for the sandbox rootfs cache in GB, enforced the same way
    /// (on top of the idle-TTL eviction that cache always applies).
    public let sandboxImageCacheMaxSizeGB: Int?
    /// Legacy monolithic firmware images, attached with `-bios`. Still honored
    /// as the fallback when no split CODE/VARS pair resolves, so hosts that
    /// boot today keep booting — but such VMs have no persistent UEFI variable
    /// store (issue #565).
    public let firmwarePathARM64: String?
    public let firmwarePathX86_64: String?
    /// Split EDK2 firmware for this host's architecture: the read-only code
    /// image and the variable-store template copied per VM. Both must be set
    /// together to take effect; unset means the platform's default candidates.
    public let firmwareCodePath: String?
    public let firmwareVarsTemplate: String?
    /// The signed EDK2 build and its pre-enrolled variable store, used for VMs
    /// that ask for Secure Boot. Unset means the platform defaults; when
    /// neither resolves, Secure Boot VMs are refused rather than booted without
    /// it.
    public let secureBootFirmwareCodePath: String?
    public let secureBootFirmwareVarsTemplate: String?
    public let spiffe: SPIFFEConfig?
    public let firecrackerBinaryPath: String?
    public let firecrackerSocketDir: String?
    /// Where the sandbox guest base image (kernel + init/guest agent, issue
    /// #419) is installed. Its presence — together with a passing Firecracker
    /// probe — is what makes the agent advertise the sandbox-runtime
    /// capability at registration (issue #415).
    public let sandboxGuestImagePath: String?
    /// Whether sandboxes run inside Firecracker's jailer (issue #425):
    /// `auto` (default — jail when root + jailer binary), `required`
    /// (production posture: no jailer, no sandbox capability), or `disabled`.
    public let sandboxJailerMode: SandboxJailerMode?
    public let sandboxJailerBinaryPath: String?
    /// Base directory for per-sandbox chroots. Defaults to `<vm_storage_dir>/jailer`
    /// (each jail holds a full writable rootfs copy, so it belongs on VM storage).
    public let sandboxJailerChrootDir: String?
    /// First uid/gid of the per-sandbox uid range (65536 ids). Default
    /// 0x70000000 (1879048192).
    public let sandboxJailerUidBase: UInt32?
    /// Warm start (issue #426): provision new sandboxes by restoring a
    /// per-(image, machine shape) template snapshot instead of cold-booting.
    /// Default true; every warm failure falls back to a cold boot.
    public let sandboxWarmStart: Bool?
    /// Size budget for the warm-snapshot template cache in GB (entries are
    /// roughly guest-memory sized). Default 20.
    public let sandboxWarmCacheMaxSizeGB: Int?
    public let hypervisorType: HypervisorType?
    /// Site uplink for OVN SNAT egress (issue #342). When nil, routers +
    /// east-west are realized but no SNAT/uplink.
    public let ovnUplink: OVNUplinkConfig?
    /// OVN native dynamic routing for north-south advertisement of floating
    /// IPs and tenant routes over BGP/FRR (issue #344). Requires OVN ≥ 25.03
    /// and an operator-configured FRR on the egress host; nil or disabled
    /// strips any previously applied `dynamic-routing*` options.
    public let ovnDynamicRouting: OVNDynamicRoutingConfig?
    /// Per-network DNS resolver settings (STR-40). Nil means the built-in
    /// defaults: enabled, CoreDNS discovered on `PATH`-adjacent locations,
    /// config under `/var/lib/strato/resolver`, and AWS's 1024 pps ceiling.
    public let resolver: NetworkResolverConfig?
    /// Simulation ("dummy agent") settings. Nil (or disabled) means a normal
    /// agent that drives real hypervisor/network/storage backends.
    public let simulation: SimulationConfig?
    /// Blast-radius guard (STR-98): the absolute number of confirmed teardowns
    /// one sync may perform before the percentage half of the guard applies at
    /// all. Default 3.
    public let reconcileTeardownMinimum: Int?
    /// The percentage of this host's present workloads above which a sync's
    /// confirmed teardowns are refused. Default 25.
    public let reconcileTeardownPercent: Int?
    /// Operator override for a deliberate host drain: converge a sync's
    /// teardowns however large the batch. Default false — a bug or a stale
    /// control-plane database must not be able to empty a host, while a real
    /// drain can afford the flag.
    public let allowBulkTeardown: Bool?
    /// How often the poller must fetch *without* `If-None-Match`, in seconds.
    /// Default 300. This is the correctness invariant of the pull transport,
    /// not a tuning knob: conditional requests are a bandwidth optimization,
    /// and this bounds how long a wrong "not modified" could strand the agent.
    /// Raising it trades convergence-of-last-resort latency for very little
    /// bandwidth; setting it very low mostly just wastes assemblies.
    public let desiredStateFullRefetchSeconds: Int?
    /// Whether to serve instance metadata to guests on `169.254.169.254` /
    /// `[fd00:ec2::254]` (STR-56). Default true. Turning it off leaves the
    /// dataplane in place — the localport, the namespaces and the advertised
    /// routes are all a *network* property (`metadataEnabled`) — and only stops
    /// this host answering, which a guest sees as a refused connection.
    public let metadataService: Bool?
    /// IP TTL / hop limit on metadata responses. Default 1, which is what stops
    /// a guest relaying metadata off-box: the address is one L2 hop away, so a
    /// reply that crosses any router dies. Raising it is a deliberate weakening
    /// and exists only for a topology that puts a router between guest and host,
    /// which Strato's does not.
    public let metadataResponseHopLimit: Int?

    /// Whether this host answers guests' metadata requests.
    public var servesInstanceMetadata: Bool { metadataService ?? true }

    /// The hop limit to apply to metadata responses.
    public var metadataHopLimit: Int { metadataResponseHopLimit ?? 1 }

    public static let defaultQEMUMemoryOverheadMB = 512
    public static let qemuMemoryOverheadRange = 128...4096

    public var qemuMemoryOverheadBytes: Int64 {
        Int64(qemuMemoryOverheadMB ?? Self.defaultQEMUMemoryOverheadMB) * 1024 * 1024
    }

    /// The forced-unconditional-fetch interval, floored at one second so a
    /// zero or negative value in a config file cannot turn the loop into a
    /// spin.
    public var desiredStateFullRefetchInterval: Duration {
        guard let seconds = desiredStateFullRefetchSeconds else {
            return DesiredStatePoller<ContinuousClock>.defaultFullRefetchInterval
        }
        return .seconds(max(1, seconds))
    }

    /// The teardown blast-radius guard this configuration asks for.
    public var teardownGuard: TeardownGuard {
        TeardownGuard(
            minimumWorkloads: reconcileTeardownMinimum ?? TeardownGuard.defaultMinimumWorkloads,
            percentOfPresent: reconcileTeardownPercent ?? TeardownGuard.defaultPercentOfPresent,
            allowBulkTeardown: allowBulkTeardown ?? false)
    }

    package init(
        controlPlaneURL: String,
        logLevel: AgentLogLevel? = nil,
        networkMode: NetworkMode? = nil,
        ovnEncapIP: String? = nil,
        ovnEncapType: String? = nil,
        ovnRemote: String? = nil,
        ovnBootstrapChassis: Bool? = nil,
        ovnNorthbound: String? = nil,
        ovnNorthboundTLS: OVNNorthboundTLSConfig? = nil,
        enableHVF: Bool? = nil,
        enableKVM: Bool? = nil,
        qemuMemoryOverheadMB: Int? = nil,
        vmStoragePath: String? = nil,
        volumeStoragePath: String? = nil,
        imageCacheDir: String? = nil,
        imageCacheMaxSizeGB: Int? = nil,
        sandboxImageCacheDir: String? = nil,
        sandboxImageCacheMaxSizeGB: Int? = nil,
        firmwarePathARM64: String? = nil,
        firmwarePathX86_64: String? = nil,
        firmwareCodePath: String? = nil,
        firmwareVarsTemplate: String? = nil,
        secureBootFirmwareCodePath: String? = nil,
        secureBootFirmwareVarsTemplate: String? = nil,
        spiffe: SPIFFEConfig? = nil,
        firecrackerBinaryPath: String? = nil,
        firecrackerSocketDir: String? = nil,
        sandboxGuestImagePath: String? = nil,
        sandboxJailerMode: SandboxJailerMode? = nil,
        sandboxJailerBinaryPath: String? = nil,
        sandboxJailerChrootDir: String? = nil,
        sandboxJailerUidBase: UInt32? = nil,
        sandboxWarmStart: Bool? = nil,
        sandboxWarmCacheMaxSizeGB: Int? = nil,
        hypervisorType: HypervisorType? = nil,
        ovnUplink: OVNUplinkConfig? = nil,
        ovnDynamicRouting: OVNDynamicRoutingConfig? = nil,
        resolver: NetworkResolverConfig? = nil,
        simulation: SimulationConfig? = nil,
        reconcileTeardownMinimum: Int? = nil,
        reconcileTeardownPercent: Int? = nil,
        allowBulkTeardown: Bool? = nil,
        desiredStateFullRefetchSeconds: Int? = nil,
        metadataService: Bool? = nil,
        metadataResponseHopLimit: Int? = nil
    ) {
        self.controlPlaneURL = controlPlaneURL
        self.logLevel = logLevel
        self.networkMode = networkMode
        self.ovnEncapIP = ovnEncapIP
        self.ovnEncapType = ovnEncapType
        self.ovnRemote = ovnRemote
        self.ovnBootstrapChassis = ovnBootstrapChassis
        self.ovnNorthbound = ovnNorthbound
        self.ovnNorthboundTLS = ovnNorthboundTLS
        self.enableHVF = enableHVF
        self.enableKVM = enableKVM
        self.qemuMemoryOverheadMB = qemuMemoryOverheadMB
        self.vmStoragePath = vmStoragePath
        self.volumeStoragePath = volumeStoragePath
        self.imageCacheDir = imageCacheDir
        self.imageCacheMaxSizeGB = imageCacheMaxSizeGB
        self.sandboxImageCacheDir = sandboxImageCacheDir
        self.sandboxImageCacheMaxSizeGB = sandboxImageCacheMaxSizeGB
        self.firmwarePathARM64 = firmwarePathARM64
        self.firmwarePathX86_64 = firmwarePathX86_64
        self.firmwareCodePath = firmwareCodePath
        self.firmwareVarsTemplate = firmwareVarsTemplate
        self.secureBootFirmwareCodePath = secureBootFirmwareCodePath
        self.secureBootFirmwareVarsTemplate = secureBootFirmwareVarsTemplate
        self.spiffe = spiffe
        self.firecrackerBinaryPath = firecrackerBinaryPath
        self.firecrackerSocketDir = firecrackerSocketDir
        self.sandboxGuestImagePath = sandboxGuestImagePath
        self.sandboxJailerMode = sandboxJailerMode
        self.sandboxJailerBinaryPath = sandboxJailerBinaryPath
        self.sandboxJailerChrootDir = sandboxJailerChrootDir
        self.sandboxJailerUidBase = sandboxJailerUidBase
        self.sandboxWarmStart = sandboxWarmStart
        self.sandboxWarmCacheMaxSizeGB = sandboxWarmCacheMaxSizeGB
        self.hypervisorType = hypervisorType
        self.ovnUplink = ovnUplink
        self.ovnDynamicRouting = ovnDynamicRouting
        self.resolver = resolver
        self.simulation = simulation
        self.reconcileTeardownMinimum = reconcileTeardownMinimum
        self.reconcileTeardownPercent = reconcileTeardownPercent
        self.allowBulkTeardown = allowBulkTeardown
        self.desiredStateFullRefetchSeconds = desiredStateFullRefetchSeconds
        self.metadataService = metadataService
        self.metadataResponseHopLimit = metadataResponseHopLimit
    }

    /// The VM image cache budget in bytes (config stores whole GB).
    public var imageCacheMaxSizeBytes: Int64? {
        imageCacheMaxSizeGB.map { Int64($0) * 1024 * 1024 * 1024 }
    }

    /// The sandbox rootfs cache budget in bytes (config stores whole GB).
    public var sandboxImageCacheMaxSizeBytes: Int64? {
        sandboxImageCacheMaxSizeGB.map { Int64($0) * 1024 * 1024 * 1024 }
    }

    /// The warm-snapshot cache budget in bytes (config stores whole GB).
    public var sandboxWarmCacheMaxSizeBytes: Int64? {
        sandboxWarmCacheMaxSizeGB.map { Int64($0) * 1024 * 1024 * 1024 }
    }

    /// The OVN chassis bootstrap settings derived from this configuration.
    public var ovnChassisConfig: OVNChassisConfig {
        OVNChassisConfig(
            encapIP: ovnEncapIP,
            encapType: ovnEncapType,
            remote: ovnRemote,
            bootstrapEnabled: ovnBootstrapChassis ?? true
        )
    }

}
