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

    // MARK: - Storage paths

    @Test("Load volume_storage_dir alongside vm_storage_dir")
    func loadVolumeStorageDir() throws {
        try withTempDirectory { tempDirectory in
            let tomlContent = """
                control_plane_url = "ws://localhost:8080/agent/ws"
                vm_storage_dir = "/srv/strato/vms"
                volume_storage_dir = "/srv/strato/volumes"
                """
            let configPath = tempDirectory.appendingPathComponent("config.toml").path
            try tomlContent.write(toFile: configPath, atomically: true, encoding: .utf8)

            let config = try AgentConfig.load(from: configPath)

            #expect(config.vmStoragePath == "/srv/strato/vms")
            #expect(config.volumeStoragePath == "/srv/strato/volumes")
        }
    }

    @Test("volume_storage_dir defaults to nil (platform default path) when absent")
    func volumeStorageDirDefaultNil() throws {
        try withTempDirectory { tempDirectory in
            let configPath = tempDirectory.appendingPathComponent("config.toml").path
            try "control_plane_url = \"ws://x:8080/agent/ws\"".write(
                toFile: configPath, atomically: true, encoding: .utf8)

            let config = try AgentConfig.load(from: configPath)

            #expect(config.volumeStoragePath == nil)
        }
    }

    // MARK: - Image cache settings

    @Test("Load image cache settings")
    func loadImageCacheSettings() throws {
        try withTempDirectory { tempDirectory in
            let tomlContent = """
                control_plane_url = "ws://localhost:8080/agent/ws"
                image_cache_dir = "/mnt/big/strato-images"
                image_cache_max_size_gb = 50
                sandbox_image_cache_dir = "/mnt/big/strato-sandbox-images"
                sandbox_image_cache_max_size_gb = 20
                """
            let configPath = tempDirectory.appendingPathComponent("config.toml").path
            try tomlContent.write(toFile: configPath, atomically: true, encoding: .utf8)

            let config = try AgentConfig.load(from: configPath)

            let expectedImageBytes: Int64 = 50 * 1024 * 1024 * 1024
            let expectedSandboxBytes: Int64 = 20 * 1024 * 1024 * 1024
            #expect(config.imageCacheDir == "/mnt/big/strato-images")
            #expect(config.imageCacheMaxSizeGB == 50)
            #expect(config.imageCacheMaxSizeBytes == expectedImageBytes)
            #expect(config.sandboxImageCacheDir == "/mnt/big/strato-sandbox-images")
            #expect(config.sandboxImageCacheMaxSizeGB == 20)
            #expect(config.sandboxImageCacheMaxSizeBytes == expectedSandboxBytes)
        }
    }

    @Test("Image cache settings default to nil (unbounded, default paths) when absent")
    func imageCacheSettingsDefaultNil() throws {
        try withTempDirectory { tempDirectory in
            let configPath = tempDirectory.appendingPathComponent("config.toml").path
            try "control_plane_url = \"ws://x:8080/agent/ws\"".write(
                toFile: configPath, atomically: true, encoding: .utf8)

            let config = try AgentConfig.load(from: configPath)

            #expect(config.imageCacheDir == nil)
            #expect(config.imageCacheMaxSizeGB == nil)
            #expect(config.imageCacheMaxSizeBytes == nil)
            #expect(config.sandboxImageCacheDir == nil)
            #expect(config.sandboxImageCacheMaxSizeGB == nil)
        }
    }

    @Test("Non-positive cache budgets are rejected")
    func nonPositiveCacheBudgetRejected() throws {
        try withTempDirectory { tempDirectory in
            for key in ["image_cache_max_size_gb", "sandbox_image_cache_max_size_gb"] {
                let tomlContent = """
                    control_plane_url = "ws://localhost:8080/agent/ws"
                    \(key) = 0
                    """
                let configPath = tempDirectory.appendingPathComponent("config.toml").path
                try tomlContent.write(toFile: configPath, atomically: true, encoding: .utf8)

                #expect(throws: AgentConfigError.self) {
                    try AgentConfig.load(from: configPath)
                }
            }
        }
    }

    // MARK: - Sandbox jailer settings (issue #425)

    @Test("Load sandbox jailer settings")
    func loadSandboxJailerSettings() throws {
        try withTempDirectory { tempDirectory in
            let tomlContent = """
                control_plane_url = "ws://localhost:8080/agent/ws"
                sandbox_jailer_mode = "required"
                sandbox_jailer_binary_path = "/opt/fc/jailer"
                sandbox_jailer_chroot_dir = "/srv/jails"
                sandbox_jailer_uid_base = 200000
                """
            let configPath = tempDirectory.appendingPathComponent("config.toml").path
            try tomlContent.write(toFile: configPath, atomically: true, encoding: .utf8)

            let config = try AgentConfig.load(from: configPath)

            #expect(config.sandboxJailerMode == .required)
            #expect(config.sandboxJailerBinaryPath == "/opt/fc/jailer")
            #expect(config.sandboxJailerChrootDir == "/srv/jails")
            #expect(config.sandboxJailerUidBase == 200_000)
        }
    }

    @Test("Sandbox jailer settings default to nil when absent")
    func sandboxJailerSettingsDefaultNil() throws {
        try withTempDirectory { tempDirectory in
            let configPath = tempDirectory.appendingPathComponent("config.toml").path
            try "control_plane_url = \"ws://x:8080/agent/ws\"".write(
                toFile: configPath, atomically: true, encoding: .utf8)

            let config = try AgentConfig.load(from: configPath)

            #expect(config.sandboxJailerMode == nil)
            #expect(config.sandboxJailerBinaryPath == nil)
            #expect(config.sandboxJailerChrootDir == nil)
            #expect(config.sandboxJailerUidBase == nil)
        }
    }

    @Test("A misspelled sandbox_jailer_mode is rejected, never silently weakened to auto")
    func invalidSandboxJailerModeRejected() throws {
        try withTempDirectory { tempDirectory in
            let tomlContent = """
                control_plane_url = "ws://localhost:8080/agent/ws"
                sandbox_jailer_mode = "requierd"
                """
            let configPath = tempDirectory.appendingPathComponent("config.toml").path
            try tomlContent.write(toFile: configPath, atomically: true, encoding: .utf8)

            #expect(throws: AgentConfigError.self) {
                try AgentConfig.load(from: configPath)
            }
        }
    }

    @Test("A uid base without room for the per-sandbox range is rejected")
    func invalidSandboxJailerUidBaseRejected() throws {
        try withTempDirectory { tempDirectory in
            for bad in ["0", "-5", "4294967295"] {
                let tomlContent = """
                    control_plane_url = "ws://localhost:8080/agent/ws"
                    sandbox_jailer_uid_base = \(bad)
                    """
                let configPath = tempDirectory.appendingPathComponent("config.toml").path
                try tomlContent.write(toFile: configPath, atomically: true, encoding: .utf8)

                #expect(throws: AgentConfigError.self) {
                    try AgentConfig.load(from: configPath)
                }
            }
        }
    }

    @Test("Jailer defaults: binary beside firecracker, chroot under VM storage")
    func sandboxJailerDefaults() {
        // The sibling path only wins when it exists on the test host, so pin
        // the fallback shape instead: an absent sibling falls back to the
        // sibling path itself (the well-known locations are also absent here).
        let binary = AgentConfig.defaultSandboxJailerBinaryPath(
            firecrackerBinaryPath: "/nonexistent/bin/firecracker")
        #expect(binary == "/nonexistent/bin/jailer")

        #expect(
            AgentConfig.defaultSandboxJailerChrootDir(vmStoragePath: "/var/lib/strato/vms")
                == "/var/lib/strato/vms/jailer")
        #expect(AgentConfig.defaultSandboxJailerUidBase == 100_000)
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

    @Test("Load [ovn_dynamic_routing] settings")
    func loadOVNDynamicRouting() throws {
        try withTempDirectory { tempDirectory in
            let tomlContent = """
                control_plane_url = "ws://localhost:8080/agent/ws"
                network_mode = "ovn"

                [ovn_dynamic_routing]
                enabled = true
                redistribute = ["nat"]
                vrf_name = "ovnvrf"
                maintain_vrf = false
                routing_protocols = ["BGP", "BFD"]
                """
            let configPath = tempDirectory.appendingPathComponent("config.toml").path
            try tomlContent.write(toFile: configPath, atomically: true, encoding: .utf8)

            let config = try AgentConfig.load(from: configPath)
            let routing = try #require(config.ovnDynamicRouting)
            #expect(routing.enabled)
            #expect(routing.redistribute == ["nat"])
            #expect(routing.vrfName == "ovnvrf")
            #expect(!routing.maintainVRF)
            #expect(routing.routingProtocols == ["BGP", "BFD"])
        }
    }

    @Test("[ovn_dynamic_routing] defaults: absent section is nil; bare section is disabled with defaults")
    func ovnDynamicRoutingDefaults() throws {
        try withTempDirectory { tempDirectory in
            let absentPath = tempDirectory.appendingPathComponent("absent.toml").path
            try "control_plane_url = \"ws://localhost:8080/agent/ws\"".write(
                toFile: absentPath, atomically: true, encoding: .utf8)
            #expect(try AgentConfig.load(from: absentPath).ovnDynamicRouting == nil)

            let barePath = tempDirectory.appendingPathComponent("bare.toml").path
            try """
            control_plane_url = "ws://localhost:8080/agent/ws"

            [ovn_dynamic_routing]
            enabled = true
            """.write(toFile: barePath, atomically: true, encoding: .utf8)
            let routing = try #require(try AgentConfig.load(from: barePath).ovnDynamicRouting)
            #expect(routing.enabled)
            #expect(routing.redistribute == OVNDynamicRoutingConfig.defaultRedistribute)
            #expect(routing.routingProtocols == OVNDynamicRoutingConfig.defaultRoutingProtocols)
            #expect(routing.maintainVRF)
            #expect(routing.vrfName == nil)
        }
    }

    @Test("An unsupported redistribute or protocol value is rejected, never silently dropped")
    func ovnDynamicRoutingRejectsInvalidValues() throws {
        try withTempDirectory { tempDirectory in
            for badLine in [
                "redistribute = [\"connected\", \"nats\"]",
                "routing_protocols = [\"OSPF\"]",
            ] {
                let tomlContent = """
                    control_plane_url = "ws://localhost:8080/agent/ws"

                    [ovn_dynamic_routing]
                    enabled = true
                    \(badLine)
                    """
                let configPath = tempDirectory.appendingPathComponent("config.toml").path
                try tomlContent.write(toFile: configPath, atomically: true, encoding: .utf8)
                #expect(throws: AgentConfigError.self) {
                    _ = try AgentConfig.load(from: configPath)
                }
            }
        }
    }

    @Test("Load [ovn_northbound_tls] with an ssl: endpoint")
    func loadOVNNorthboundTLS() throws {
        try withTempDirectory { tempDirectory in
            let tomlContent = """
                control_plane_url = "ws://localhost:8080/agent/ws"
                network_mode = "ovn"
                ovn_northbound = "ssl:central:6641"

                [ovn_northbound_tls]
                ca_cert = "/etc/strato/pki/cacert.pem"
                client_cert = "/etc/strato/pki/agent-cert.pem"
                client_key = "/etc/strato/pki/agent-privkey.pem"
                server_hostname = "central.site.example"
                """
            let configPath = tempDirectory.appendingPathComponent("config.toml").path
            try tomlContent.write(toFile: configPath, atomically: true, encoding: .utf8)

            let config = try AgentConfig.load(from: configPath)
            let tls = try #require(config.ovnNorthboundTLS)
            #expect(tls.caCertPath == "/etc/strato/pki/cacert.pem")
            #expect(tls.clientCertPath == "/etc/strato/pki/agent-cert.pem")
            #expect(tls.clientKeyPath == "/etc/strato/pki/agent-privkey.pem")
            #expect(tls.serverHostname == "central.site.example")
            // Verification is on unless explicitly disabled.
            #expect(tls.verifyServerCertificate)
            #expect(
                tls.configuredFilePaths == [
                    "/etc/strato/pki/cacert.pem",
                    "/etc/strato/pki/agent-cert.pem",
                    "/etc/strato/pki/agent-privkey.pem",
                ])
        }
    }

    @Test("[ovn_northbound_tls] without an ssl: endpoint is rejected — TLS settings must never be silently ignored")
    func ovnNorthboundTLSRequiresSSLEndpoint() throws {
        try withTempDirectory { tempDirectory in
            for endpointLine in ["ovn_northbound = \"tcp:central:6641\"", ""] {
                let tomlContent = """
                    control_plane_url = "ws://localhost:8080/agent/ws"
                    \(endpointLine)

                    [ovn_northbound_tls]
                    ca_cert = "/etc/strato/pki/cacert.pem"
                    """
                let configPath = tempDirectory.appendingPathComponent("config.toml").path
                try tomlContent.write(toFile: configPath, atomically: true, encoding: .utf8)

                #expect(throws: AgentConfigError.self) {
                    _ = try AgentConfig.load(from: configPath)
                }
            }
        }
    }

    @Test("A client certificate without its key (or vice versa) is rejected")
    func ovnNorthboundTLSClientPairValidated() throws {
        try withTempDirectory { tempDirectory in
            for lonelyKey in ["client_cert", "client_key"] {
                let tomlContent = """
                    control_plane_url = "ws://localhost:8080/agent/ws"
                    ovn_northbound = "ssl:central:6641"

                    [ovn_northbound_tls]
                    \(lonelyKey) = "/etc/strato/pki/half-a-pair.pem"
                    """
                let configPath = tempDirectory.appendingPathComponent("config.toml").path
                try tomlContent.write(toFile: configPath, atomically: true, encoding: .utf8)

                #expect(throws: AgentConfigError.self) {
                    _ = try AgentConfig.load(from: configPath)
                }
            }
        }
    }

    @Test("ovn_northbound_tls defaults to nil, and an ssl: endpoint works without it (system trust roots)")
    func ovnNorthboundTLSDefaultsNil() throws {
        try withTempDirectory { tempDirectory in
            let tomlContent = """
                control_plane_url = "ws://minimal:8080/ws"
                ovn_northbound = "ssl:central:6641"
                """
            let configPath = tempDirectory.appendingPathComponent("config.toml").path
            try tomlContent.write(toFile: configPath, atomically: true, encoding: .utf8)

            let config = try AgentConfig.load(from: configPath)
            #expect(config.ovnNorthbound == "ssl:central:6641")
            #expect(config.ovnNorthboundTLS == nil)
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
}
