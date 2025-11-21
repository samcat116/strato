import Foundation
import Toml
import Logging

enum NetworkMode: String, Codable {
    case ovn
    case user
}

struct AgentConfig: Codable {
    let controlPlaneURL: String
    let qemuSocketDir: String?
    let logLevel: String?
    let networkMode: NetworkMode?
    let enableHVF: Bool?
    let enableKVM: Bool?

    enum CodingKeys: String, CodingKey {
        case controlPlaneURL = "control_plane_url"
        case qemuSocketDir = "qemu_socket_dir"
        case logLevel = "log_level"
        case networkMode = "network_mode"
        case enableHVF = "enable_hvf"
        case enableKVM = "enable_kvm"
    }

    init(
        controlPlaneURL: String,
        qemuSocketDir: String? = nil,
        logLevel: String? = nil,
        networkMode: NetworkMode? = nil,
        enableHVF: Bool? = nil,
        enableKVM: Bool? = nil
    ) {
        self.controlPlaneURL = controlPlaneURL
        self.qemuSocketDir = qemuSocketDir
        self.logLevel = logLevel
        self.networkMode = networkMode
        self.enableHVF = enableHVF
        self.enableKVM = enableKVM
    }
    
    static func load(from path: String, logger: Logger? = nil) throws -> AgentConfig {
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
            enableKVM: enableKVM
        )
    }
    
    static let defaultConfigPath = "/etc/strato/config.toml"
    static let fallbackConfigPath = "./config.toml"
    
    static func loadDefaultConfig(logger: Logger? = nil) -> AgentConfig {
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
        return AgentConfig(
            controlPlaneURL: "ws://localhost:8080/agent/ws",
            qemuSocketDir: "/var/run/qemu",
            logLevel: "info",
            networkMode: .ovn,
            enableHVF: false,
            enableKVM: true
        )
        #else
        return AgentConfig(
            controlPlaneURL: "ws://localhost:8080/agent/ws",
            qemuSocketDir: "/var/run/qemu",
            logLevel: "info",
            networkMode: .user,
            enableHVF: true,
            enableKVM: false
        )
        #endif
    }
}

enum AgentConfigError: Error, LocalizedError {
    case configFileNotFound(String)
    case invalidTOMLFormat(String)
    case missingRequiredField(String)
    case invalidConfiguration(String)
    
    var errorDescription: String? {
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