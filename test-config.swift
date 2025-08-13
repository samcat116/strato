#!/usr/bin/env swift

// Quick test script to verify TOML configuration loading
import Foundation

// Copy AgentConfig implementation for testing
import Toml

struct AgentConfig: Codable {
    let controlPlaneURL: String
    let qemuSocketDir: String?
    let logLevel: String?
    
    enum CodingKeys: String, CodingKey {
        case controlPlaneURL = "control_plane_url"
        case qemuSocketDir = "qemu_socket_dir"
        case logLevel = "log_level"
    }
    
    static func load(from path: String) throws -> AgentConfig {
        let fileURL = URL(fileURLWithPath: path)
        
        guard FileManager.default.fileExists(atPath: path) else {
            throw NSError(domain: "ConfigError", code: 1, userInfo: [NSLocalizedDescriptionKey: "Config file not found at path: \(path)"])
        }
        
        let tomlString = try String(contentsOf: fileURL, encoding: .utf8)
        let tomlData = try Toml(withString: tomlString)
        
        guard let controlPlaneURL = tomlData.string("control_plane_url") else {
            throw NSError(domain: "ConfigError", code: 2, userInfo: [NSLocalizedDescriptionKey: "Missing required field: control_plane_url"])
        }
        
        let qemuSocketDir = tomlData.string("qemu_socket_dir")
        let logLevel = tomlData.string("log_level")
        
        return AgentConfig(
            controlPlaneURL: controlPlaneURL,
            qemuSocketDir: qemuSocketDir,
            logLevel: logLevel
        )
    }
}

// Test the configuration loading
do {
    let config = try AgentConfig.load(from: "config.toml")
    print("✅ TOML Configuration loaded successfully!")
    print("Control Plane URL: \(config.controlPlaneURL)")
    print("QEMU Socket Dir: \(config.qemuSocketDir ?? "default")")
    print("Log Level: \(config.logLevel ?? "default")")
} catch {
    print("❌ Failed to load configuration: \(error)")
}