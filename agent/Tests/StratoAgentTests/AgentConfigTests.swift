import Testing
import Foundation
import Logging
@testable import StratoAgentCore

@Suite("AgentConfig Tests")
struct AgentConfigTests {

    // Helper to create and clean up temporary directories
    func withTempDirectory<T>(_ body: (URL) throws -> T) rethrows -> T {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-config-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)

        defer {
            try? FileManager.default.removeItem(at: tempDirectory)
        }

        return try body(tempDirectory)
    }

    // MARK: - Initialization Tests

    @Test("AgentConfig initializes with all parameters")
    func agentConfigInitialization() {
        let config = AgentConfig(
            controlPlaneURL: "ws://localhost:8080/agent/ws",
            qemuSocketDir: "/var/run/qemu",
            logLevel: "debug",
            networkMode: .ovn,
            enableHVF: false,
            enableKVM: true
        )

        #expect(config.controlPlaneURL == "ws://localhost:8080/agent/ws")
        #expect(config.qemuSocketDir == "/var/run/qemu")
        #expect(config.logLevel == "debug")
        #expect(config.networkMode == .ovn)
        #expect(config.enableHVF == false)
        #expect(config.enableKVM == true)
    }

    @Test("AgentConfig initializes with nil optional values")
    func agentConfigInitializationWithNilValues() {
        let config = AgentConfig(
            controlPlaneURL: "ws://test:8080/ws"
        )

        #expect(config.controlPlaneURL == "ws://test:8080/ws")
        #expect(config.qemuSocketDir == nil)
        #expect(config.logLevel == nil)
        #expect(config.networkMode == nil)
        #expect(config.enableHVF == nil)
        #expect(config.enableKVM == nil)
    }

    // MARK: - TOML Loading Tests

    @Test("Load valid TOML configuration")
    func loadValidConfig() throws {
        try withTempDirectory { tempDirectory in
            let tomlContent = """
            control_plane_url = "ws://localhost:8080/agent/ws"
            qemu_socket_dir = "/var/run/qemu"
            log_level = "info"
            network_mode = "ovn"
            enable_hvf = false
            enable_kvm = true
            """

            let configPath = tempDirectory.appendingPathComponent("config.toml").path
            try tomlContent.write(toFile: configPath, atomically: true, encoding: .utf8)

            let config = try AgentConfig.load(from: configPath)

            #expect(config.controlPlaneURL == "ws://localhost:8080/agent/ws")
            #expect(config.qemuSocketDir == "/var/run/qemu")
            #expect(config.logLevel == "info")
            #expect(config.networkMode == .ovn)
            #expect(config.enableHVF == false)
            #expect(config.enableKVM == true)
        }
    }

    @Test("Load minimal TOML configuration")
    func loadMinimalConfig() throws {
        try withTempDirectory { tempDirectory in
            let tomlContent = """
            control_plane_url = "ws://minimal:8080/ws"
            """

            let configPath = tempDirectory.appendingPathComponent("minimal.toml").path
            try tomlContent.write(toFile: configPath, atomically: true, encoding: .utf8)

            let config = try AgentConfig.load(from: configPath)

            #expect(config.controlPlaneURL == "ws://minimal:8080/ws")
            #expect(config.qemuSocketDir == nil)
            #expect(config.logLevel == nil)
            #expect(config.networkMode == nil)
        }
    }

    @Test("Load configuration with user network mode")
    func loadConfigWithUserNetworkMode() throws {
        try withTempDirectory { tempDirectory in
            let tomlContent = """
            control_plane_url = "ws://localhost:8080/agent/ws"
            network_mode = "user"
            """

            let configPath = tempDirectory.appendingPathComponent("user-mode.toml").path
            try tomlContent.write(toFile: configPath, atomically: true, encoding: .utf8)

            let config = try AgentConfig.load(from: configPath)

            #expect(config.networkMode == .user)
        }
    }

    // MARK: - Error Handling Tests

    @Test("Loading non-existent config file throws error")
    func loadConfigFileNotFound() {
        let nonExistentPath = "/tmp/does-not-exist-\(UUID().uuidString).toml"

        #expect(throws: AgentConfigError.self) {
            try AgentConfig.load(from: nonExistentPath)
        }
    }

    @Test("Loading config without required field throws error")
    func loadConfigMissingRequiredField() throws {
        try withTempDirectory { tempDirectory in
            let tomlContent = """
            qemu_socket_dir = "/var/run/qemu"
            log_level = "debug"
            """

            let configPath = tempDirectory.appendingPathComponent("missing-url.toml").path
            try tomlContent.write(toFile: configPath, atomically: true, encoding: .utf8)

            #expect(throws: AgentConfigError.self) {
                try AgentConfig.load(from: configPath)
            }
        }
    }

    @Test("Loading config with invalid network mode throws error")
    func loadConfigInvalidNetworkMode() throws {
        try withTempDirectory { tempDirectory in
            let tomlContent = """
            control_plane_url = "ws://localhost:8080/agent/ws"
            network_mode = "invalid_mode"
            """

            let configPath = tempDirectory.appendingPathComponent("invalid-mode.toml").path
            try tomlContent.write(toFile: configPath, atomically: true, encoding: .utf8)

            #expect(throws: AgentConfigError.self) {
                try AgentConfig.load(from: configPath)
            }
        }
    }

    @Test("Loading invalid TOML throws error")
    func loadConfigInvalidTOML() throws {
        try withTempDirectory { tempDirectory in
            let invalidToml = """
            control_plane_url = ws://localhost:8080/agent/ws
            [this is not valid toml
            """

            let configPath = tempDirectory.appendingPathComponent("invalid.toml").path
            try invalidToml.write(toFile: configPath, atomically: true, encoding: .utf8)

            #expect(throws: Error.self) {
                try AgentConfig.load(from: configPath)
            }
        }
    }

    // MARK: - Default Config Tests

    @Test("Load default configuration")
    func loadDefaultConfig() {
        let config = AgentConfig.loadDefaultConfig()

        #expect(config.controlPlaneURL == "ws://localhost:8080/agent/ws")

        #if os(Linux)
        #expect(config.networkMode == .ovn)
        #expect(config.enableKVM == true)
        #expect(config.enableHVF == false)
        #else
        #expect(config.networkMode == .user)
        #expect(config.enableHVF == true)
        #expect(config.enableKVM == false)
        #endif
    }

    // MARK: - Codable Tests

    @Test("AgentConfig can be encoded and decoded")
    func agentConfigEncodingDecoding() throws {
        let originalConfig = AgentConfig(
            controlPlaneURL: "ws://test:9000/ws",
            qemuSocketDir: "/custom/qemu",
            logLevel: "trace",
            networkMode: .user,
            enableHVF: true,
            enableKVM: false
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(originalConfig)

        let decoder = JSONDecoder()
        let decodedConfig = try decoder.decode(AgentConfig.self, from: data)

        #expect(decodedConfig.controlPlaneURL == originalConfig.controlPlaneURL)
        #expect(decodedConfig.qemuSocketDir == originalConfig.qemuSocketDir)
        #expect(decodedConfig.logLevel == originalConfig.logLevel)
        #expect(decodedConfig.networkMode == originalConfig.networkMode)
        #expect(decodedConfig.enableHVF == originalConfig.enableHVF)
        #expect(decodedConfig.enableKVM == originalConfig.enableKVM)
    }

    // MARK: - Error Description Tests

    @Test("AgentConfigError provides descriptive messages")
    func agentConfigErrorDescriptions() {
        let fileNotFoundError = AgentConfigError.configFileNotFound("/test/path")
        #expect(fileNotFoundError.errorDescription?.contains("/test/path") == true)

        let invalidTOMLError = AgentConfigError.invalidTOMLFormat("syntax error")
        #expect(invalidTOMLError.errorDescription?.contains("syntax error") == true)

        let missingFieldError = AgentConfigError.missingRequiredField("test_field")
        #expect(missingFieldError.errorDescription?.contains("test_field") == true)

        let invalidConfigError = AgentConfigError.invalidConfiguration("test message")
        #expect(invalidConfigError.errorDescription?.contains("test message") == true)
    }

    // MARK: - Platform-Specific Configuration Tests

    @Test("Platform-specific settings are handled correctly")
    func loadConfigWithPlatformSpecificSettings() throws {
        try withTempDirectory { tempDirectory in
            #if os(macOS)
            // Test that KVM warning appears on macOS
            let tomlContent = """
            control_plane_url = "ws://localhost:8080/agent/ws"
            enable_kvm = true
            """
            #else
            // Test that HVF warning appears on Linux
            let tomlContent = """
            control_plane_url = "ws://localhost:8080/agent/ws"
            enable_hvf = true
            """
            #endif

            let configPath = tempDirectory.appendingPathComponent("platform-specific.toml").path
            try tomlContent.write(toFile: configPath, atomically: true, encoding: .utf8)

            // Should load successfully despite platform-specific warnings
            let config = try AgentConfig.load(from: configPath)
            #expect(config.controlPlaneURL == "ws://localhost:8080/agent/ws")
        }
    }

    // MARK: - Default Path Constants Tests

    @Test("Default config paths are correct")
    func defaultConfigPaths() {
        #if os(macOS)
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        #expect(AgentConfig.defaultConfigPath == "\(home)/Library/Application Support/strato/config.toml")
        #else
        #expect(AgentConfig.defaultConfigPath == "/etc/strato/config.toml")
        #endif
        #expect(AgentConfig.fallbackConfigPath == "./config.toml")
    }
}
