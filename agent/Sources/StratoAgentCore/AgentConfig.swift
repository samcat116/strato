import Foundation
import Toml
import Logging
import StratoShared

public enum NetworkMode: String, Codable {
    case ovn
    case user
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

public struct AgentConfig: Codable {
    public let controlPlaneURL: String
    public let qemuSocketDir: String?
    public let logLevel: String?
    public let networkMode: NetworkMode?
    public let enableHVF: Bool?
    public let enableKVM: Bool?
    public let vmStoragePath: String?
    public let qemuBinaryPath: String?
    public let firmwarePathARM64: String?
    public let firmwarePathX86_64: String?
    public let spiffe: SPIFFEConfig?
    public let firecrackerBinaryPath: String?
    public let firecrackerSocketDir: String?
    public let hypervisorType: HypervisorType?

    enum CodingKeys: String, CodingKey {
        case controlPlaneURL = "control_plane_url"
        case qemuSocketDir = "qemu_socket_dir"
        case logLevel = "log_level"
        case networkMode = "network_mode"
        case enableHVF = "enable_hvf"
        case enableKVM = "enable_kvm"
        case vmStoragePath = "vm_storage_dir"
        case qemuBinaryPath = "qemu_binary_path"
        case firmwarePathARM64 = "firmware_path_arm64"
        case firmwarePathX86_64 = "firmware_path_x86_64"
        case spiffe
        case firecrackerBinaryPath = "firecracker_binary_path"
        case firecrackerSocketDir = "firecracker_socket_dir"
        case hypervisorType = "hypervisor_type"
    }

    public init(
        controlPlaneURL: String,
        qemuSocketDir: String? = nil,
        logLevel: String? = nil,
        networkMode: NetworkMode? = nil,
        enableHVF: Bool? = nil,
        enableKVM: Bool? = nil,
        vmStoragePath: String? = nil,
        qemuBinaryPath: String? = nil,
        firmwarePathARM64: String? = nil,
        firmwarePathX86_64: String? = nil,
        spiffe: SPIFFEConfig? = nil,
        firecrackerBinaryPath: String? = nil,
        firecrackerSocketDir: String? = nil,
        hypervisorType: HypervisorType? = nil
    ) {
        self.controlPlaneURL = controlPlaneURL
        self.qemuSocketDir = qemuSocketDir
        self.logLevel = logLevel
        self.networkMode = networkMode
        self.enableHVF = enableHVF
        self.enableKVM = enableKVM
        self.vmStoragePath = vmStoragePath
        self.qemuBinaryPath = qemuBinaryPath
        self.firmwarePathARM64 = firmwarePathARM64
        self.firmwarePathX86_64 = firmwarePathX86_64
        self.spiffe = spiffe
        self.firecrackerBinaryPath = firecrackerBinaryPath
        self.firecrackerSocketDir = firecrackerSocketDir
        self.hypervisorType = hypervisorType
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
        let enableHVF = tomlData.bool("enable_hvf")
        let enableKVM = tomlData.bool("enable_kvm")
        let vmStoragePath = tomlData.string("vm_storage_dir")
        let qemuBinaryPath = tomlData.string("qemu_binary_path")
        let firmwarePathARM64 = tomlData.string("firmware_path_arm64")
        let firmwarePathX86_64 = tomlData.string("firmware_path_x86_64")
        let firecrackerBinaryPath = tomlData.string("firecracker_binary_path")
        let firecrackerSocketDir = tomlData.string("firecracker_socket_dir")
        let hypervisorTypeString = tomlData.string("hypervisor_type")

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
                throw AgentConfigError.invalidConfiguration("hypervisor_type must be 'qemu' or 'firecracker', got '\(typeString)'")
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
                logger?.info("SPIFFE authentication enabled", metadata: [
                    "trustDomain": .string(trustDomain ?? SPIFFEConfig.defaultTrustDomain),
                    "sourceType": .string(sourceType ?? "workload_api")
                ])
            }
        } else {
            spiffeConfig = nil
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
            enableHVF: enableHVF,
            enableKVM: enableKVM,
            vmStoragePath: vmStoragePath,
            qemuBinaryPath: qemuBinaryPath,
            firmwarePathARM64: firmwarePathARM64,
            firmwarePathX86_64: firmwarePathX86_64,
            spiffe: spiffeConfig,
            firecrackerBinaryPath: firecrackerBinaryPath,
            firecrackerSocketDir: firecrackerSocketDir,
            hypervisorType: hypervisorType
        )
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
            #if arch(arm64)
            return "/opt/homebrew/bin/qemu-system-aarch64"
            #else
            return "/opt/homebrew/bin/qemu-system-x86_64"
            #endif
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
            "/usr/share/edk2/aarch64/QEMU_EFI.fd"
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
            "/usr/share/qemu/OVMF.fd"
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
            "/usr/bin/firecracker"
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