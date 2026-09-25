import StratoShared
import StratoAgentCore
@testable import StratoAgentRuntime

func runtimeTestConfiguration(
    path: String, volumeStoragePath: String = FileSystemStorageBackend.defaultStoragePath,
    simulation: SimulationConfig? = nil, hypervisorType: HypervisorType = .qemu
) -> AgentRuntimeConfiguration {
    AgentRuntimeConfiguration(
        networkMode: nil,
        ovnChassisConfig: OVNChassisConfig(),
        ovnUplink: nil,
        ovnDynamicRouting: nil,
        resolverConfig: nil,
        ovnNorthbound: nil,
        ovnNorthboundTLS: nil,
        imageCachePath: nil,
        imageCacheMaxSizeBytes: nil,
        sandboxImageCachePath: nil,
        sandboxImageCacheMaxSizeBytes: nil,
        vmStoragePath: path,
        volumeStoragePath: volumeStoragePath,
        firmware: FirmwareOverrides(),
        firecrackerBinaryPath: "/usr/bin/firecracker",
        firecrackerSocketDir: "/tmp/firecracker",
        sandboxGuestImagePath: nil,
        sandboxJailerMode: .auto,
        sandboxJailerBinaryPath: "/usr/local/bin/jailer",
        sandboxJailerChrootDir: "/var/lib/strato/vms/jailer",
        sandboxJailerUidBase: AgentConfig.defaultSandboxJailerUidBase,
        legacySandboxJailerUidBase: AgentConfig.defaultSandboxJailerUidBase,
        sandboxWarmStart: true,
        sandboxWarmCacheMaxSizeBytes: nil,
        hypervisorType: hypervisorType,
        hardwareAccelerationEnabled: true,
        qemuMemoryOverheadBytes: Int64(AgentConfig.defaultQEMUMemoryOverheadMB) * 1024 * 1024,
        simulation: simulation,
        installMode: .detect(),
        spiffeConfig: nil,
        teardownGuard: TeardownGuard(),
        desiredStateFullRefetchInterval: DesiredStatePoller<ContinuousClock>.defaultFullRefetchInterval,
        metadataServiceEnabled: true,
        metadataHopLimit: 1)
}
