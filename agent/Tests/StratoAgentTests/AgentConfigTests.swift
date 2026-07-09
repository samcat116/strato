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

    @Test("Load OVN chassis bootstrap settings")
    func loadOVNChassisSettings() throws {
        try withTempDirectory { tempDirectory in
            let tomlContent = """
                control_plane_url = "ws://localhost:8080/agent/ws"
                network_mode = "ovn"
                ovn_remote = "tcp:central:6642"
                ovn_encap_type = "geneve"
                ovn_encap_ip = "10.0.0.5"
                ovn_bootstrap_chassis = false
                """

            let configPath = tempDirectory.appendingPathComponent("config.toml").path
            try tomlContent.write(toFile: configPath, atomically: true, encoding: .utf8)

            let config = try AgentConfig.load(from: configPath)

            #expect(config.ovnRemote == "tcp:central:6642")
            #expect(config.ovnEncapType == "geneve")
            #expect(config.ovnEncapIP == "10.0.0.5")
            #expect(config.ovnBootstrapChassis == false)

            let chassis = config.ovnChassisConfig
            #expect(chassis.remote == "tcp:central:6642")
            #expect(chassis.encapIP == "10.0.0.5")
            #expect(!chassis.bootstrapEnabled)
        }
    }

    @Test("Load OVN northbound connection string")
    func loadOVNNorthbound() throws {
        try withTempDirectory { tempDirectory in
            let tomlContent = """
                control_plane_url = "ws://localhost:8080/agent/ws"
                network_mode = "ovn"
                ovn_northbound = "tcp:central:6641"
                """
            let configPath = tempDirectory.appendingPathComponent("config.toml").path
            try tomlContent.write(toFile: configPath, atomically: true, encoding: .utf8)

            let config = try AgentConfig.load(from: configPath)
            #expect(config.ovnNorthbound == "tcp:central:6641")
        }
    }

    @Test("ovn_northbound defaults to nil (legacy local socket)")
    func ovnNorthboundDefaultsNil() throws {
        try withTempDirectory { tempDirectory in
            let tomlContent = """
                control_plane_url = "ws://minimal:8080/ws"
                """
            let configPath = tempDirectory.appendingPathComponent("config.toml").path
            try tomlContent.write(toFile: configPath, atomically: true, encoding: .utf8)

            let config = try AgentConfig.load(from: configPath)
            #expect(config.ovnNorthbound == nil)
        }
    }

    @Test("A malformed ovn_northbound is rejected at load time")
    func ovnNorthboundValidated() throws {
        try withTempDirectory { tempDirectory in
            let tomlContent = """
                control_plane_url = "ws://minimal:8080/ws"
                ovn_northbound = "central:6641"
                """
            let configPath = tempDirectory.appendingPathComponent("config.toml").path
            try tomlContent.write(toFile: configPath, atomically: true, encoding: .utf8)

            #expect(throws: AgentConfigError.self) {
                _ = try AgentConfig.load(from: configPath)
            }
        }
    }

    @Test("Chassis bootstrap defaults to enabled when keys are absent")
    func ovnChassisSettingsDefault() throws {
        try withTempDirectory { tempDirectory in
            let tomlContent = """
                control_plane_url = "ws://minimal:8080/ws"
                """
            let configPath = tempDirectory.appendingPathComponent("config.toml").path
            try tomlContent.write(toFile: configPath, atomically: true, encoding: .utf8)

            let config = try AgentConfig.load(from: configPath)
            #expect(config.ovnBootstrapChassis == nil)
            let chassis = config.ovnChassisConfig
            #expect(chassis.bootstrapEnabled)
            #expect(chassis.encapIP == nil)
            #expect(chassis.remote == nil)
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

    // MARK: - Join State Configuration Tests

    @Test("Parses state_file from the config")
    func parsesStateFile() throws {
        try withTempDirectory { tempDirectory in
            let tomlContent = """
                control_plane_url = "ws://cp:8080/agent/ws"
                state_file = "/custom/agent-state.json"
                """
            let configPath = tempDirectory.appendingPathComponent("state-file.toml").path
            try tomlContent.write(toFile: configPath, atomically: true, encoding: .utf8)

            let config = try AgentConfig.load(from: configPath)
            #expect(config.stateFilePath == "/custom/agent-state.json")
        }
    }

    @Test("state_file is optional")
    func stateFileOptional() throws {
        try withTempDirectory { tempDirectory in
            let tomlContent = """
                control_plane_url = "ws://cp:8080/agent/ws"
                """
            let configPath = tempDirectory.appendingPathComponent("no-state-file.toml").path
            try tomlContent.write(toFile: configPath, atomically: true, encoding: .utf8)

            let config = try AgentConfig.load(from: configPath)
            #expect(config.stateFilePath == nil)
        }
    }

    @Test("writeMinimalConfig produces a loadable config with the given URL")
    func writeMinimalConfigRoundTrip() throws {
        try withTempDirectory { tempDirectory in
            let configPath = tempDirectory.appendingPathComponent("nested/config.toml").path

            try AgentConfig.writeMinimalConfig(
                controlPlaneURL: "wss://cp.example.com/agent/ws",
                to: configPath
            )

            let config = try AgentConfig.load(from: configPath)
            #expect(config.controlPlaneURL == "wss://cp.example.com/agent/ws")
        }
    }
}
