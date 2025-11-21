import XCTest
import Foundation
import Logging
@testable import StratoAgentCore

final class AgentConfigTests: XCTestCase {

    var tempDirectory: URL!

    override func setUp() {
        super.setUp()
        // Create a temporary directory for test files
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-config-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        // Clean up temporary directory
        try? FileManager.default.removeItem(at: tempDirectory)
        super.tearDown()
    }

    // MARK: - Initialization Tests

    func testAgentConfigInitialization() {
        let config = AgentConfig(
            controlPlaneURL: "ws://localhost:8080/agent/ws",
            qemuSocketDir: "/var/run/qemu",
            logLevel: "debug",
            networkMode: .ovn,
            enableHVF: false,
            enableKVM: true
        )

        XCTAssertEqual(config.controlPlaneURL, "ws://localhost:8080/agent/ws")
        XCTAssertEqual(config.qemuSocketDir, "/var/run/qemu")
        XCTAssertEqual(config.logLevel, "debug")
        XCTAssertEqual(config.networkMode, .ovn)
        XCTAssertEqual(config.enableHVF, false)
        XCTAssertEqual(config.enableKVM, true)
    }

    func testAgentConfigInitializationWithNilValues() {
        let config = AgentConfig(
            controlPlaneURL: "ws://test:8080/ws"
        )

        XCTAssertEqual(config.controlPlaneURL, "ws://test:8080/ws")
        XCTAssertNil(config.qemuSocketDir)
        XCTAssertNil(config.logLevel)
        XCTAssertNil(config.networkMode)
        XCTAssertNil(config.enableHVF)
        XCTAssertNil(config.enableKVM)
    }

    // MARK: - TOML Loading Tests

    func testLoadValidConfig() throws {
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

        XCTAssertEqual(config.controlPlaneURL, "ws://localhost:8080/agent/ws")
        XCTAssertEqual(config.qemuSocketDir, "/var/run/qemu")
        XCTAssertEqual(config.logLevel, "info")
        XCTAssertEqual(config.networkMode, .ovn)
        XCTAssertEqual(config.enableHVF, false)
        XCTAssertEqual(config.enableKVM, true)
    }

    func testLoadMinimalConfig() throws {
        let tomlContent = """
        control_plane_url = "ws://minimal:8080/ws"
        """

        let configPath = tempDirectory.appendingPathComponent("minimal.toml").path
        try tomlContent.write(toFile: configPath, atomically: true, encoding: .utf8)

        let config = try AgentConfig.load(from: configPath)

        XCTAssertEqual(config.controlPlaneURL, "ws://minimal:8080/ws")
        XCTAssertNil(config.qemuSocketDir)
        XCTAssertNil(config.logLevel)
        XCTAssertNil(config.networkMode)
    }

    func testLoadConfigWithUserNetworkMode() throws {
        let tomlContent = """
        control_plane_url = "ws://localhost:8080/agent/ws"
        network_mode = "user"
        """

        let configPath = tempDirectory.appendingPathComponent("user-mode.toml").path
        try tomlContent.write(toFile: configPath, atomically: true, encoding: .utf8)

        let config = try AgentConfig.load(from: configPath)

        XCTAssertEqual(config.networkMode, .user)
    }

    // MARK: - Error Handling Tests

    func testLoadConfigFileNotFound() {
        let nonExistentPath = "/tmp/does-not-exist-\(UUID().uuidString).toml"

        XCTAssertThrowsError(try AgentConfig.load(from: nonExistentPath)) { error in
            guard case AgentConfigError.configFileNotFound = error else {
                XCTFail("Expected configFileNotFound error, got \(error)")
                return
            }
        }
    }

    func testLoadConfigMissingRequiredField() throws {
        let tomlContent = """
        qemu_socket_dir = "/var/run/qemu"
        log_level = "debug"
        """

        let configPath = tempDirectory.appendingPathComponent("missing-url.toml").path
        try tomlContent.write(toFile: configPath, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try AgentConfig.load(from: configPath)) { error in
            guard case AgentConfigError.missingRequiredField(let field) = error else {
                XCTFail("Expected missingRequiredField error, got \(error)")
                return
            }
            XCTAssertEqual(field, "control_plane_url")
        }
    }

    func testLoadConfigInvalidNetworkMode() throws {
        let tomlContent = """
        control_plane_url = "ws://localhost:8080/agent/ws"
        network_mode = "invalid_mode"
        """

        let configPath = tempDirectory.appendingPathComponent("invalid-mode.toml").path
        try tomlContent.write(toFile: configPath, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try AgentConfig.load(from: configPath)) { error in
            guard case AgentConfigError.invalidConfiguration = error else {
                XCTFail("Expected invalidConfiguration error, got \(error)")
                return
            }
        }
    }

    func testLoadConfigInvalidTOML() throws {
        let invalidToml = """
        control_plane_url = ws://localhost:8080/agent/ws
        [this is not valid toml
        """

        let configPath = tempDirectory.appendingPathComponent("invalid.toml").path
        try invalidToml.write(toFile: configPath, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try AgentConfig.load(from: configPath))
    }

    // MARK: - Default Config Tests

    func testLoadDefaultConfig() {
        let config = AgentConfig.loadDefaultConfig()

        XCTAssertNotNil(config.controlPlaneURL)
        XCTAssertEqual(config.controlPlaneURL, "ws://localhost:8080/agent/ws")

        #if os(Linux)
        XCTAssertEqual(config.networkMode, .ovn)
        XCTAssertEqual(config.enableKVM, true)
        XCTAssertEqual(config.enableHVF, false)
        #else
        XCTAssertEqual(config.networkMode, .user)
        XCTAssertEqual(config.enableHVF, true)
        XCTAssertEqual(config.enableKVM, false)
        #endif
    }

    // MARK: - Codable Tests

    func testAgentConfigEncodingDecoding() throws {
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

        XCTAssertEqual(decodedConfig.controlPlaneURL, originalConfig.controlPlaneURL)
        XCTAssertEqual(decodedConfig.qemuSocketDir, originalConfig.qemuSocketDir)
        XCTAssertEqual(decodedConfig.logLevel, originalConfig.logLevel)
        XCTAssertEqual(decodedConfig.networkMode, originalConfig.networkMode)
        XCTAssertEqual(decodedConfig.enableHVF, originalConfig.enableHVF)
        XCTAssertEqual(decodedConfig.enableKVM, originalConfig.enableKVM)
    }

    func testNetworkModeRawValues() {
        XCTAssertEqual(NetworkMode.ovn.rawValue, "ovn")
        XCTAssertEqual(NetworkMode.user.rawValue, "user")
    }

    func testNetworkModeFromRawValue() {
        XCTAssertEqual(NetworkMode(rawValue: "ovn"), .ovn)
        XCTAssertEqual(NetworkMode(rawValue: "user"), .user)
        XCTAssertNil(NetworkMode(rawValue: "invalid"))
    }

    // MARK: - Error Description Tests

    func testAgentConfigErrorDescriptions() {
        let fileNotFoundError = AgentConfigError.configFileNotFound("/test/path")
        XCTAssertTrue(fileNotFoundError.errorDescription?.contains("/test/path") ?? false)

        let invalidTOMLError = AgentConfigError.invalidTOMLFormat("syntax error")
        XCTAssertTrue(invalidTOMLError.errorDescription?.contains("syntax error") ?? false)

        let missingFieldError = AgentConfigError.missingRequiredField("test_field")
        XCTAssertTrue(missingFieldError.errorDescription?.contains("test_field") ?? false)

        let invalidConfigError = AgentConfigError.invalidConfiguration("test message")
        XCTAssertTrue(invalidConfigError.errorDescription?.contains("test message") ?? false)
    }

    // MARK: - Platform-Specific Configuration Tests

    func testLoadConfigWithPlatformSpecificSettings() throws {
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
        XCTAssertNotNil(config)
    }

    // MARK: - Default Path Constants Tests

    func testDefaultConfigPaths() {
        XCTAssertEqual(AgentConfig.defaultConfigPath, "/etc/strato/config.toml")
        XCTAssertEqual(AgentConfig.fallbackConfigPath, "./config.toml")
    }
}
