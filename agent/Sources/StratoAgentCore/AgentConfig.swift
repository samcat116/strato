import Foundation
import Configuration
import Logging
import StratoShared
import TomlConfiguration

public enum NetworkMode: String {
    case ovn
    case user
}

/// Simulation ("dummy agent") configuration. When enabled the agent registers
/// and speaks the full control-plane protocol but drives a no-op hypervisor and
/// no real networking/storage, reporting configurable fake host capacity. This
/// lets a fleet of agents be scale-tested against a control plane far larger
/// than the compute available to actually run VMs.
public struct SimulationConfig: Sendable, Equatable {
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
public struct SPIFFEConfig: Sendable {
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

    /// The SPIFFE ID the control plane must present on its TLS certificate.
    /// Every workload in the trust domain holds a bundle-signed SVID, so the
    /// agent pins this exact ID and refuses any other peer — chain
    /// verification alone would let a compromised workload impersonate the
    /// control plane (issue #552). Nil derives the conventional
    /// `spiffe://<trust_domain>/control-plane`, which is what both supported
    /// deployment paths (deploy/compose Envoy and the Helm chart) provision.
    public let controlPlaneSPIFFEID: String?

    public init(
        enabled: Bool = false,
        trustDomain: String? = nil,
        workloadAPISocketPath: String? = nil,
        sourceType: String? = nil,
        certificatePath: String? = nil,
        privateKeyPath: String? = nil,
        trustBundlePath: String? = nil,
        controlPlaneSPIFFEID: String? = nil
    ) {
        self.enabled = enabled
        self.trustDomain = trustDomain
        self.workloadAPISocketPath = workloadAPISocketPath
        self.sourceType = sourceType
        self.certificatePath = certificatePath
        self.privateKeyPath = privateKeyPath
        self.trustBundlePath = trustBundlePath
        self.controlPlaneSPIFFEID = controlPlaneSPIFFEID
    }

    /// The control-plane SPIFFE ID to pin: the configured override, or the
    /// conventional `spiffe://<trust_domain>/control-plane`.
    public var resolvedControlPlaneSPIFFEID: String {
        controlPlaneSPIFFEID ?? "spiffe://\(trustDomain ?? Self.defaultTrustDomain)/control-plane"
    }

    /// Whether `id` is a full SPIFFE ID — `spiffe://<trust-domain>/<path>`
    /// with both parts non-empty. Config load applies this to the *resolved*
    /// ID so a typo in an explicit `control_plane_spiffe_id` and an empty
    /// `trust_domain` are both caught: either way the only symptom would
    /// otherwise be every TLS handshake failing with a pin mismatch.
    public static func isWellFormedSPIFFEID(_ id: String) -> Bool {
        let scheme = "spiffe://"
        guard id.hasPrefix(scheme) else { return false }
        let authorityAndPath = id.dropFirst(scheme.count)
        guard let slash = authorityAndPath.firstIndex(of: "/") else { return false }
        let trustDomain = authorityAndPath[..<slash]
        let path = authorityAndPath[authorityAndPath.index(after: slash)...]
        return !trustDomain.isEmpty && !path.isEmpty
    }

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
public struct OVNNorthboundTLSConfig: Sendable, Equatable {
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

public struct AgentConfig {
    public let controlPlaneURL: String
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
            return DesiredStatePoller.defaultFullRefetchInterval
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

    private init(
        controlPlaneURL: String,
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

    /// Loads the agent configuration from process environment variables layered
    /// over a TOML file. Swift Configuration queries providers in order, so an
    /// environment value always wins over the matching file value.
    public static func load(
        from path: String,
        environmentVariables: [String: String] = ProcessInfo.processInfo.environment,
        logger: Logger? = nil
    ) async throws -> AgentConfig {
        guard FileManager.default.fileExists(atPath: path) else {
            throw AgentConfigError.configFileNotFound(path)
        }

        let tomlProvider = try await TOMLProvider(filePath: .init(path))
        let reader = ConfigReader(providers: [
            EnvironmentVariablesProvider(environmentVariables: environmentVariables),
            tomlProvider,
        ])
        return try await load(from: reader, logger: logger)
    }

    private static func load(from reader: ConfigReader, logger: Logger?) async throws -> AgentConfig {
        let values = AgentConfigReader(reader)
        guard let controlPlaneURL = try await values.string("control_plane_url") else {
            throw AgentConfigError.missingRequiredField("control_plane_url")
        }

        let logLevel = try await values.string("log_level")
        let networkModeString = try await values.string("network_mode")
        let ovnEncapIP = try await values.string("ovn_encap_ip")
        let ovnEncapType = try await values.string("ovn_encap_type")
        let ovnRemote = try await values.string("ovn_remote")
        let ovnBootstrapChassis = try await values.bool("ovn_bootstrap_chassis")
        let ovnNorthbound = try await values.string("ovn_northbound")
        if let ovnNorthbound {
            let validSchemes = ["unix:", "tcp:", "ssl:"]
            guard validSchemes.contains(where: ovnNorthbound.hasPrefix) else {
                throw AgentConfigError.invalidConfiguration(
                    "ovn_northbound must be an OVN connection string (unix:<path>, tcp:<host>:<port>, or ssl:<host>:<port>), got '\(ovnNorthbound)'"
                )
            }
        }
        // A section is present when any recognized value is present. This also
        // lets environment-only nested settings materialize a section.
        let tlsValues = values.scoped(to: "ovn_northbound_tls")
        let tlsCACert = try await tlsValues.string("ca_cert")
        let tlsClientCert = try await tlsValues.string("client_cert")
        let tlsClientKey = try await tlsValues.string("client_key")
        let tlsVerifyServer = try await tlsValues.bool("verify_server_certificate")
        let tlsServerHostname = try await tlsValues.string("server_hostname")
        let hasTLSConfig =
            tlsCACert != nil || tlsClientCert != nil || tlsClientKey != nil
            || tlsVerifyServer != nil || tlsServerHostname != nil
        let ovnNorthboundTLS: OVNNorthboundTLSConfig?
        if hasTLSConfig {
            guard let ovnNorthbound, ovnNorthbound.hasPrefix("ssl:") else {
                throw AgentConfigError.invalidConfiguration(
                    "[ovn_northbound_tls] requires ovn_northbound to be an ssl:<host>:<port> endpoint, "
                        + "got '\(ovnNorthbound ?? "(unset)")'"
                )
            }
            guard (tlsClientCert == nil) == (tlsClientKey == nil) else {
                throw AgentConfigError.invalidConfiguration(
                    "[ovn_northbound_tls] client_cert and client_key must be set together"
                )
            }
            ovnNorthboundTLS = OVNNorthboundTLSConfig(
                caCertPath: tlsCACert,
                clientCertPath: tlsClientCert,
                clientKeyPath: tlsClientKey,
                verifyServerCertificate: tlsVerifyServer ?? true,
                serverHostname: tlsServerHostname
            )
        } else {
            ovnNorthboundTLS = nil
        }
        let enableHVF = try await values.bool("enable_hvf")
        let enableKVM = try await values.bool("enable_kvm")
        let qemuMemoryOverheadMB = try await values.int("qemu_memory_overhead_mb")
        if let qemuMemoryOverheadMB, !Self.qemuMemoryOverheadRange.contains(qemuMemoryOverheadMB) {
            throw AgentConfigError.invalidConfiguration(
                "qemu_memory_overhead_mb must be between 128 and 4096, got \(qemuMemoryOverheadMB)")
        }
        let vmStoragePath = try await values.string("vm_storage_dir")
        let volumeStoragePath = try await values.string("volume_storage_dir")
        let imageCacheDir = try await values.string("image_cache_dir")
        let sandboxImageCacheDir = try await values.string("sandbox_image_cache_dir")
        // Cache budgets must be positive: 0 would mean "evict everything, every
        // time" — an operator who wants no cache bound should omit the key.
        let imageCacheMaxSizeGB = try await Self.positiveInt(values, key: "image_cache_max_size_gb")
        let sandboxImageCacheMaxSizeGB = try await Self.positiveInt(
            values, key: "sandbox_image_cache_max_size_gb")
        // Keys retired with the process QEMU driver (STR-136). Read only to
        // say so: unknown keys are otherwise ignored, and a node whose config
        // still says `qemu_driver = "process"` would change behaviour in
        // silence — which is the one outcome an operator must not discover from
        // a VM that started somewhere unexpected. Warned rather than rejected,
        // so an unattended fleet upgrade is not a fleet-wide outage.
        for (key, note) in [
            ("qemu_driver", "the agent always drives QEMU through libvirtd now"),
            ("qemu_binary_path", "libvirt selects the emulator from its own capabilities"),
            ("swtpm_binary_path", "libvirt starts and supervises swtpm per domain"),
            ("qemu_socket_dir", "libvirt owns each domain's sockets under its own state directory"),
        ] {
            if try await values.string(key) != nil {
                logger?.warning("\(key) is no longer used and will be ignored: \(note) (STR-136)")
            }
        }
        // The pull transport became the only one at wire v38; the pin existed
        // for the push-era rollout.
        if try await values.bool("desired_state_pull") != nil {
            logger?.warning(
                "desired_state_pull is no longer used and will be ignored: the long-poll is the only desired-state transport now"
            )
        }
        let firmwarePathARM64 = try await values.string("firmware_path_arm64")
        let firmwarePathX86_64 = try await values.string("firmware_path_x86_64")
        // Split EDK2 firmware (issue #565). CODE and VARS only mean anything as
        // a pair — a lone code path with no variable store is the `-bios` setup
        // the pair exists to replace — so a half-configured pair is rejected
        // rather than silently ignored.
        let firmwareCodePath = try await values.string("firmware_code_path")
        let firmwareVarsTemplate = try await values.string("firmware_vars_template")
        guard (firmwareCodePath == nil) == (firmwareVarsTemplate == nil) else {
            throw AgentConfigError.invalidConfiguration(
                "firmware_code_path and firmware_vars_template must be set together")
        }
        let secureBootFirmwareCodePath = try await values.string("secure_boot_firmware_code_path")
        let secureBootFirmwareVarsTemplate = try await values.string("secure_boot_firmware_vars_template")
        guard (secureBootFirmwareCodePath == nil) == (secureBootFirmwareVarsTemplate == nil) else {
            throw AgentConfigError.invalidConfiguration(
                "secure_boot_firmware_code_path and secure_boot_firmware_vars_template must be set together")
        }
        let firecrackerBinaryPath = try await values.string("firecracker_binary_path")
        let firecrackerSocketDir = try await values.string("firecracker_socket_dir")
        let sandboxGuestImagePath = try await values.string("sandbox_guest_image_path")
        let hypervisorTypeString = try await values.string("hypervisor_type")

        // Sandbox jailer settings (issue #425). The mode is strictly decoded —
        // a typo like "requierd" silently falling back to auto would quietly
        // weaken a host an operator believed hardened.
        let sandboxJailerMode: SandboxJailerMode?
        if let modeString = try await values.string("sandbox_jailer_mode") {
            guard let mode = SandboxJailerMode(rawValue: modeString) else {
                throw AgentConfigError.invalidConfiguration(
                    "sandbox_jailer_mode must be 'auto', 'required', or 'disabled', got '\(modeString)'")
            }
            sandboxJailerMode = mode
        } else {
            sandboxJailerMode = nil
        }
        let sandboxJailerBinaryPath = try await values.string("sandbox_jailer_binary_path")
        let sandboxJailerChrootDir = try await values.string("sandbox_jailer_chroot_dir")
        let sandboxJailerUidBase: UInt32?
        if let uidBase = try await values.int("sandbox_jailer_uid_base") {
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
        let sandboxWarmStart = try await values.bool("sandbox_warm_start")
        let sandboxWarmCacheMaxSizeGB = try await Self.positiveInt(
            values, key: "sandbox_warm_cache_max_size_gb")

        // Teardown blast-radius guard (STR-98). Zero is meaningful for both
        // numbers — "allow no teardown without the override", and "any batch
        // past the floor is refused" — so neither goes through `positiveInt`;
        // a negative value is clamped to 0 by `TeardownGuard`.
        let reconcileTeardownMinimum = try await values.int("reconcile_teardown_minimum")
        let reconcileTeardownPercent = try await values.int("reconcile_teardown_percent")
        let allowBulkTeardown = try await values.bool("allow_bulk_teardown")

        // Desired-state transport (STR-146).
        let desiredStateFullRefetchSeconds = try await values.int("desired_state_full_refetch_seconds")
        let metadataService = try await values.bool("metadata_service")
        let metadataResponseHopLimit = try await values.int("metadata_response_hop_limit")
        if let metadataResponseHopLimit, !(1...255).contains(metadataResponseHopLimit) {
            // Validated rather than clamped, for `qemu_driver`'s reason: a hop
            // limit outside the IP field's range is a mistake, and silently
            // substituting a working value hides it until someone wonders why
            // the setting did nothing.
            throw AgentConfigError.invalidConfiguration(
                "metadata_response_hop_limit must be between 1 and 255, got \(metadataResponseHopLimit)")
        }

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

        // Parse SPIFFE configuration from its scoped provider view.
        let spiffeValues = values.scoped(to: "spiffe")
        let spiffeEnabled = try await spiffeValues.bool("enabled")
        let trustDomain = try await spiffeValues.string("trust_domain")
        let workloadAPISocketPath = try await spiffeValues.string("workload_api_socket_path")
        let sourceType = try await spiffeValues.string("source_type")
        let certificatePath = try await spiffeValues.string("certificate_path")
        let privateKeyPath = try await spiffeValues.string("private_key_path")
        let trustBundlePath = try await spiffeValues.string("trust_bundle_path")
        let controlPlaneSPIFFEID = try await spiffeValues.string("control_plane_spiffe_id")
        let hasSPIFFEConfig =
            spiffeEnabled != nil || trustDomain != nil || workloadAPISocketPath != nil
            || sourceType != nil || certificatePath != nil || privateKeyPath != nil
            || trustBundlePath != nil || controlPlaneSPIFFEID != nil
        let spiffeConfig: SPIFFEConfig?
        if hasSPIFFEConfig {
            let parsedSPIFFEConfig = SPIFFEConfig(
                enabled: spiffeEnabled ?? false,
                trustDomain: trustDomain,
                workloadAPISocketPath: workloadAPISocketPath,
                sourceType: sourceType,
                certificatePath: certificatePath,
                privateKeyPath: privateKeyPath,
                trustBundlePath: trustBundlePath,
                controlPlaneSPIFFEID: controlPlaneSPIFFEID
            )

            // Validate what actually gets pinned, not just the override: an
            // empty trust_domain derives the equally malformed
            // "spiffe:///control-plane", and either way the only symptom
            // would be every TLS handshake failing with a pin mismatch.
            let resolvedID = parsedSPIFFEConfig.resolvedControlPlaneSPIFFEID
            guard SPIFFEConfig.isWellFormedSPIFFEID(resolvedID) else {
                let source =
                    controlPlaneSPIFFEID == nil
                    ? "derived from trust_domain '\(trustDomain ?? "")'"
                    : "from control_plane_spiffe_id"
                throw AgentConfigError.invalidConfiguration(
                    "The control plane's pinned SPIFFE ID (\(source)) must be a full SPIFFE ID "
                        + "(spiffe://<trust-domain>/<path>), got '\(resolvedID)'"
                )
            }

            spiffeConfig = parsedSPIFFEConfig

            if spiffeEnabled == true {
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

        // Parse the OVN uplink from the [ovn_uplink] scope (issue #342). SNAT
        // egress is off unless a dedicated external CIDR is configured.
        let uplinkValues = values.scoped(to: "ovn_uplink")
        let externalCIDR = try await uplinkValues.string("external_cidr")
        let gateway = try await uplinkValues.string("gateway")
        let bridge = try await uplinkValues.string("bridge")
        let physnet = try await uplinkValues.string("physnet")
        let externalCIDR6 = try await uplinkValues.string("external_cidr6")
        let gateway6 = try await uplinkValues.string("gateway6")
        let hasUplinkConfig =
            externalCIDR != nil || gateway != nil || bridge != nil || physnet != nil
            || externalCIDR6 != nil || gateway6 != nil
        let ovnUplink: OVNUplinkConfig?
        if hasUplinkConfig {
            guard let externalCIDR else {
                throw AgentConfigError.invalidConfiguration(
                    "[ovn_uplink] external_cidr is required when the section is configured")
            }
            ovnUplink = OVNUplinkConfig(
                externalCIDR: externalCIDR,
                gateway: gateway,
                bridge: bridge ?? OVNUplinkConfig.defaultBridge,
                physnet: physnet ?? OVNUplinkConfig.defaultPhysnet,
                externalCIDR6: externalCIDR6,
                gateway6: gateway6
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

        // Parse OVN native dynamic routing from its scoped values (issue #344).
        let routingValues = values.scoped(to: "ovn_dynamic_routing")
        let routingEnabled = try await routingValues.bool("enabled")
        let redistribute = try await routingValues.stringArray("redistribute")
        let vrfName = try await routingValues.string("vrf_name")
        let maintainVRF = try await routingValues.bool("maintain_vrf")
        let routingProtocols = try await routingValues.stringArray("routing_protocols")
        let hasRoutingConfig =
            routingEnabled != nil || redistribute != nil || vrfName != nil
            || maintainVRF != nil || routingProtocols != nil
        let ovnDynamicRouting: OVNDynamicRoutingConfig?
        if hasRoutingConfig {
            let config = OVNDynamicRoutingConfig(
                enabled: routingEnabled ?? false,
                redistribute: redistribute ?? OVNDynamicRoutingConfig.defaultRedistribute,
                vrfName: vrfName,
                maintainVRF: maintainVRF ?? true,
                routingProtocols: routingProtocols ?? OVNDynamicRoutingConfig.defaultRoutingProtocols
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

        // Parse the per-network resolver from its scoped values (STR-40).
        let resolverValues = values.scoped(to: "resolver")
        let resolverEnabled = try await resolverValues.bool("enabled")
        let corednsBinaryPath = try await resolverValues.string("coredns_binary_path")
        let resolverConfigDirectory = try await resolverValues.string("config_dir")
        let resolverRatePPS = try await resolverValues.int("rate_limit_pps")
        let hasResolverConfig =
            resolverEnabled != nil || corednsBinaryPath != nil
            || resolverConfigDirectory != nil || resolverRatePPS != nil
        let resolver: NetworkResolverConfig?
        if hasResolverConfig {
            guard resolverRatePPS.map({ $0 >= 0 }) ?? true else {
                throw AgentConfigError.invalidConfiguration(
                    "[resolver] rate_limit_pps must be zero (no limit) or a positive integer")
            }
            resolver = NetworkResolverConfig(
                enabled: resolverEnabled ?? true,
                corednsBinaryPath: corednsBinaryPath,
                configDirectory: resolverConfigDirectory,
                rateLimitPPS: resolverRatePPS)
        } else {
            resolver = nil
        }

        // Parse simulation ("dummy agent") settings from its scoped values.
        let simulationValues = values.scoped(to: "simulation")
        let simulationEnabled = try await simulationValues.bool("enabled")
        let simulationCPUCores = try await simulationValues.int("cpu_cores")
        let simulationMemoryMB = try await simulationValues.int("memory_mb")
        let simulationDiskGB = try await simulationValues.int("disk_gb")
        let simulationLogIntervalMS = try await simulationValues.int("sandbox_log_interval_ms")
        let simulationExitAfterSeconds = try await simulationValues.int("sandbox_exit_after_seconds")
        let hasSimulationConfig =
            simulationEnabled != nil || simulationCPUCores != nil || simulationMemoryMB != nil
            || simulationDiskGB != nil || simulationLogIntervalMS != nil
            || simulationExitAfterSeconds != nil
        let simulationConfig: SimulationConfig?
        if hasSimulationConfig {
            simulationConfig = SimulationConfig(
                enabled: simulationEnabled ?? false,
                cpuCores: simulationCPUCores,
                memoryMB: simulationMemoryMB,
                diskGB: simulationDiskGB,
                sandboxLogIntervalMS: simulationLogIntervalMS,
                sandboxExitAfterSeconds: simulationExitAfterSeconds
            )
            if simulationEnabled == true {
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
            qemuMemoryOverheadMB: qemuMemoryOverheadMB,
            vmStoragePath: vmStoragePath,
            volumeStoragePath: volumeStoragePath,
            imageCacheDir: imageCacheDir,
            imageCacheMaxSizeGB: imageCacheMaxSizeGB,
            sandboxImageCacheDir: sandboxImageCacheDir,
            sandboxImageCacheMaxSizeGB: sandboxImageCacheMaxSizeGB,
            firmwarePathARM64: firmwarePathARM64,
            firmwarePathX86_64: firmwarePathX86_64,
            firmwareCodePath: firmwareCodePath,
            firmwareVarsTemplate: firmwareVarsTemplate,
            secureBootFirmwareCodePath: secureBootFirmwareCodePath,
            secureBootFirmwareVarsTemplate: secureBootFirmwareVarsTemplate,
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
            resolver: resolver,
            simulation: simulationConfig,
            reconcileTeardownMinimum: reconcileTeardownMinimum,
            reconcileTeardownPercent: reconcileTeardownPercent,
            allowBulkTeardown: allowBulkTeardown,
            desiredStateFullRefetchSeconds: desiredStateFullRefetchSeconds,
            metadataService: metadataService,
            metadataResponseHopLimit: metadataResponseHopLimit
        )
    }

    /// Reads an integer key that must be positive when present.
    private static func positiveInt(_ values: AgentConfigReader, key: String) async throws -> Int? {
        guard let value = try await values.int(key) else { return nil }
        guard value > 0 else {
            throw AgentConfigError.invalidConfiguration("\(key) must be a positive integer, got \(value)")
        }
        return value
    }

    /// Small throwing facade over ConfigReader's typed fetch APIs. ConfigReader's
    /// synchronous optional getters intentionally hide provider conversion errors;
    /// configuration loading must instead reject malformed environment overrides.
    private struct AgentConfigReader: Sendable {
        let reader: ConfigReader
        let prefix: String?

        init(_ reader: ConfigReader, prefix: String? = nil) {
            self.reader = reader
            self.prefix = prefix
        }

        func scoped(to key: String) -> Self {
            Self(reader.scoped(to: ConfigKey(key)), prefix: qualified(key))
        }

        func string(_ key: String) async throws -> String? {
            try await fetch(key) { try await reader.fetchString(forKey: ConfigKey(key)) }
        }

        func int(_ key: String) async throws -> Int? {
            try await fetch(key) { try await reader.fetchInt(forKey: ConfigKey(key)) }
        }

        func bool(_ key: String) async throws -> Bool? {
            try await fetch(key) { try await reader.fetchBool(forKey: ConfigKey(key)) }
        }

        func stringArray(_ key: String) async throws -> [String]? {
            try await fetch(key) { try await reader.fetchStringArray(forKey: ConfigKey(key)) }
        }

        private func fetch<Value: Sendable>(
            _ key: String,
            operation: () async throws -> Value?
        ) async throws -> Value? {
            do {
                return try await operation()
            } catch {
                throw AgentConfigError.invalidConfiguration(
                    "\(qualified(key)) could not be read: \(error)")
            }
        }

        private func qualified(_ key: String) -> String {
            prefix.map { "\($0).\(key)" } ?? key
        }
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

    /// Paths `loadDefaultConfig` probes, in order: the platform config location
    /// first, then a working-directory file for development.
    public static var defaultConfigSearchPaths: [String] {
        [defaultConfigPath, fallbackConfigPath]
    }

    /// Loads the first config file that parses out of `searchPaths`. Environment
    /// values override each candidate. If no file loads, the same environment
    /// values are applied over the compiled-in defaults.
    public static func loadDefaultConfig(
        searchPaths: [String] = defaultConfigSearchPaths,
        environmentVariables: [String: String] = ProcessInfo.processInfo.environment,
        logger: Logger? = nil
    ) async throws -> AgentConfig {
        for path in searchPaths {
            do {
                return try await load(
                    from: path,
                    environmentVariables: environmentVariables,
                    logger: logger)
            } catch {
                logger?.warning("Failed to load config from \(path): \(error)")
            }
        }

        logger?.info("Using default configuration")
        let defaults = builtinDefaults
        let defaultValues: [AbsoluteConfigKey: ConfigValue] = [
            "control_plane_url": ConfigValue(.string(defaults.controlPlaneURL), isSecret: false),
            "log_level": ConfigValue(.string(defaults.logLevel ?? "info"), isSecret: false),
            "network_mode": ConfigValue(
                .string(defaults.networkMode?.rawValue ?? NetworkMode.user.rawValue), isSecret: false),
            "enable_hvf": ConfigValue(.bool(defaults.enableHVF ?? false), isSecret: false),
            "enable_kvm": ConfigValue(.bool(defaults.enableKVM ?? false), isSecret: false),
            "vm_storage_dir": ConfigValue(
                .string(defaults.vmStoragePath ?? defaultVMStoragePath), isSecret: false),
        ]
        let reader = ConfigReader(providers: [
            EnvironmentVariablesProvider(environmentVariables: environmentVariables),
            InMemoryProvider(name: "agent-built-in-defaults", values: defaultValues),
        ])
        return try await load(from: reader, logger: logger)
    }

    /// The compiled-in configuration used when no config file is found. Paths
    /// delegate to the dedicated `default*` properties rather than repeating
    /// them, so this can't drift from the fallbacks the CLI applies when a
    /// config file leaves a key unset.
    public static var builtinDefaults: AgentConfig {
        #if os(Linux)
        let networkMode = NetworkMode.ovn
        let enableHVF = false
        let enableKVM = true
        #else
        let networkMode = NetworkMode.user
        let enableHVF = true
        let enableKVM = false
        #endif
        return AgentConfig(
            controlPlaneURL: "ws://localhost:8080/agent/ws",
            logLevel: "info",
            networkMode: networkMode,
            enableHVF: enableHVF,
            enableKVM: enableKVM,
            vmStoragePath: defaultVMStoragePath
        )
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

    /// Well-known jailer install locations probed after the Firecracker sibling.
    public static let wellKnownSandboxJailerPaths = ["/usr/local/bin/jailer", "/usr/bin/jailer"]

    /// Default jailer binary path (Linux only). The jailer ships in the same
    /// release tarball as Firecracker, so look beside the resolved Firecracker
    /// binary first, then the same well-known locations. `wellKnownPaths` is
    /// injectable so tests can probe a fixture instead of the host's installs.
    public static func defaultSandboxJailerBinaryPath(
        firecrackerBinaryPath: String,
        wellKnownPaths: [String] = wellKnownSandboxJailerPaths
    ) -> String {
        let sibling = URL(fileURLWithPath: firecrackerBinaryPath)
            .deletingLastPathComponent().appendingPathComponent("jailer").path
        let candidates = [sibling] + wellKnownPaths
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
    case missingRequiredField(String)
    case invalidConfiguration(String)

    public var errorDescription: String? {
        switch self {
        case .configFileNotFound(let path):
            return "Configuration file not found at path: \(path)"
        case .missingRequiredField(let field):
            return "Missing required configuration field: \(field)"
        case .invalidConfiguration(let message):
            return "Invalid configuration: \(message)"
        }
    }
}
