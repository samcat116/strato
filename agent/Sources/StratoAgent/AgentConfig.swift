import Foundation
import Toml
import Logging

struct AgentConfig: Codable {
    let controlPlaneURL: String
    let qemuSocketDir: String?
    let logLevel: String?
    
    enum CodingKeys: String, CodingKey {
        case controlPlaneURL = "control_plane_url"
        case qemuSocketDir = "qemu_socket_dir"
        case logLevel = "log_level"
    }
    
    init(controlPlaneURL: String, qemuSocketDir: String? = nil, logLevel: String? = nil) {
        self.controlPlaneURL = controlPlaneURL
        self.qemuSocketDir = qemuSocketDir
        self.logLevel = logLevel
    }
    
    static func load(from path: String) throws -> AgentConfig {
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
        
        return AgentConfig(
            controlPlaneURL: controlPlaneURL,
            qemuSocketDir: qemuSocketDir,
            logLevel: logLevel
        )
    }
    
    static let defaultConfigPath = "/etc/strato/config.toml"
    static let fallbackConfigPath = "./config.toml"
    
    static func loadDefaultConfig(logger: Logger? = nil) -> AgentConfig {
        // Try to load from default path first
        do {
            return try load(from: defaultConfigPath)
        } catch {
            logger?.warning("Failed to load config from \(defaultConfigPath): \(error)")
        }
        
        // Try fallback path for development
        do {
            return try load(from: fallbackConfigPath)
        } catch {
            logger?.warning("Failed to load config from \(fallbackConfigPath): \(error)")
        }
        
        // Return default configuration if no config file found
        logger?.info("Using default configuration")
        return AgentConfig(
            controlPlaneURL: "ws://localhost:8080/agent/ws",
            qemuSocketDir: "/var/run/qemu",
            logLevel: "info"
        )
    }
}

enum AgentConfigError: Error, LocalizedError {
    case configFileNotFound(String)
    case invalidTOMLFormat(String)
    case missingRequiredField(String)
    
    var errorDescription: String? {
        switch self {
        case .configFileNotFound(let path):
            return "Configuration file not found at path: \(path)"
        case .invalidTOMLFormat(let details):
            return "Invalid TOML format: \(details)"
        case .missingRequiredField(let field):
            return "Missing required configuration field: \(field)"
        }
    }
}