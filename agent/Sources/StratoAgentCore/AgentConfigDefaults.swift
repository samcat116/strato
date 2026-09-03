import Foundation
import Configuration
import Logging
import StratoShared

extension AgentConfig {
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

    /// Loads the first config file that exists in `searchPaths`, or falls back
    /// to the built-in defaults when none exist. A present file must be valid:
    /// silently skipping it could start the agent with unintended defaults.
    /// `searchPaths` is injectable so tests can pin the search (or skip it
    /// entirely) instead of reading whatever the host operator installed.
    public static func loadDefaultConfig(
        searchPaths: [String] = defaultConfigSearchPaths,
        environmentVariables: [String: String] = ProcessInfo.processInfo.environment,
        logger: Logger? = nil
    ) async throws -> AgentConfig {
        for path in searchPaths {
            guard FileManager.default.fileExists(atPath: path) else { continue }
            return try await load(
                from: path,
                environmentVariables: environmentVariables,
                logger: logger)
        }

        // Return default configuration only if no config file was found.
        logger?.info("Using default configuration")
        let defaults = builtinDefaults
        let defaultValues: [AbsoluteConfigKey: ConfigValue] = [
            "control_plane_url": ConfigValue(.string(defaults.controlPlaneURL), isSecret: false),
            "log_level": ConfigValue(.string(defaults.logLevel?.rawValue ?? "info"), isSecret: false),
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
            controlPlaneURL: "wss://localhost:8443/agent/ws",
            logLevel: .info,
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
        FirmwareResolver.defaultMonolithicPath(architecture: .arm64)
    }

    /// Default UEFI firmware path for x86_64 guests (platform-specific)
    /// Used when VMs boot from disk images rather than direct kernel boot
    public static var defaultFirmwarePathX86_64: String? {
        FirmwareResolver.defaultMonolithicPath(architecture: .x86_64)
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

    /// Lowest configurable jail uid/gid base. The first 65536 ids include the
    /// conventional system, login, nobody, and dynamic-user bands; exact host
    /// ownership and subordinate delegations are checked by `HostPreflight`.
    public static let minimumSandboxJailerUidBase: UInt32 = SandboxJailerConfig.minimumUIDBase

    /// The implicit base used by builds before STR-290. Kept solely so a
    /// manifest entry without a persisted jail uid can adopt the identity its
    /// already-created jail actually used after the default changes.
    public static let legacySandboxJailerUidBase: UInt32 = 100_000

    /// Default first uid of the per-sandbox uid/gid range. 0x70000000 starts
    /// immediately above systemd-nspawn's conventional automatic allocation
    /// band and above the shadow suite's default subordinate-id band, while
    /// remaining below the signed 32-bit boundary. Host preflight remains the
    /// authority for the actual machine.
    public static let defaultSandboxJailerUidBase: UInt32 = 0x7000_0000

    /// Default hypervisor type (platform-specific)
    /// Linux defaults to QEMU, but can be configured to use Firecracker
    public static var defaultHypervisorType: HypervisorType {
        return .qemu
    }
}
