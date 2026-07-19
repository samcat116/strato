import Foundation
import Toml
import Logging
import StratoShared

public enum NetworkMode: String, Codable {
    case ovn
    case user
}

/// Simulation ("dummy agent") configuration. When enabled the agent registers
/// and speaks the full control-plane protocol but drives a no-op hypervisor and
/// no real networking/storage, reporting configurable fake host capacity. This
/// lets a fleet of agents be scale-tested against a control plane far larger
/// than the compute available to actually run VMs.
public struct SimulationConfig: Codable, Sendable, Equatable {
    /// Whether simulation mode is active. When false, every other field is ignored.
    public let enabled: Bool
    /// Fake logical CPU core count to advertise. Nil uses `defaultCPUCores`.
    public let cpuCores: Int?
    /// Fake total memory in megabytes. Nil uses `defaultMemoryMB`.
    public let memoryMB: Int?
    /// Fake total disk in gigabytes. Nil uses `defaultDiskGB`.
    public let diskGB: Int?
    /// Milliseconds between synthetic workload log lines from each running
    /// simulated sandbox (issue #470); 0 disables emission. Nil uses
    /// `defaultSandboxLogIntervalMS`.
    public let sandboxLogIntervalMS: Int?
    /// When set (> 0), a simulated sandbox workload exits (code 0) this many
    /// seconds after boot, exercising the one-shot `.exited` path at scale.
    /// Nil means workloads run until stopped.
    public let sandboxExitAfterSeconds: Int?

    enum CodingKeys: String, CodingKey {
        case enabled
        case cpuCores = "cpu_cores"
        case memoryMB = "memory_mb"
        case diskGB = "disk_gb"
        case sandboxLogIntervalMS = "sandbox_log_interval_ms"
        case sandboxExitAfterSeconds = "sandbox_exit_after_seconds"
    }

    public init(
        enabled: Bool = false,
        cpuCores: Int? = nil,
        memoryMB: Int? = nil,
        diskGB: Int? = nil,
        sandboxLogIntervalMS: Int? = nil,
        sandboxExitAfterSeconds: Int? = nil
    ) {
        self.enabled = enabled
        self.cpuCores = cpuCores
        self.memoryMB = memoryMB
        self.diskGB = diskGB
        self.sandboxLogIntervalMS = sandboxLogIntervalMS
        self.sandboxExitAfterSeconds = sandboxExitAfterSeconds
    }

    /// Default simulation configuration (disabled).
    public static let disabled = SimulationConfig(enabled: false)

    public static let defaultCPUCores = 8
    public static let defaultMemoryMB = 16 * 1024  // 16 GB
    public static let defaultDiskGB = 512
    public static let defaultSandboxLogIntervalMS = 5000

    /// Resolved fake capacity, applying defaults for any unset field. The agent
    /// reports these instead of probing the real host, so a spawner can give
    /// each dummy a different size and make the scheduler's placement decisions
    /// non-trivial.
    public var resolvedCPUCores: Int { cpuCores ?? Self.defaultCPUCores }
    public var resolvedMemoryBytes: Int64 { Int64(memoryMB ?? Self.defaultMemoryMB) * 1024 * 1024 }
    public var resolvedDiskBytes: Int64 { Int64(diskGB ?? Self.defaultDiskGB) * 1024 * 1024 * 1024 }

    /// Interval between synthetic sandbox workload log lines, or nil when
    /// emission is disabled (interval configured to 0).
    public var resolvedSandboxLogInterval: Duration? {
        let ms = sandboxLogIntervalMS ?? Self.defaultSandboxLogIntervalMS
        return ms > 0 ? .milliseconds(ms) : nil
    }

    /// How long a simulated sandbox workload runs before exiting on its own,
    /// or nil when workloads should run until stopped (the default).
    public var resolvedSandboxLifetime: Duration? {
        guard let seconds = sandboxExitAfterSeconds, seconds > 0 else { return nil }
        return .seconds(seconds)
    }
}

/// SPIFFE/SPIRE configuration
public struct SPIFFEConfig: Codable, Sendable {
    /// Whether SPIFFE authentication is enabled
    public let enabled: Bool

    /// Trust domain (e.g., "strato.local")
    public let trustDomain: String?

    /// Path to the SPIRE Workload API socket
    public let workloadAPISocketPath: String?

    /// Source type: "workload_api" or "files"
    public let sourceType: String?

    /// Path to certificate file (for file-based source)
    public let certificatePath: String?

    /// Path to private key file (for file-based source)
    public let privateKeyPath: String?

    /// Path to trust bundle file (for file-based source)
    public let trustBundlePath: String?

    enum CodingKeys: String, CodingKey {
        case enabled
        case trustDomain = "trust_domain"
        case workloadAPISocketPath = "workload_api_socket_path"
        case sourceType = "source_type"
        case certificatePath = "certificate_path"
        case privateKeyPath = "private_key_path"
        case trustBundlePath = "trust_bundle_path"
    }

    public init(
        enabled: Bool = false,
        trustDomain: String? = nil,
        workloadAPISocketPath: String? = nil,
        sourceType: String? = nil,
        certificatePath: String? = nil,
        privateKeyPath: String? = nil,
        trustBundlePath: String? = nil
    ) {
        self.enabled = enabled
        self.trustDomain = trustDomain
        self.workloadAPISocketPath = workloadAPISocketPath
        self.sourceType = sourceType
        self.certificatePath = certificatePath
        self.privateKeyPath = privateKeyPath
        self.trustBundlePath = trustBundlePath
    }

    /// Default SPIFFE configuration (disabled)
    public static let disabled = SPIFFEConfig(enabled: false)

    /// Default Workload API socket path
    public static let defaultWorkloadAPISocketPath = "/var/run/spire/sockets/workload.sock"

    /// Default trust domain
    public static let defaultTrustDomain = "strato.local"
}

/// TLS settings for an `ssl:` `ovn_northbound` endpoint (the
/// `[ovn_northbound_tls]` config section). OVN deployments run a private PKI
/// (`ovn-pki`), so the CA must be supplied explicitly and the server usually
/// requires a client certificate signed by the same CA — these are the agent
/// counterparts of ovn-nbctl's `-C`/`-c`/`-p` flags. All paths are PEM files.
public struct OVNNorthboundTLSConfig: Codable, Sendable, Equatable {
    /// CA certificate(s) used to verify the server. Nil = system trust roots.
    public let caCertPath: String?
    /// Client certificate chain presented to the server.
    public let clientCertPath: String?
    /// Private key for the client certificate.
    public let clientKeyPath: String?
    /// Whether the server certificate is verified at all. Default true;
    /// disable only for lab setups with unverifiable certificates.
    public let verifyServerCertificate: Bool
    /// Hostname for SNI/certificate verification, when connecting by IP
    /// address to a certificate issued for a DNS name.
    public let serverHostname: String?

    enum CodingKeys: String, CodingKey {
        case caCertPath = "ca_cert"
        case clientCertPath = "client_cert"
        case clientKeyPath = "client_key"
        case verifyServerCertificate = "verify_server_certificate"
        case serverHostname = "server_hostname"
    }

    public init(
        caCertPath: String? = nil,
        clientCertPath: String? = nil,
        clientKeyPath: String? = nil,
        verifyServerCertificate: Bool = true,
        serverHostname: String? = nil
    ) {
        self.caCertPath = caCertPath
        self.clientCertPath = clientCertPath
        self.clientKeyPath = clientKeyPath
        self.verifyServerCertificate = verifyServerCertificate
        self.serverHostname = serverHostname
    }

    /// Every configured PEM path, for existence checks in the host preflight.
    public var configuredFilePaths: [String] {
        [caCertPath, clientCertPath, clientKeyPath].compactMap { $0 }
    }
}

public struct AgentConfig: Codable {
    public let controlPlaneURL: String
    public let qemuSocketDir: String?
    public let logLevel: String?
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
    public let qemuBinaryPath: String?
    public let firmwarePathARM64: String?
    public let firmwarePathX86_64: String?
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
    /// First uid/gid of the per-sandbox uid range (65536 ids). Default 100000.
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
    /// Simulation ("dummy agent") settings. Nil (or disabled) means a normal
    /// agent that drives real hypervisor/network/storage backends.
    public let simulation: SimulationConfig?

    enum CodingKeys: String, CodingKey {
        case controlPlaneURL = "control_plane_url"
        case qemuSocketDir = "qemu_socket_dir"
        case logLevel = "log_level"
        case networkMode = "network_mode"
        case ovnEncapIP = "ovn_encap_ip"
        case ovnEncapType = "ovn_encap_type"
        case ovnRemote = "ovn_remote"
        case ovnBootstrapChassis = "ovn_bootstrap_chassis"
        case ovnNorthbound = "ovn_northbound"
        case ovnNorthboundTLS = "ovn_northbound_tls"
        case enableHVF = "enable_hvf"
        case enableKVM = "enable_kvm"
        case vmStoragePath = "vm_storage_dir"
        case volumeStoragePath = "volume_storage_dir"
        case imageCacheDir = "image_cache_dir"
        case imageCacheMaxSizeGB = "image_cache_max_size_gb"
        case sandboxImageCacheDir = "sandbox_image_cache_dir"
        case sandboxImageCacheMaxSizeGB = "sandbox_image_cache_max_size_gb"
        case qemuBinaryPath = "qemu_binary_path"
        case firmwarePathARM64 = "firmware_path_arm64"
        case firmwarePathX86_64 = "firmware_path_x86_64"
        case spiffe
        case firecrackerBinaryPath = "firecracker_binary_path"
        case firecrackerSocketDir = "firecracker_socket_dir"
        case sandboxGuestImagePath = "sandbox_guest_image_path"
        case sandboxJailerMode = "sandbox_jailer_mode"
        case sandboxJailerBinaryPath = "sandbox_jailer_binary_path"
        case sandboxJailerChrootDir = "sandbox_jailer_chroot_dir"
        case sandboxJailerUidBase = "sandbox_jailer_uid_base"
        case sandboxWarmStart = "sandbox_warm_start"
        case sandboxWarmCacheMaxSizeGB = "sandbox_warm_cache_max_size_gb"
        case hypervisorType = "hypervisor_type"
        case ovnUplink = "ovn_uplink"
        case ovnDynamicRouting = "ovn_dynamic_routing"
        case simulation
    }

    public init(
        controlPlaneURL: String,
        qemuSocketDir: String? = nil,
        logLevel: String? = nil,
        networkMode: NetworkMode? = nil,
        ovnEncapIP: String? = nil,
        ovnEncapType: String? = nil,
        ovnRemote: String? = nil,
        ovnBootstrapChassis: Bool? = nil,
        ovnNorthbound: String? = nil,
        ovnNorthboundTLS: OVNNorthboundTLSConfig? = nil,
        enableHVF: Bool? = nil,
        enableKVM: Bool? = nil,
        vmStoragePath: String? = nil,
        volumeStoragePath: String? = nil,
        imageCacheDir: String? = nil,
        imageCacheMaxSizeGB: Int? = nil,
        sandboxImageCacheDir: String? = nil,
        sandboxImageCacheMaxSizeGB: Int? = nil,
        qemuBinaryPath: String? = nil,
        firmwarePathARM64: String? = nil,
        firmwarePathX86_64: String? = nil,
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
        simulation: SimulationConfig? = nil
    ) {
        self.controlPlaneURL = controlPlaneURL
        self.qemuSocketDir = qemuSocketDir
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
        self.vmStoragePath = vmStoragePath
        self.volumeStoragePath = volumeStoragePath
        self.imageCacheDir = imageCacheDir
        self.imageCacheMaxSizeGB = imageCacheMaxSizeGB
        self.sandboxImageCacheDir = sandboxImageCacheDir
        self.sandboxImageCacheMaxSizeGB = sandboxImageCacheMaxSizeGB
        self.qemuBinaryPath = qemuBinaryPath
        self.firmwarePathARM64 = firmwarePathARM64
        self.firmwarePathX86_64 = firmwarePathX86_64
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
        self.simulation = simulation
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

    public static func load(from path: String, logger: Logger? = nil) throws -> AgentConfig {
        let fileURL = URL(fileURLWithPath: path)

        guard FileManager.default.fileExists(atPath: path) else {
            throw AgentConfigError.configFileNotFound(path)
        }

        let tomlString = try String(contentsOf: fileURL, encoding: .utf8)
        let tomlData = try Toml(withString: tomlString)

        // Extract configuration values from TOML
        guard let controlPlaneURL = tomlData.string("control_plane_url") else {
            throw AgentConfigError.missingRequiredField("control_plane_url")
        }

        let qemuSocketDir = tomlData.string("qemu_socket_dir")
        let logLevel = tomlData.string("log_level")
        let networkModeString = tomlData.string("network_mode")
        let ovnEncapIP = tomlData.string("ovn_encap_ip")
        let ovnEncapType = tomlData.string("ovn_encap_type")
        let ovnRemote = tomlData.string("ovn_remote")
        let ovnBootstrapChassis = tomlData.bool("ovn_bootstrap_chassis")
        let ovnNorthbound = tomlData.string("ovn_northbound")
        if let ovnNorthbound {
            let validSchemes = ["unix:", "tcp:", "ssl:"]
            guard validSchemes.contains(where: ovnNorthbound.hasPrefix) else {
                throw AgentConfigError.invalidConfiguration(
                    "ovn_northbound must be an OVN connection string (unix:<path>, tcp:<host>:<port>, or ssl:<host>:<port>), got '\(ovnNorthbound)'"
                )
            }
        }
        // Parse NB TLS material from the [ovn_northbound_tls] section. It only
        // makes sense with an ssl: endpoint, so any other pairing is rejected —
        // an operator who wrote cert paths must not silently get cleartext.
        // (`table(_:)` returns an empty scoped view even for an absent section,
        // so presence must be tested with `hasTable`.)
        let ovnNorthboundTLS: OVNNorthboundTLSConfig?
        if tomlData.hasTable("ovn_northbound_tls"), let tlsTable = tomlData.table("ovn_northbound_tls") {
            guard let ovnNorthbound, ovnNorthbound.hasPrefix("ssl:") else {
                throw AgentConfigError.invalidConfiguration(
                    "[ovn_northbound_tls] requires ovn_northbound to be an ssl:<host>:<port> endpoint, "
                        + "got '\(ovnNorthbound ?? "(unset)")'"
                )
            }
            let clientCert = tlsTable.string("client_cert")
            let clientKey = tlsTable.string("client_key")
            guard (clientCert == nil) == (clientKey == nil) else {
                throw AgentConfigError.invalidConfiguration(
                    "[ovn_northbound_tls] client_cert and client_key must be set together"
                )
            }
            ovnNorthboundTLS = OVNNorthboundTLSConfig(
                caCertPath: tlsTable.string("ca_cert"),
                clientCertPath: clientCert,
                clientKeyPath: clientKey,
                verifyServerCertificate: tlsTable.bool("verify_server_certificate") ?? true,
                serverHostname: tlsTable.string("server_hostname")
            )
        } else {
            ovnNorthboundTLS = nil
        }
        let enableHVF = tomlData.bool("enable_hvf")
        let enableKVM = tomlData.bool("enable_kvm")
        let vmStoragePath = tomlData.string("vm_storage_dir")
        let volumeStoragePath = tomlData.string("volume_storage_dir")
        let imageCacheDir = tomlData.string("image_cache_dir")
        let sandboxImageCacheDir = tomlData.string("sandbox_image_cache_dir")
        // Cache budgets must be positive: 0 would mean "evict everything, every
        // time" — an operator who wants no cache bound should omit the key.
        let imageCacheMaxSizeGB = try Self.positiveInt(tomlData, key: "image_cache_max_size_gb")
        let sandboxImageCacheMaxSizeGB = try Self.positiveInt(tomlData, key: "sandbox_image_cache_max_size_gb")
        let qemuBinaryPath = tomlData.string("qemu_binary_path")
        let firmwarePathARM64 = tomlData.string("firmware_path_arm64")
        let firmwarePathX86_64 = tomlData.string("firmware_path_x86_64")
        let firecrackerBinaryPath = tomlData.string("firecracker_binary_path")
        let firecrackerSocketDir = tomlData.string("firecracker_socket_dir")
        let sandboxGuestImagePath = tomlData.string("sandbox_guest_image_path")
        let hypervisorTypeString = tomlData.string("hypervisor_type")

        // Sandbox jailer settings (issue #425). The mode is strictly decoded —
        // a typo like "requierd" silently falling back to auto would quietly
        // weaken a host an operator believed hardened.
        let sandboxJailerMode: SandboxJailerMode?
        if let modeString = tomlData.string("sandbox_jailer_mode") {
            guard let mode = SandboxJailerMode(rawValue: modeString) else {
                throw AgentConfigError.invalidConfiguration(
                    "sandbox_jailer_mode must be 'auto', 'required', or 'disabled', got '\(modeString)'")
            }
            sandboxJailerMode = mode
        } else {
            sandboxJailerMode = nil
        }
        let sandboxJailerBinaryPath = tomlData.string("sandbox_jailer_binary_path")
        let sandboxJailerChrootDir = tomlData.string("sandbox_jailer_chroot_dir")
        let sandboxJailerUidBase: UInt32?
        if let uidBase = tomlData.int("sandbox_jailer_uid_base") {
            guard uidBase > 0, uidBase <= Int(UInt32.max) - Int(SandboxJailerConfig.uidCount) else {
                throw AgentConfigError.invalidConfiguration(
                    "sandbox_jailer_uid_base must be a positive uid with room for a \(SandboxJailerConfig.uidCount)-id range, got \(uidBase)"
                )
            }
            sandboxJailerUidBase = UInt32(uidBase)
        } else {
            sandboxJailerUidBase = nil
        }

        // Warm start (issue #426).
        let sandboxWarmStart = tomlData.bool("sandbox_warm_start")
        let sandboxWarmCacheMaxSizeGB = try Self.positiveInt(
            tomlData, key: "sandbox_warm_cache_max_size_gb")

        // Validate and parse network mode
        let networkMode: NetworkMode?
        if let modeString = networkModeString {
            guard let mode = NetworkMode(rawValue: modeString) else {
                throw AgentConfigError.invalidConfiguration("network_mode must be 'ovn' or 'user', got '\(modeString)'")
            }
            networkMode = mode
        } else {
            networkMode = nil
        }

        // Validate and parse hypervisor type
        let hypervisorType: HypervisorType?
        if let typeString = hypervisorTypeString {
            guard let hType = HypervisorType(rawValue: typeString) else {
                throw AgentConfigError.invalidConfiguration(
                    "hypervisor_type must be 'qemu' or 'firecracker', got '\(typeString)'")
            }
            hypervisorType = hType
            logger?.info("Agent configured to use hypervisor type: \(typeString)")
        } else {
            hypervisorType = nil
        }

        // Parse SPIFFE configuration from [spiffe] section
        let spiffeConfig: SPIFFEConfig?
        if let spiffeTable = tomlData.table("spiffe") {
            let enabled = spiffeTable.bool("enabled") ?? false
            let trustDomain = spiffeTable.string("trust_domain")
            let workloadAPISocketPath = spiffeTable.string("workload_api_socket_path")
            let sourceType = spiffeTable.string("source_type")
            let certificatePath = spiffeTable.string("certificate_path")
            let privateKeyPath = spiffeTable.string("private_key_path")
            let trustBundlePath = spiffeTable.string("trust_bundle_path")

            spiffeConfig = SPIFFEConfig(
                enabled: enabled,
                trustDomain: trustDomain,
                workloadAPISocketPath: workloadAPISocketPath,
                sourceType: sourceType,
                certificatePath: certificatePath,
                privateKeyPath: privateKeyPath,
                trustBundlePath: trustBundlePath
            )

            if enabled {
                logger?.info(
                    "SPIFFE authentication enabled",
                    metadata: [
                        "trustDomain": .string(trustDomain ?? SPIFFEConfig.defaultTrustDomain),
                        "sourceType": .string(sourceType ?? "workload_api"),
                    ])
            }
        } else {
            spiffeConfig = nil
        }

        // Parse the OVN uplink from the [ovn_uplink] section (issue #342). SNAT
        // egress is off unless a dedicated external CIDR is configured.
        let ovnUplink: OVNUplinkConfig?
        if let uplinkTable = tomlData.table("ovn_uplink"), let externalCIDR = uplinkTable.string("external_cidr") {
            let externalCIDR6 = uplinkTable.string("external_cidr6")
            ovnUplink = OVNUplinkConfig(
                externalCIDR: externalCIDR,
                gateway: uplinkTable.string("gateway"),
                bridge: uplinkTable.string("bridge") ?? OVNUplinkConfig.defaultBridge,
                physnet: uplinkTable.string("physnet") ?? OVNUplinkConfig.defaultPhysnet,
                externalCIDR6: externalCIDR6,
                gateway6: uplinkTable.string("gateway6")
            )
            logger?.info(
                "OVN SNAT uplink configured",
                metadata: [
                    "externalCIDR": .string(externalCIDR),
                    "externalCIDR6": .string(externalCIDR6 ?? "none"),
                ])
        } else {
            ovnUplink = nil
        }

        // Parse OVN native dynamic routing from the [ovn_dynamic_routing]
        // section (issue #344). Presence tested with `hasTable` (same gotcha
        // as [simulation] below). Invalid redistribute/protocol values are
        // rejected at load: OVN would silently ignore them, which reads as
        // "BGP is on" while advertising nothing.
        let ovnDynamicRouting: OVNDynamicRoutingConfig?
        if tomlData.hasTable("ovn_dynamic_routing"), let routingTable = tomlData.table("ovn_dynamic_routing") {
            let config = OVNDynamicRoutingConfig(
                enabled: routingTable.bool("enabled") ?? false,
                redistribute: routingTable.array("redistribute")
                    ?? OVNDynamicRoutingConfig.defaultRedistribute,
                vrfName: routingTable.string("vrf_name"),
                maintainVRF: routingTable.bool("maintain_vrf") ?? true,
                routingProtocols: routingTable.array("routing_protocols")
                    ?? OVNDynamicRoutingConfig.defaultRoutingProtocols
            )
            let invalid = config.invalidValues
            guard invalid.isEmpty else {
                throw AgentConfigError.invalidConfiguration(
                    "[ovn_dynamic_routing] has unsupported value(s): \(invalid.joined(separator: ", ")). "
                        + "redistribute allows \(OVNDynamicRoutingConfig.allowedRedistributeValues.sorted().joined(separator: "/")); "
                        + "routing_protocols allows \(OVNDynamicRoutingConfig.allowedRoutingProtocols.sorted().joined(separator: "/"))"
                )
            }
            ovnDynamicRouting = config
            if config.enabled {
                logger?.info(
                    "OVN dynamic routing enabled (requires OVN >= 25.03 and host FRR)",
                    metadata: [
                        "redistribute": .string(config.redistribute.joined(separator: ",")),
                        "routingProtocols": .string(config.routingProtocols.joined(separator: ",")),
                    ])
            }
        } else {
            ovnDynamicRouting = nil
        }

        // Parse simulation ("dummy agent") settings from the [simulation]
        // section. Absent section means a normal agent. `table(_:)` returns an
        // empty scoped view even for an absent section, so presence must be
        // tested with `hasTable` (same gotcha as [ovn_northbound_tls] above).
        let simulationConfig: SimulationConfig?
        if tomlData.hasTable("simulation"), let simTable = tomlData.table("simulation") {
            let enabled = simTable.bool("enabled") ?? false
            simulationConfig = SimulationConfig(
                enabled: enabled,
                cpuCores: simTable.int("cpu_cores"),
                memoryMB: simTable.int("memory_mb"),
                diskGB: simTable.int("disk_gb"),
                sandboxLogIntervalMS: simTable.int("sandbox_log_interval_ms"),
                sandboxExitAfterSeconds: simTable.int("sandbox_exit_after_seconds")
            )
            if enabled {
                logger?.warning(
                    "Simulation mode enabled: this agent will NOT run real VMs",
                    metadata: [
                        "cpuCores": .stringConvertible(simulationConfig?.resolvedCPUCores ?? 0)
                    ])
            }
        } else {
            simulationConfig = nil
        }

        // Validate platform-specific settings
        #if os(macOS)
        if enableKVM == true {
            logger?.warning("enable_kvm is not supported on macOS, will be ignored")
        }
        #elseif os(Linux)
        if enableHVF == true {
            logger?.warning("enable_hvf is only supported on macOS, will be ignored")
        }
        #endif

        return AgentConfig(
            controlPlaneURL: controlPlaneURL,
            qemuSocketDir: qemuSocketDir,
            logLevel: logLevel,
            networkMode: networkMode,
            ovnEncapIP: ovnEncapIP,
            ovnEncapType: ovnEncapType,
            ovnRemote: ovnRemote,
            ovnBootstrapChassis: ovnBootstrapChassis,
            ovnNorthbound: ovnNorthbound,
            ovnNorthboundTLS: ovnNorthboundTLS,
            enableHVF: enableHVF,
            enableKVM: enableKVM,
            vmStoragePath: vmStoragePath,
            volumeStoragePath: volumeStoragePath,
            imageCacheDir: imageCacheDir,
            imageCacheMaxSizeGB: imageCacheMaxSizeGB,
            sandboxImageCacheDir: sandboxImageCacheDir,
            sandboxImageCacheMaxSizeGB: sandboxImageCacheMaxSizeGB,
            qemuBinaryPath: qemuBinaryPath,
            firmwarePathARM64: firmwarePathARM64,
            firmwarePathX86_64: firmwarePathX86_64,
            spiffe: spiffeConfig,
            firecrackerBinaryPath: firecrackerBinaryPath,
            firecrackerSocketDir: firecrackerSocketDir,
            sandboxGuestImagePath: sandboxGuestImagePath,
            sandboxJailerMode: sandboxJailerMode,
            sandboxJailerBinaryPath: sandboxJailerBinaryPath,
            sandboxJailerChrootDir: sandboxJailerChrootDir,
            sandboxJailerUidBase: sandboxJailerUidBase,
            sandboxWarmStart: sandboxWarmStart,
            sandboxWarmCacheMaxSizeGB: sandboxWarmCacheMaxSizeGB,
            hypervisorType: hypervisorType,
            ovnUplink: ovnUplink,
            ovnDynamicRouting: ovnDynamicRouting,
            simulation: simulationConfig
        )
    }

    /// Reads an integer key that must be positive when present.
    private static func positiveInt(_ toml: Toml, key: String) throws -> Int? {
        guard let value = toml.int(key) else { return nil }
        guard value > 0 else {
            throw AgentConfigError.invalidConfiguration("\(key) must be a positive integer, got \(value)")
        }
        return value
    }

    /// Default config file path (platform-specific)
    public static var defaultConfigPath: String {
        #if os(macOS)
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/Library/Application Support/strato/config.toml"
        #else
        return "/etc/strato/config.toml"
        #endif
    }

    public static let fallbackConfigPath = "./config.toml"

    public static func loadDefaultConfig(logger: Logger? = nil) -> AgentConfig {
        // Try to load from default path first
        do {
            return try load(from: defaultConfigPath, logger: logger)
        } catch {
            logger?.warning("Failed to load config from \(defaultConfigPath): \(error)")
        }

        // Try fallback path for development
        do {
            return try load(from: fallbackConfigPath, logger: logger)
        } catch {
            logger?.warning("Failed to load config from \(fallbackConfigPath): \(error)")
        }

        // Return default configuration if no config file found
        logger?.info("Using default configuration")

        #if os(Linux)
        #if arch(arm64)
        let defaultQemuPath = "/usr/bin/qemu-system-aarch64"
        #else
        let defaultQemuPath = "/usr/bin/qemu-system-x86_64"
        #endif
        return AgentConfig(
            controlPlaneURL: "ws://localhost:8080/agent/ws",
            qemuSocketDir: "/var/run/qemu",
            logLevel: "info",
            networkMode: .ovn,
            enableHVF: false,
            enableKVM: true,
            vmStoragePath: "/var/lib/strato/vms",
            qemuBinaryPath: defaultQemuPath
        )
        #else
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        #if arch(arm64)
        let defaultQemuPath = "/opt/homebrew/bin/qemu-system-aarch64"
        #else
        let defaultQemuPath = "/opt/homebrew/bin/qemu-system-x86_64"
        #endif
        return AgentConfig(
            controlPlaneURL: "ws://localhost:8080/agent/ws",
            qemuSocketDir: "\(home)/Library/Application Support/strato/qemu-sockets",
            logLevel: "info",
            networkMode: .user,
            enableHVF: true,
            enableKVM: false,
            vmStoragePath: "\(home)/Library/Application Support/strato/vms",
            qemuBinaryPath: defaultQemuPath
        )
        #endif
    }

    /// Default VM storage path (platform-specific)
    public static var defaultVMStoragePath: String {
        #if os(macOS)
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/Library/Application Support/strato/vms"
        #else
        return "/var/lib/strato/vms"
        #endif
    }

    /// Default QEMU socket directory (platform-specific)
    public static var defaultQemuSocketDir: String {
        #if os(macOS)
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/Library/Application Support/strato/qemu-sockets"
        #else
        return "/var/run/qemu"
        #endif
    }

    /// Default QEMU binary path (platform and architecture-specific)
    public static var defaultQemuBinaryPath: String {
        #if os(macOS)
        // Homebrew's prefix differs by hardware: /opt/homebrew on Apple
        // Silicon, /usr/local on Intel. Probe both (native prefix first)
        // so the default works on either, and fall back to the native
        // prefix when QEMU isn't installed yet.
        #if arch(arm64)
        let binary = "qemu-system-aarch64"
        let prefixes = ["/opt/homebrew/bin", "/usr/local/bin"]
        #else
        let binary = "qemu-system-x86_64"
        let prefixes = ["/usr/local/bin", "/opt/homebrew/bin"]
        #endif
        let candidates = prefixes.map { "\($0)/\(binary)" }
        return candidates.first { FileManager.default.fileExists(atPath: $0) } ?? candidates[0]
        #else
        #if arch(arm64)
        return "/usr/bin/qemu-system-aarch64"
        #else
        return "/usr/bin/qemu-system-x86_64"
        #endif
        #endif
    }

    /// Default UEFI firmware path for ARM64 guests (platform-specific)
    /// Used when VMs boot from disk images rather than direct kernel boot
    public static var defaultFirmwarePathARM64: String? {
        #if os(macOS)
        let path = "/opt/homebrew/share/qemu/edk2-aarch64-code.fd"
        return FileManager.default.fileExists(atPath: path) ? path : nil
        #else
        // Linux: try common paths for different distributions
        let paths = [
            "/usr/share/AAVMF/AAVMF_CODE.fd",
            "/usr/share/qemu-efi-aarch64/QEMU_EFI.fd",
            "/usr/share/edk2/aarch64/QEMU_EFI.fd",
        ]
        return paths.first { FileManager.default.fileExists(atPath: $0) }
        #endif
    }

    /// Default UEFI firmware path for x86_64 guests (platform-specific)
    /// Used when VMs boot from disk images rather than direct kernel boot
    public static var defaultFirmwarePathX86_64: String? {
        #if os(macOS)
        let path = "/opt/homebrew/share/qemu/edk2-x86_64-code.fd"
        return FileManager.default.fileExists(atPath: path) ? path : nil
        #else
        // Linux: try common paths for different distributions
        let paths = [
            "/usr/share/OVMF/OVMF_CODE.fd",
            "/usr/share/edk2/ovmf/OVMF_CODE.fd",
            "/usr/share/qemu/OVMF.fd",
        ]
        return paths.first { FileManager.default.fileExists(atPath: $0) }
        #endif
    }

    /// Default Firecracker binary path (Linux only)
    public static var defaultFirecrackerBinaryPath: String {
        #if os(Linux)
        // Check common installation paths
        let paths = [
            "/usr/local/bin/firecracker",
            "/usr/bin/firecracker",
        ]
        if let path = paths.first(where: { FileManager.default.fileExists(atPath: $0) }) {
            return path
        }
        // Also check user's local bin
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let userPath = "\(home)/.local/bin/firecracker"
        if FileManager.default.fileExists(atPath: userPath) {
            return userPath
        }
        return "/usr/local/bin/firecracker"
        #else
        return "/usr/local/bin/firecracker"  // Not available on macOS
        #endif
    }

    /// Default Firecracker socket directory (Linux only)
    public static var defaultFirecrackerSocketDir: String {
        return "/tmp/firecracker"
    }

    /// Default sandbox guest base image location (Linux only — sandboxes are
    /// Firecracker/KVM workloads). The guest-image work (issue #419) installs
    /// its artifacts here; until something exists at this path the agent does
    /// not advertise the sandbox-runtime capability.
    public static var defaultSandboxGuestImagePath: String {
        return "/var/lib/strato/sandbox/guest"
    }

    /// Default jailer binary path (Linux only). The jailer ships in the same
    /// release tarball as Firecracker, so look beside the resolved Firecracker
    /// binary first, then the same well-known locations.
    public static func defaultSandboxJailerBinaryPath(firecrackerBinaryPath: String) -> String {
        let sibling = URL(fileURLWithPath: firecrackerBinaryPath)
            .deletingLastPathComponent().appendingPathComponent("jailer").path
        let candidates = [sibling, "/usr/local/bin/jailer", "/usr/bin/jailer"]
        return candidates.first { FileManager.default.fileExists(atPath: $0) } ?? sibling
    }

    /// Default per-sandbox chroot base directory: under VM storage, because
    /// every jail holds a full writable rootfs copy and the jailer's stock
    /// `/srv/jailer` is rarely provisioned for that.
    public static func defaultSandboxJailerChrootDir(vmStoragePath: String) -> String {
        vmStoragePath + "/jailer"
    }

    /// Default first uid of the per-sandbox uid/gid range: 100000, clear of
    /// system and login users on stock hosts (shared with the systemd-nspawn
    /// container range, which a Firecracker hypervisor host does not use).
    public static let defaultSandboxJailerUidBase: UInt32 = 100_000

    /// Default hypervisor type (platform-specific)
    /// Linux defaults to QEMU, but can be configured to use Firecracker
    public static var defaultHypervisorType: HypervisorType {
        return .qemu
    }
}

public enum AgentConfigError: Error, LocalizedError {
    case configFileNotFound(String)
    case invalidTOMLFormat(String)
    case missingRequiredField(String)
    case invalidConfiguration(String)

    public var errorDescription: String? {
        switch self {
        case .configFileNotFound(let path):
            return "Configuration file not found at path: \(path)"
        case .invalidTOMLFormat(let details):
            return "Invalid TOML format: \(details)"
        case .missingRequiredField(let field):
            return "Missing required configuration field: \(field)"
        case .invalidConfiguration(let message):
            return "Invalid configuration: \(message)"
        }
    }
}
