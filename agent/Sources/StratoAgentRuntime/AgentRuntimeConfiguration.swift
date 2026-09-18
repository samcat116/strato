import Foundation
import StratoAgentCore
import StratoShared

/// Immutable settings after TOML, CLI overrides, and platform defaults are resolved.
/// Agent owns runtime state; bootstrap owns configuration policy.
struct AgentRuntimeConfiguration: Sendable {
    let networkMode: NetworkMode?
    // Chassis-level OVN settings (ovn-remote/encap external_ids) the network
    // service bootstraps onto the local OVS at connect time.
    let ovnChassisConfig: OVNChassisConfig
    let ovnUplink: OVNUplinkConfig?
    // OVN native dynamic routing (issue #344): BGP advertisement of floating
    // IPs / connected routes via FRR on the egress host.
    let ovnDynamicRouting: OVNDynamicRoutingConfig?
    // Per-network DNS resolver settings (STR-40). Nil means the defaults, which
    // is deliberately "on": the feature is an opt-out on the *network*, so a
    // host whose config says nothing about it is one that should run it.
    let resolverConfig: NetworkResolverConfig?
    let ovnNorthbound: String?
    // TLS material for an ssl: ovn_northbound endpoint (nil = tcp/unix).
    let ovnNorthboundTLS: OVNNorthboundTLSConfig?
    let imageCachePath: String?
    // Byte budgets for the image caches; nil means unbounded (see
    // image_cache_max_size_gb / sandbox_image_cache_max_size_gb).
    let imageCacheMaxSizeBytes: Int64?
    let sandboxImageCachePath: String?
    let sandboxImageCacheMaxSizeBytes: Int64?
    let vmStoragePath: String
    // Root of the managed-volume tree for the filesystem storage backend and
    // the host preflight's writability probe.
    let volumeStoragePath: String
    // Operator-configured EDK2 firmware paths (issue #565): the split
    // CODE/VARS pairs and the legacy monolithic image.
    let firmware: FirmwareOverrides
    let firecrackerBinaryPath: String
    let firecrackerSocketDir: String
    // Where the sandbox guest base image (issue #419) is installed; its
    // presence gates the sandbox-runtime capability advertised at
    // registration (issue #415).
    let sandboxGuestImagePath: String?
    // Sandbox jailer policy (issue #425): resolved once at start() into
    // either a SandboxJailerConfig for the runtime or, when mode is
    // `required` and the host can't satisfy it, a blocked-reason that keeps
    // the sandbox capability dark at every registration.
    let sandboxJailerMode: SandboxJailerMode
    let sandboxJailerBinaryPath: String
    let sandboxJailerChrootDir: String
    let sandboxJailerUidBase: UInt32
    /// Base used only to reconstruct manifests written before jailUID was
    /// persisted. This remains the old default when the current allocation
    /// default moves, unless the operator explicitly configured a base.
    let legacySandboxJailerUidBase: UInt32
    // Warm start (issue #426): provision sandboxes from per-image template
    // snapshots when possible. Default on; warm failures cold-boot.
    let sandboxWarmStart: Bool
    let sandboxWarmCacheMaxSizeBytes: Int64?
    let hypervisorType: HypervisorType
    let hardwareAccelerationEnabled: Bool
    let qemuMemoryOverheadBytes: Int64
    // Simulation ("dummy agent") mode: the agent speaks the full control-plane
    // protocol but drives a no-op mock hypervisor with no real
    // networking/storage, and reports the configured fake host capacity instead
    // of probing the machine. Lets a fleet of dummies scale-test a control plane
    // far larger than the compute available to run real VMs. Nil/disabled means
    // a normal agent.
    let simulation: SimulationConfig?
    let installMode: AgentInstallMode
    // SPIFFE/SPIRE support
    let spiffeConfig: SPIFFEConfig?
    // How much of this host one sync's confirmed teardowns may remove (STR-98).
    let teardownGuard: TeardownGuard
    // Desired-state transport (STR-146): the long-poll loop, started once
    // registration confirms the control plane.
    let desiredStateFullRefetchInterval: Duration
    let metadataServiceEnabled: Bool
    let metadataHopLimit: Int
}
