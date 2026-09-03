import Foundation

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
