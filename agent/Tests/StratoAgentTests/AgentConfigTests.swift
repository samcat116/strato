import Testing
import Foundation
import Logging
@testable import StratoAgentCore

@Suite("AgentConfig Tests")
struct AgentConfigTests {
    private static let invalidLogLevelMessage =
        "Invalid configuration: log level must be one of trace, debug, info, notice, "
        + "warning, error, critical, got 'verbose'"

    // Helper to create and clean up temporary directories
    func withTempDirectory<T>(_ body: (URL) async throws -> T) async rethrows -> T {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-config-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)

        defer {
            try? FileManager.default.removeItem(at: tempDirectory)
        }

        return try await body(tempDirectory)
    }

    private func loadConfig(from path: String) async throws -> AgentConfig {
        try await AgentConfig.load(from: path, environmentVariables: [:])
    }

    private func loadDefaultConfig(searchPaths: [String]) async throws -> AgentConfig {
        try await AgentConfig.loadDefaultConfig(
            searchPaths: searchPaths,
            environmentVariables: [:])
    }

    // MARK: - Storage paths

    @Test("Load volume_storage_dir alongside vm_storage_dir")
    func loadVolumeStorageDir() async throws {
        try await withTempDirectory { tempDirectory in
            let tomlContent = """
                control_plane_url = "ws://localhost:8080/agent/ws"
                vm_storage_dir = "/srv/strato/vms"
                volume_storage_dir = "/srv/strato/volumes"
                """
            let configPath = tempDirectory.appendingPathComponent("config.toml").path
            try tomlContent.write(toFile: configPath, atomically: true, encoding: .utf8)

            let config = try await loadConfig(from: configPath)

            #expect(config.vmStoragePath == "/srv/strato/vms")
            #expect(config.volumeStoragePath == "/srv/strato/volumes")
        }
    }

    @Test("volume_storage_dir defaults to nil (platform default path) when absent")
    func volumeStorageDirDefaultNil() async throws {
        try await withTempDirectory { tempDirectory in
            let configPath = tempDirectory.appendingPathComponent("config.toml").path
            try "control_plane_url = \"ws://x:8080/agent/ws\"".write(
                toFile: configPath, atomically: true, encoding: .utf8)

            let config = try await loadConfig(from: configPath)

            #expect(config.volumeStoragePath == nil)
        }
    }

    // MARK: - Warm start (issue #426)

    @Test("Load warm-start settings")
    func loadWarmStartSettings() async throws {
        try await withTempDirectory { tempDirectory in
            let tomlContent = """
                control_plane_url = "ws://localhost:8080/agent/ws"
                sandbox_warm_start = false
                sandbox_warm_cache_max_size_gb = 40
                """
            let configPath = tempDirectory.appendingPathComponent("config.toml").path
            try tomlContent.write(toFile: configPath, atomically: true, encoding: .utf8)

            let config = try await loadConfig(from: configPath)

            #expect(config.sandboxWarmStart == false, "the documented kill switch must actually load")
            #expect(config.sandboxWarmCacheMaxSizeGB == 40)
            let budgetBytes: Int64? = config.sandboxWarmCacheMaxSizeBytes
            #expect(budgetBytes == Int64(40) * 1024 * 1024 * 1024)
        }
    }

    @Test("Warm-start settings default to nil (enabled, default budget) when absent")
    func warmStartSettingsDefaultNil() async throws {
        try await withTempDirectory { tempDirectory in
            let configPath = tempDirectory.appendingPathComponent("config.toml").path
            try "control_plane_url = \"ws://x:8080/agent/ws\"".write(
                toFile: configPath, atomically: true, encoding: .utf8)

            let config = try await loadConfig(from: configPath)

            #expect(config.sandboxWarmStart == nil)
            #expect(config.sandboxWarmCacheMaxSizeGB == nil)
        }
    }

    @Test("A non-positive warm cache budget is rejected")
    func nonPositiveWarmCacheBudgetRejected() async throws {
        try await withTempDirectory { tempDirectory in
            let tomlContent = """
                control_plane_url = "ws://localhost:8080/agent/ws"
                sandbox_warm_cache_max_size_gb = 0
                """
            let configPath = tempDirectory.appendingPathComponent("config.toml").path
            try tomlContent.write(toFile: configPath, atomically: true, encoding: .utf8)

            await #expect(throws: AgentConfigError.self) {
                try await loadConfig(from: configPath)
            }
        }
    }

    // MARK: - Pinned control-plane SPIFFE ID (issue #552)

    @Test("control_plane_spiffe_id defaults to spiffe://<trust_domain>/control-plane")
    func controlPlaneSPIFFEIDDefault() async throws {
        try await withTempDirectory { tempDirectory in
            let tomlContent = """
                control_plane_url = "wss://cp.example:8443/agent/ws"
                [spiffe]
                enabled = true
                trust_domain = "prod.example.com"
                """
            let configPath = tempDirectory.appendingPathComponent("config.toml").path
            try tomlContent.write(toFile: configPath, atomically: true, encoding: .utf8)

            let config = try await loadConfig(from: configPath)

            let spiffe = try #require(config.spiffe)
            #expect(spiffe.controlPlaneSPIFFEID == nil)
            #expect(spiffe.resolvedControlPlaneSPIFFEID == "spiffe://prod.example.com/control-plane")
        }
    }

    @Test("control_plane_spiffe_id defaults from the default trust domain when unset")
    func controlPlaneSPIFFEIDDefaultTrustDomain() {
        let spiffe = SPIFFEConfig(enabled: true)
        #expect(spiffe.resolvedControlPlaneSPIFFEID == "spiffe://strato.local/control-plane")
    }

    @Test("An explicit control_plane_spiffe_id overrides the derived default")
    func controlPlaneSPIFFEIDOverride() async throws {
        try await withTempDirectory { tempDirectory in
            let tomlContent = """
                control_plane_url = "wss://cp.example:8443/agent/ws"
                [spiffe]
                enabled = true
                trust_domain = "prod.example.com"
                control_plane_spiffe_id = "spiffe://prod.example.com/cp/primary"
                """
            let configPath = tempDirectory.appendingPathComponent("config.toml").path
            try tomlContent.write(toFile: configPath, atomically: true, encoding: .utf8)

            let config = try await loadConfig(from: configPath)

            let spiffe = try #require(config.spiffe)
            #expect(spiffe.resolvedControlPlaneSPIFFEID == "spiffe://prod.example.com/cp/primary")
        }
    }

    @Test(
        "A malformed control_plane_spiffe_id is rejected at load",
        arguments: [
            "control-plane",  // no scheme
            "https://prod.example.com/control-plane",  // wrong scheme
            "spiffe://",  // no trust domain
            "spiffe:///control-plane",  // empty trust domain
            "spiffe://prod.example.com",  // no workload path
            "spiffe://prod.example.com/",  // empty workload path
        ])
    func malformedControlPlaneSPIFFEIDRejected(id: String) async throws {
        try await withTempDirectory { tempDirectory in
            let tomlContent = """
                control_plane_url = "wss://cp.example:8443/agent/ws"
                [spiffe]
                enabled = true
                control_plane_spiffe_id = "\(id)"
                """
            let configPath = tempDirectory.appendingPathComponent("config.toml").path
            try tomlContent.write(toFile: configPath, atomically: true, encoding: .utf8)

            await #expect(throws: AgentConfigError.self) {
                try await loadConfig(from: configPath)
            }
        }
    }

    @Test("An empty trust_domain is rejected rather than deriving a malformed pinned ID")
    func emptyTrustDomainRejected() async throws {
        // Without an explicit control_plane_spiffe_id the pinned identity is
        // derived, so validating only the override would let this through and
        // surface as every handshake failing with a pin mismatch.
        try await withTempDirectory { tempDirectory in
            let tomlContent = """
                control_plane_url = "wss://cp.example:8443/agent/ws"
                [spiffe]
                enabled = true
                trust_domain = ""
                """
            let configPath = tempDirectory.appendingPathComponent("config.toml").path
            try tomlContent.write(toFile: configPath, atomically: true, encoding: .utf8)

            await #expect(throws: AgentConfigError.self) {
                try await loadConfig(from: configPath)
            }
        }
    }

    @Test(
        "isWellFormedSPIFFEID accepts full SPIFFE IDs",
        arguments: [
            "spiffe://strato.local/control-plane",
            "spiffe://prod.example.com/cp/primary",
            "spiffe://td/a",
        ])
    func wellFormedSPIFFEIDAccepted(id: String) {
        #expect(SPIFFEConfig.isWellFormedSPIFFEID(id))
    }

    // MARK: - Image cache settings

    @Test("Load image cache settings")
    func loadImageCacheSettings() async throws {
        try await withTempDirectory { tempDirectory in
            let tomlContent = """
                control_plane_url = "ws://localhost:8080/agent/ws"
                image_cache_dir = "/mnt/big/strato-images"
                image_cache_max_size_gb = 50
                sandbox_image_cache_dir = "/mnt/big/strato-sandbox-images"
                sandbox_image_cache_max_size_gb = 20
                """
            let configPath = tempDirectory.appendingPathComponent("config.toml").path
            try tomlContent.write(toFile: configPath, atomically: true, encoding: .utf8)

            let config = try await loadConfig(from: configPath)

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
    func imageCacheSettingsDefaultNil() async throws {
        try await withTempDirectory { tempDirectory in
            let configPath = tempDirectory.appendingPathComponent("config.toml").path
            try "control_plane_url = \"ws://x:8080/agent/ws\"".write(
                toFile: configPath, atomically: true, encoding: .utf8)

            let config = try await loadConfig(from: configPath)

            #expect(config.imageCacheDir == nil)
            #expect(config.imageCacheMaxSizeGB == nil)
            #expect(config.imageCacheMaxSizeBytes == nil)
            #expect(config.sandboxImageCacheDir == nil)
            #expect(config.sandboxImageCacheMaxSizeGB == nil)
        }
    }

    @Test("Non-positive cache budgets are rejected")
    func nonPositiveCacheBudgetRejected() async throws {
        try await withTempDirectory { tempDirectory in
            for key in ["image_cache_max_size_gb", "sandbox_image_cache_max_size_gb"] {
                let tomlContent = """
                    control_plane_url = "ws://localhost:8080/agent/ws"
                    \(key) = 0
                    """
                let configPath = tempDirectory.appendingPathComponent("config.toml").path
                try tomlContent.write(toFile: configPath, atomically: true, encoding: .utf8)

                await #expect(throws: AgentConfigError.self) {
                    try await loadConfig(from: configPath)
                }
            }
        }
    }

    // MARK: - Sandbox jailer settings (issue #425)

    @Test("QEMU memory overhead defaults to 512 MiB and loads valid bounds")
    func qemuMemoryOverhead() async throws {
        try await withTempDirectory { tempDirectory in
            let configPath = tempDirectory.appendingPathComponent("config.toml").path
            try "control_plane_url = \"ws://x:8080/agent/ws\"".write(
                toFile: configPath, atomically: true, encoding: .utf8)
            var config = try await loadConfig(from: configPath)
            #expect(config.qemuMemoryOverheadMB == nil)
            #expect(config.qemuMemoryOverheadBytes == 512 * 1024 * 1024)

            for value in [128, 4096] {
                try """
                control_plane_url = "ws://x:8080/agent/ws"
                qemu_memory_overhead_mb = \(value)
                """.write(toFile: configPath, atomically: true, encoding: .utf8)
                config = try await loadConfig(from: configPath)
                #expect(config.qemuMemoryOverheadMB == value)
            }
        }
    }

    @Test("QEMU memory overhead rejects values outside 128 through 4096 MiB")
    func invalidQEMUMemoryOverhead() async throws {
        try await withTempDirectory { tempDirectory in
            let configPath = tempDirectory.appendingPathComponent("config.toml").path
            for value in [127, 4097] {
                try """
                control_plane_url = "ws://x:8080/agent/ws"
                qemu_memory_overhead_mb = \(value)
                """.write(toFile: configPath, atomically: true, encoding: .utf8)
                await #expect(throws: AgentConfigError.self) {
                    try await loadConfig(from: configPath)
                }
            }
        }
    }

    @Test("Load sandbox jailer settings")
    func loadSandboxJailerSettings() async throws {
        try await withTempDirectory { tempDirectory in
            let tomlContent = """
                control_plane_url = "ws://localhost:8080/agent/ws"
                sandbox_jailer_mode = "required"
                sandbox_jailer_binary_path = "/opt/fc/jailer"
                sandbox_jailer_chroot_dir = "/srv/jails"
                sandbox_jailer_uid_base = 200000
                """
            let configPath = tempDirectory.appendingPathComponent("config.toml").path
            try tomlContent.write(toFile: configPath, atomically: true, encoding: .utf8)

            let config = try await loadConfig(from: configPath)

            #expect(config.sandboxJailerMode == .required)
            #expect(config.sandboxJailerBinaryPath == "/opt/fc/jailer")
            #expect(config.sandboxJailerChrootDir == "/srv/jails")
            #expect(config.sandboxJailerUidBase == 200_000)
        }
    }

    @Test("Sandbox jailer settings default to nil when absent")
    func sandboxJailerSettingsDefaultNil() async throws {
        try await withTempDirectory { tempDirectory in
            let configPath = tempDirectory.appendingPathComponent("config.toml").path
            try "control_plane_url = \"ws://x:8080/agent/ws\"".write(
                toFile: configPath, atomically: true, encoding: .utf8)

            let config = try await loadConfig(from: configPath)

            #expect(config.sandboxJailerMode == nil)
            #expect(config.sandboxJailerBinaryPath == nil)
            #expect(config.sandboxJailerChrootDir == nil)
            #expect(config.sandboxJailerUidBase == nil)
        }
    }

    @Test(
        "Retired settings fail as unknown",
        arguments: [
            ("qemu_driver", "\"process\""),
            ("qemu_binary_path", "\"/usr/bin/qemu-system-x86_64\""),
            ("swtpm_binary_path", "\"/usr/bin/swtpm\""),
            ("qemu_socket_dir", "\"/run/strato/qemu\""),
            ("desired_state_pull", "true"),
        ])
    func retiredSettingsRejected(key: String, value: String) async throws {
        try await withTempDirectory { tempDirectory in
            let configPath = tempDirectory.appendingPathComponent("config.toml").path
            try """
            control_plane_url = "ws://localhost:8080/agent/ws"
            \(key) = \(value)
            """.write(toFile: configPath, atomically: true, encoding: .utf8)

            await #expect {
                try await loadConfig(from: configPath)
            } throws: { error in
                error.localizedDescription == "Invalid configuration: unknown setting '\(key)'"
            }
        }
    }

    @Test(
        "Unknown top-level and nested settings fail clearly",
        arguments: [
            ("log_levle", "\"debug\""),
            ("spiffe.trust_domian", "\"strato.local\""),
        ])
    func unknownSettingsRejected(key: String, value: String) async throws {
        try await withTempDirectory { tempDirectory in
            let configPath = tempDirectory.appendingPathComponent("config.toml").path
            try """
            control_plane_url = "ws://localhost:8080/agent/ws"
            \(key) = \(value)
            """.write(toFile: configPath, atomically: true, encoding: .utf8)

            await #expect {
                try await loadConfig(from: configPath)
            } throws: { error in
                error.localizedDescription == "Invalid configuration: unknown setting '\(key)'"
            }
        }
    }

    @Test("Unknown sections fail clearly even when empty")
    func unknownSectionRejected() async throws {
        try await withTempDirectory { tempDirectory in
            let configPath = tempDirectory.appendingPathComponent("config.toml").path
            try """
            control_plane_url = "ws://localhost:8080/agent/ws"
            [obsolete]
            """.write(toFile: configPath, atomically: true, encoding: .utf8)

            await #expect {
                try await loadConfig(from: configPath)
            } throws: { error in
                error.localizedDescription == "Invalid configuration: unknown section '[obsolete]'"
            }
        }
    }

    @Test("A misspelled sandbox_jailer_mode is rejected, never silently weakened to auto")
    func invalidSandboxJailerModeRejected() async throws {
        try await withTempDirectory { tempDirectory in
            let tomlContent = """
                control_plane_url = "ws://localhost:8080/agent/ws"
                sandbox_jailer_mode = "requierd"
                """
            let configPath = tempDirectory.appendingPathComponent("config.toml").path
            try tomlContent.write(toFile: configPath, atomically: true, encoding: .utf8)

            await #expect(throws: AgentConfigError.self) {
                try await loadConfig(from: configPath)
            }
        }
    }

    @Test("A uid base without room for the per-sandbox range is rejected")
    func invalidSandboxJailerUidBaseRejected() async throws {
        try await withTempDirectory { tempDirectory in
            for bad in ["0", "-5", "65535", "4294901760", "4294967295"] {
                let tomlContent = """
                    control_plane_url = "ws://localhost:8080/agent/ws"
                    sandbox_jailer_uid_base = \(bad)
                    """
                let configPath = tempDirectory.appendingPathComponent("config.toml").path
                try tomlContent.write(toFile: configPath, atomically: true, encoding: .utf8)

                await #expect(throws: AgentConfigError.self) {
                    try await loadConfig(from: configPath)
                }
            }
        }
    }

    @Test("The jailer uid base accepts the configured floor and highest non-wrapping range")
    func sandboxJailerUidBaseBoundariesAccepted() async throws {
        try await withTempDirectory { tempDirectory in
            for accepted in ["65536", "4294901759"] {
                let tomlContent = """
                    control_plane_url = "ws://localhost:8080/agent/ws"
                    sandbox_jailer_uid_base = \(accepted)
                    """
                let configPath = tempDirectory.appendingPathComponent("config.toml").path
                try tomlContent.write(toFile: configPath, atomically: true, encoding: .utf8)

                let config = try await loadConfig(from: configPath)
                #expect(config.sandboxJailerUidBase == UInt32(accepted))
            }
        }
    }

    @Test("Jailer defaults: binary beside firecracker, chroot under VM storage")
    func sandboxJailerDefaults() async throws {
        // Probe a fixture rather than the host's installs so the result does
        // not depend on whether a real jailer is present on the test machine.
        try await withTempDirectory { tempDirectory in
            let sibling = tempDirectory.appendingPathComponent("bin")
            let wellKnown = tempDirectory.appendingPathComponent("well-known")
            try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: wellKnown, withIntermediateDirectories: true)
            let wellKnownJailer = wellKnown.appendingPathComponent("jailer").path
            try "".write(toFile: wellKnownJailer, atomically: true, encoding: .utf8)

            // Nothing beside firecracker: fall through to the well-known list.
            #expect(
                AgentConfig.defaultSandboxJailerBinaryPath(
                    firecrackerBinaryPath: sibling.appendingPathComponent("firecracker").path,
                    wellKnownPaths: [wellKnownJailer]) == wellKnownJailer)

            // A jailer beside firecracker wins over the well-known locations.
            let siblingJailer = sibling.appendingPathComponent("jailer").path
            try "".write(toFile: siblingJailer, atomically: true, encoding: .utf8)
            #expect(
                AgentConfig.defaultSandboxJailerBinaryPath(
                    firecrackerBinaryPath: sibling.appendingPathComponent("firecracker").path,
                    wellKnownPaths: [wellKnownJailer]) == siblingJailer)
        }

        // No candidate exists: fall back to the sibling path itself.
        #expect(
            AgentConfig.defaultSandboxJailerBinaryPath(
                firecrackerBinaryPath: "/nonexistent/bin/firecracker",
                wellKnownPaths: []) == "/nonexistent/bin/jailer")

        // The fixtures above inject their own candidates, so pin the real
        // probe list too — otherwise emptying or reordering it stays green.
        #expect(AgentConfig.wellKnownSandboxJailerPaths == ["/usr/local/bin/jailer", "/usr/bin/jailer"])

        #expect(
            AgentConfig.defaultSandboxJailerChrootDir(vmStoragePath: "/var/lib/strato/vms")
                == "/var/lib/strato/vms/jailer")
        #expect(AgentConfig.minimumSandboxJailerUidBase == 65_536)
        #expect(AgentConfig.legacySandboxJailerUidBase == 100_000)
        #expect(AgentConfig.defaultSandboxJailerUidBase == 0x7000_0000)
    }

    // MARK: - TOML Loading Tests

    @Test("The checked-in example is a valid agent configuration")
    func loadCheckedInExample() async throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let config = try await loadConfig(
            from: repositoryRoot.appendingPathComponent("config.toml.example").path)

        #expect(config.controlPlaneURL == "wss://localhost:8080/agent/ws")
    }

    @Test("Load valid TOML configuration")
    func loadValidConfig() async throws {
        try await withTempDirectory { tempDirectory in
            let tomlContent = """
                control_plane_url = "ws://localhost:8080/agent/ws"
                log_level = "info"
                network_mode = "ovn"
                enable_hvf = false
                enable_kvm = true
                """

            let configPath = tempDirectory.appendingPathComponent("config.toml").path
            try tomlContent.write(toFile: configPath, atomically: true, encoding: .utf8)

            let config = try await loadConfig(from: configPath)

            #expect(config.controlPlaneURL == "ws://localhost:8080/agent/ws")
            #expect(config.logLevel == .info)
            #expect(config.networkMode == .ovn)
            #expect(config.enableHVF == false)
            #expect(config.enableKVM == true)
        }
    }

    @Test(
        "TOML accepts every representative log threshold",
        arguments: [AgentLogLevel.trace, .info, .warning])
    func loadSupportedTOMLLogLevel(_ level: AgentLogLevel) async throws {
        try await withTempDirectory { tempDirectory in
            let configPath = tempDirectory.appendingPathComponent("config.toml").path
            try """
            control_plane_url = "ws://localhost:8080/agent/ws"
            log_level = "\(level.rawValue)"
            """.write(toFile: configPath, atomically: true, encoding: .utf8)

            let config = try await loadConfig(from: configPath)

            #expect(config.logLevel == level)
        }
    }

    @Test("TOML rejects an unsupported log threshold")
    func rejectInvalidTOMLLogLevel() async throws {
        try await withTempDirectory { tempDirectory in
            let configPath = tempDirectory.appendingPathComponent("config.toml").path
            try """
            control_plane_url = "ws://localhost:8080/agent/ws"
            log_level = "verbose"
            """.write(toFile: configPath, atomically: true, encoding: .utf8)

            do {
                _ = try await loadConfig(from: configPath)
                Issue.record("Expected unsupported TOML log level to fail")
            } catch let error as AgentConfigError {
                #expect(error.localizedDescription == Self.invalidLogLevelMessage)
            } catch {
                Issue.record("Expected AgentConfigError, got \(error)")
            }
        }
    }

    @Test("Load OVN chassis bootstrap settings")
    func loadOVNChassisSettings() async throws {
        try await withTempDirectory { tempDirectory in
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

            let config = try await loadConfig(from: configPath)

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
    func loadOVNNorthbound() async throws {
        try await withTempDirectory { tempDirectory in
            let tomlContent = """
                control_plane_url = "ws://localhost:8080/agent/ws"
                network_mode = "ovn"
                ovn_northbound = "tcp:central:6641"
                """
            let configPath = tempDirectory.appendingPathComponent("config.toml").path
            try tomlContent.write(toFile: configPath, atomically: true, encoding: .utf8)

            let config = try await loadConfig(from: configPath)
            #expect(config.ovnNorthbound == "tcp:central:6641")
        }
    }

    @Test("Load [ovn_dynamic_routing] settings")
    func loadOVNDynamicRouting() async throws {
        try await withTempDirectory { tempDirectory in
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

            let config = try await loadConfig(from: configPath)
            let routing = try #require(config.ovnDynamicRouting)
            #expect(routing.enabled)
            #expect(routing.redistribute == ["nat"])
            #expect(routing.vrfName == "ovnvrf")
            #expect(!routing.maintainVRF)
            #expect(routing.routingProtocols == ["BGP", "BFD"])
        }
    }

    @Test("[ovn_dynamic_routing] defaults: absent section is nil; enabled-only uses field defaults")
    func ovnDynamicRoutingDefaults() async throws {
        try await withTempDirectory { tempDirectory in
            let absentPath = tempDirectory.appendingPathComponent("absent.toml").path
            try "control_plane_url = \"ws://localhost:8080/agent/ws\"".write(
                toFile: absentPath, atomically: true, encoding: .utf8)
            #expect(try await loadConfig(from: absentPath).ovnDynamicRouting == nil)

            let barePath = tempDirectory.appendingPathComponent("bare.toml").path
            try """
            control_plane_url = "ws://localhost:8080/agent/ws"

            [ovn_dynamic_routing]
            enabled = true
            """.write(toFile: barePath, atomically: true, encoding: .utf8)
            let routing = try #require(try await loadConfig(from: barePath).ovnDynamicRouting)
            #expect(routing.enabled)
            #expect(routing.redistribute == OVNDynamicRoutingConfig.defaultRedistribute)
            #expect(routing.routingProtocols == OVNDynamicRoutingConfig.defaultRoutingProtocols)
            #expect(routing.maintainVRF)
            #expect(routing.vrfName == nil)
        }
    }

    @Test("An unsupported redistribute or protocol value is rejected, never silently dropped")
    func ovnDynamicRoutingRejectsInvalidValues() async throws {
        try await withTempDirectory { tempDirectory in
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
                await #expect(throws: AgentConfigError.self) {
                    _ = try await loadConfig(from: configPath)
                }
            }
        }
    }

    @Test("Load [ovn_northbound_tls] with an ssl: endpoint")
    func loadOVNNorthboundTLS() async throws {
        try await withTempDirectory { tempDirectory in
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

            let config = try await loadConfig(from: configPath)
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
    func ovnNorthboundTLSRequiresSSLEndpoint() async throws {
        try await withTempDirectory { tempDirectory in
            for endpointLine in ["ovn_northbound = \"tcp:central:6641\"", ""] {
                let tomlContent = """
                    control_plane_url = "ws://localhost:8080/agent/ws"
                    \(endpointLine)

                    [ovn_northbound_tls]
                    ca_cert = "/etc/strato/pki/cacert.pem"
                    """
                let configPath = tempDirectory.appendingPathComponent("config.toml").path
                try tomlContent.write(toFile: configPath, atomically: true, encoding: .utf8)

                await #expect(throws: AgentConfigError.self) {
                    _ = try await loadConfig(from: configPath)
                }
            }
        }
    }

    @Test("A client certificate without its key (or vice versa) is rejected")
    func ovnNorthboundTLSClientPairValidated() async throws {
        try await withTempDirectory { tempDirectory in
            for lonelyKey in ["client_cert", "client_key"] {
                let tomlContent = """
                    control_plane_url = "ws://localhost:8080/agent/ws"
                    ovn_northbound = "ssl:central:6641"

                    [ovn_northbound_tls]
                    \(lonelyKey) = "/etc/strato/pki/half-a-pair.pem"
                    """
                let configPath = tempDirectory.appendingPathComponent("config.toml").path
                try tomlContent.write(toFile: configPath, atomically: true, encoding: .utf8)

                await #expect(throws: AgentConfigError.self) {
                    _ = try await loadConfig(from: configPath)
                }
            }
        }
    }

    @Test("ovn_northbound_tls defaults to nil, and an ssl: endpoint works without it (system trust roots)")
    func ovnNorthboundTLSDefaultsNil() async throws {
        try await withTempDirectory { tempDirectory in
            let tomlContent = """
                control_plane_url = "ws://minimal:8080/ws"
                ovn_northbound = "ssl:central:6641"
                """
            let configPath = tempDirectory.appendingPathComponent("config.toml").path
            try tomlContent.write(toFile: configPath, atomically: true, encoding: .utf8)

            let config = try await loadConfig(from: configPath)
            #expect(config.ovnNorthbound == "ssl:central:6641")
            #expect(config.ovnNorthboundTLS == nil)
        }
    }

    @Test("ovn_northbound defaults to nil (legacy local socket)")
    func ovnNorthboundDefaultsNil() async throws {
        try await withTempDirectory { tempDirectory in
            let tomlContent = """
                control_plane_url = "ws://minimal:8080/ws"
                """
            let configPath = tempDirectory.appendingPathComponent("config.toml").path
            try tomlContent.write(toFile: configPath, atomically: true, encoding: .utf8)

            let config = try await loadConfig(from: configPath)
            #expect(config.ovnNorthbound == nil)
        }
    }

    @Test("A malformed ovn_northbound is rejected at load time")
    func ovnNorthboundValidated() async throws {
        try await withTempDirectory { tempDirectory in
            let tomlContent = """
                control_plane_url = "ws://minimal:8080/ws"
                ovn_northbound = "central:6641"
                """
            let configPath = tempDirectory.appendingPathComponent("config.toml").path
            try tomlContent.write(toFile: configPath, atomically: true, encoding: .utf8)

            await #expect(throws: AgentConfigError.self) {
                _ = try await loadConfig(from: configPath)
            }
        }
    }

    @Test("Chassis bootstrap defaults to enabled when keys are absent")
    func ovnChassisSettingsDefault() async throws {
        try await withTempDirectory { tempDirectory in
            let tomlContent = """
                control_plane_url = "ws://minimal:8080/ws"
                """
            let configPath = tempDirectory.appendingPathComponent("config.toml").path
            try tomlContent.write(toFile: configPath, atomically: true, encoding: .utf8)

            let config = try await loadConfig(from: configPath)
            #expect(config.ovnBootstrapChassis == nil)
            let chassis = config.ovnChassisConfig
            #expect(chassis.bootstrapEnabled)
            #expect(chassis.encapIP == nil)
            #expect(chassis.remote == nil)
        }
    }

    @Test("Load minimal TOML configuration")
    func loadMinimalConfig() async throws {
        try await withTempDirectory { tempDirectory in
            let tomlContent = """
                control_plane_url = "ws://minimal:8080/ws"
                """

            let configPath = tempDirectory.appendingPathComponent("minimal.toml").path
            try tomlContent.write(toFile: configPath, atomically: true, encoding: .utf8)

            let config = try await loadConfig(from: configPath)

            #expect(config.controlPlaneURL == "ws://minimal:8080/ws")
            #expect(config.logLevel == nil)
            #expect(config.networkMode == nil)
        }
    }

    @Test("Load configuration with user network mode")
    func loadConfigWithUserNetworkMode() async throws {
        try await withTempDirectory { tempDirectory in
            let tomlContent = """
                control_plane_url = "ws://localhost:8080/agent/ws"
                network_mode = "user"
                """

            let configPath = tempDirectory.appendingPathComponent("user-mode.toml").path
            try tomlContent.write(toFile: configPath, atomically: true, encoding: .utf8)

            let config = try await loadConfig(from: configPath)

            #expect(config.networkMode == .user)
        }
    }

    // MARK: - Error Handling Tests

    @Test("Loading non-existent config file throws error")
    func loadConfigFileNotFound() async {
        let nonExistentPath = "/tmp/does-not-exist-\(UUID().uuidString).toml"

        await #expect(throws: AgentConfigError.self) {
            try await AgentConfig.load(
                from: nonExistentPath,
                environmentVariables: [
                    "CONTROL_PLANE_URL": "ws://environment:8080/agent/ws"
                ])
        }
    }

    @Test("Loading config without required field throws error")
    func loadConfigMissingRequiredField() async throws {
        try await withTempDirectory { tempDirectory in
            let tomlContent = """
                log_level = "debug"
                """

            let configPath = tempDirectory.appendingPathComponent("missing-url.toml").path
            try tomlContent.write(toFile: configPath, atomically: true, encoding: .utf8)

            await #expect(throws: AgentConfigError.self) {
                try await loadConfig(from: configPath)
            }
        }
    }

    @Test("Loading config with invalid network mode throws error")
    func loadConfigInvalidNetworkMode() async throws {
        try await withTempDirectory { tempDirectory in
            let tomlContent = """
                control_plane_url = "ws://localhost:8080/agent/ws"
                network_mode = "invalid_mode"
                """

            let configPath = tempDirectory.appendingPathComponent("invalid-mode.toml").path
            try tomlContent.write(toFile: configPath, atomically: true, encoding: .utf8)

            await #expect(throws: AgentConfigError.self) {
                try await loadConfig(from: configPath)
            }
        }
    }

    @Test("Loading invalid TOML throws error")
    func loadConfigInvalidTOML() async throws {
        try await withTempDirectory { tempDirectory in
            let invalidToml = """
                control_plane_url = ws://localhost:8080/agent/ws
                [this is not valid toml
                """

            let configPath = tempDirectory.appendingPathComponent("invalid.toml").path
            try invalidToml.write(toFile: configPath, atomically: true, encoding: .utf8)

            await #expect(throws: Error.self) {
                try await loadConfig(from: configPath)
            }
        }
    }

    // MARK: - Default Config Tests

    @Test("Load default configuration")
    func loadDefaultConfig() async throws {
        // Empty search paths: exercise the built-in defaults rather than
        // whatever config file the host operator happens to have installed.
        let config = try await loadDefaultConfig(searchPaths: [])

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

        // The built-in defaults must agree with the fallbacks the CLI applies
        // for an unset key — a divergent copy here silently wins, because it
        // leaves the field non-nil and the `?? AgentConfig.default*` fallback
        // in StratoAgent is never reached.
        #expect(config.vmStoragePath == AgentConfig.defaultVMStoragePath)
    }

    @Test("Default config search skips absent paths but rejects a present invalid file")
    func loadDefaultConfigSearchOrder() async throws {
        try await withTempDirectory { tempDirectory in
            let secondPath = tempDirectory.appendingPathComponent("second.toml").path
            try """
            control_plane_url = "ws://second:8080/agent/ws"
            """.write(toFile: secondPath, atomically: true, encoding: .utf8)

            // An absent file is skipped...
            let missingPath = tempDirectory.appendingPathComponent("missing.toml").path
            let skipped = try await loadDefaultConfig(searchPaths: [missingPath, secondPath])
            #expect(skipped.controlPlaneURL == "ws://second:8080/agent/ws")

            // A present config is authoritative. Syntax errors and missing
            // required settings must not fall through to another file or the
            // built-in defaults.
            let malformedPath = tempDirectory.appendingPathComponent("malformed.toml").path
            try "[this is not valid toml".write(toFile: malformedPath, atomically: true, encoding: .utf8)
            let incompletePath = tempDirectory.appendingPathComponent("incomplete.toml").path
            try "log_level = \"debug\"".write(toFile: incompletePath, atomically: true, encoding: .utf8)

            await #expect(throws: Error.self) {
                try await loadDefaultConfig(
                    searchPaths: [malformedPath, incompletePath, secondPath])
            }
            await #expect(throws: AgentConfigError.self) {
                try await loadDefaultConfig(searchPaths: [incompletePath, secondPath])
            }

            let obsoletePath = tempDirectory.appendingPathComponent("obsolete.toml").path
            try """
            control_plane_url = "ws://obsolete:8080/agent/ws"
            qemu_driver = "process"
            """.write(toFile: obsoletePath, atomically: true, encoding: .utf8)
            await #expect {
                try await loadDefaultConfig(searchPaths: [obsoletePath, secondPath])
            } throws: { error in
                error.localizedDescription
                    == "Invalid configuration: unknown setting 'qemu_driver'"
            }

            // Every path being absent falls through to the built-in defaults.
            let anotherMissingPath = tempDirectory.appendingPathComponent("also-missing.toml").path
            let exhausted = try await loadDefaultConfig(
                searchPaths: [missingPath, anotherMissingPath])
            #expect(exhausted.controlPlaneURL == AgentConfig.builtinDefaults.controlPlaneURL)

            let firstPath = tempDirectory.appendingPathComponent("first.toml").path
            try """
            control_plane_url = "ws://first:8080/agent/ws"
            """.write(toFile: firstPath, atomically: true, encoding: .utf8)

            let first = try await loadDefaultConfig(searchPaths: [firstPath, secondPath])
            #expect(first.controlPlaneURL == "ws://first:8080/agent/ws")
        }
    }

    // MARK: - Environment Configuration Tests

    @Test("Environment values override TOML and absent values fall back to TOML")
    func environmentOverridesTOML() async throws {
        try await withTempDirectory { tempDirectory in
            let configPath = tempDirectory.appendingPathComponent("config.toml").path
            try """
            control_plane_url = "ws://toml:8080/agent/ws"
            log_level = "info"
            network_mode = "ovn"
            enable_kvm = true
            qemu_memory_overhead_mb = 256
            vm_storage_dir = "/toml/vms"

            [spiffe]
            enabled = false
            trust_domain = "toml.example"

            [ovn_dynamic_routing]
            enabled = false
            redistribute = ["connected"]
            routing_protocols = ["BGP"]
            """.write(toFile: configPath, atomically: true, encoding: .utf8)

            let config = try await AgentConfig.load(
                from: configPath,
                environmentVariables: [
                    "CONTROL_PLANE_URL": "ws://environment:8080/agent/ws",
                    "LOG_LEVEL": "debug",
                    "NETWORK_MODE": "user",
                    "ENABLE_KVM": "false",
                    "QEMU_MEMORY_OVERHEAD_MB": "768",
                    "SPIFFE_ENABLED": "true",
                    "SPIFFE_TRUST_DOMAIN": "environment.example",
                    "OVN_DYNAMIC_ROUTING_ENABLED": "true",
                    "OVN_DYNAMIC_ROUTING_REDISTRIBUTE": "nat, static",
                    "OVN_DYNAMIC_ROUTING_ROUTING_PROTOCOLS": "BGP, BFD",
                ])

            #expect(config.controlPlaneURL == "ws://environment:8080/agent/ws")
            #expect(config.logLevel == .debug)
            #expect(config.networkMode == .user)
            #expect(config.enableKVM == false)
            #expect(config.qemuMemoryOverheadMB == 768)
            #expect(config.vmStoragePath == "/toml/vms")
            #expect(config.spiffe?.enabled == true)
            #expect(config.spiffe?.trustDomain == "environment.example")
            #expect(config.ovnDynamicRouting?.enabled == true)
            #expect(config.ovnDynamicRouting?.redistribute == ["nat", "static"])
            #expect(config.ovnDynamicRouting?.routingProtocols == ["BGP", "BFD"])
        }
    }

    @Test("Environment-only configuration overlays built-in defaults when no file loads")
    func environmentOverlaysBuiltInDefaults() async throws {
        let config = try await AgentConfig.loadDefaultConfig(
            searchPaths: [],
            environmentVariables: [
                "CONTROL_PLANE_URL": "ws://environment:8080/agent/ws",
                "LOG_LEVEL": "trace",
                "SIMULATION_ENABLED": "true",
                "SIMULATION_CPU_CORES": "24",
            ])

        #expect(config.controlPlaneURL == "ws://environment:8080/agent/ws")
        #expect(config.logLevel == .trace)
        #expect(config.vmStoragePath == AgentConfig.defaultVMStoragePath)
        #expect(config.simulation?.enabled == true)
        #expect(config.simulation?.cpuCores == 24)
    }

    @Test(
        "Environment accepts every representative log threshold",
        arguments: [AgentLogLevel.trace, .info, .warning])
    func loadSupportedEnvironmentLogLevel(_ level: AgentLogLevel) async throws {
        let config = try await AgentConfig.loadDefaultConfig(
            searchPaths: [],
            environmentVariables: ["LOG_LEVEL": level.rawValue])

        #expect(config.logLevel == level)
    }

    @Test("Environment rejects an unsupported log threshold")
    func rejectInvalidEnvironmentLogLevel() async {
        do {
            _ = try await AgentConfig.loadDefaultConfig(
                searchPaths: [],
                environmentVariables: ["LOG_LEVEL": "verbose"])
            Issue.record("Expected unsupported environment log level to fail")
        } catch let error as AgentConfigError {
            #expect(error.localizedDescription == Self.invalidLogLevelMessage)
        } catch {
            Issue.record("Expected AgentConfigError, got \(error)")
        }
    }

    @Test("Invalid environment value reports its logical key")
    func invalidEnvironmentTypeReportsKey() async throws {
        try await withTempDirectory { tempDirectory in
            let configPath = tempDirectory.appendingPathComponent("config.toml").path
            try "control_plane_url = \"ws://toml:8080/agent/ws\"".write(
                toFile: configPath, atomically: true, encoding: .utf8)

            do {
                _ = try await AgentConfig.load(
                    from: configPath,
                    environmentVariables: ["QEMU_MEMORY_OVERHEAD_MB": "not-an-integer"])
                Issue.record("Expected malformed environment configuration to fail")
            } catch AgentConfigError.invalidConfiguration(let message) {
                #expect(message.contains("qemu_memory_overhead_mb"))
            } catch {
                Issue.record("Expected AgentConfigError.invalidConfiguration, got \(error)")
            }
        }
    }

    @Test("Environment values retain enum, bounds, and paired-field validation")
    func invalidEnvironmentSemanticsFail() async throws {
        try await withTempDirectory { tempDirectory in
            let configPath = tempDirectory.appendingPathComponent("config.toml").path
            try "control_plane_url = \"ws://toml:8080/agent/ws\"".write(
                toFile: configPath, atomically: true, encoding: .utf8)

            for environmentVariables in [
                ["NETWORK_MODE": "invalid"],
                ["QEMU_MEMORY_OVERHEAD_MB": "127"],
                ["FIRMWARE_CODE_PATH": "/firmware/code.fd"],
                ["OVN_UPLINK_BRIDGE": "br-ex"],
            ] {
                await #expect(throws: AgentConfigError.self) {
                    _ = try await AgentConfig.load(
                        from: configPath,
                        environmentVariables: environmentVariables)
                }
            }
        }
    }

    @Test("Invalid environment configuration fails when no file loads")
    func invalidEnvironmentFailsWithoutFile() async {
        await #expect(throws: AgentConfigError.self) {
            _ = try await AgentConfig.loadDefaultConfig(
                searchPaths: [],
                environmentVariables: ["NETWORK_MODE": "invalid"])
        }
    }

    @Test("Empty TOML sections do not configure nested settings")
    func emptySectionsHaveNoEffect() async throws {
        try await withTempDirectory { tempDirectory in
            let configPath = tempDirectory.appendingPathComponent("config.toml").path
            try """
            control_plane_url = "ws://toml:8080/agent/ws"

            [simulation]

            [resolver]

            [ovn_uplink]
            """.write(toFile: configPath, atomically: true, encoding: .utf8)

            let config = try await loadConfig(from: configPath)

            #expect(config.simulation == nil)
            #expect(config.resolver == nil)
            #expect(config.ovnUplink == nil)
        }
    }

    // MARK: - Error Description Tests

    @Test("AgentConfigError provides descriptive messages")
    func agentConfigErrorDescriptions() {
        let fileNotFoundError = AgentConfigError.configFileNotFound("/test/path")
        #expect(fileNotFoundError.errorDescription?.contains("/test/path") == true)

        let missingFieldError = AgentConfigError.missingRequiredField("test_field")
        #expect(missingFieldError.errorDescription?.contains("test_field") == true)

        let invalidConfigError = AgentConfigError.invalidConfiguration("test message")
        #expect(invalidConfigError.errorDescription?.contains("test message") == true)
    }

    // MARK: - Platform-Specific Configuration Tests

    @Test("Platform-specific settings are handled correctly")
    func loadConfigWithPlatformSpecificSettings() async throws {
        try await withTempDirectory { tempDirectory in
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
            let config = try await loadConfig(from: configPath)
            #expect(config.controlPlaneURL == "ws://localhost:8080/agent/ws")
        }
    }

    // MARK: - Teardown blast-radius guard (STR-98)

    @Test("Load the teardown guard settings")
    func loadTeardownGuardSettings() async throws {
        try await withTempDirectory { tempDirectory in
            let tomlContent = """
                control_plane_url = "ws://localhost:8080/agent/ws"
                reconcile_teardown_minimum = 10
                reconcile_teardown_percent = 50
                allow_bulk_teardown = true
                """
            let configPath = tempDirectory.appendingPathComponent("config.toml").path
            try tomlContent.write(toFile: configPath, atomically: true, encoding: .utf8)

            let config = try await loadConfig(from: configPath)

            #expect(config.reconcileTeardownMinimum == 10)
            #expect(config.reconcileTeardownPercent == 50)
            #expect(config.allowBulkTeardown == true)
            let guardSettings = config.teardownGuard
            #expect(guardSettings.minimumWorkloads == 10)
            #expect(guardSettings.percentOfPresent == 50)
            #expect(guardSettings.allowBulkTeardown)
        }
    }

    @Test("The teardown guard defaults to on, at 3 workloads and 25%")
    func teardownGuardDefaults() async throws {
        try await withTempDirectory { tempDirectory in
            let configPath = tempDirectory.appendingPathComponent("config.toml").path
            try "control_plane_url = \"ws://x:8080/agent/ws\"".write(
                toFile: configPath, atomically: true, encoding: .utf8)

            let config = try await loadConfig(from: configPath)

            #expect(config.reconcileTeardownMinimum == nil)
            #expect(config.allowBulkTeardown == nil)
            let guardSettings = config.teardownGuard
            #expect(guardSettings.minimumWorkloads == 3)
            #expect(guardSettings.percentOfPresent == 25)
            #expect(!guardSettings.allowBulkTeardown)
            // The point of the defaults: a host losing everything is refused,
            // while a couple of strays on a small host are not.
            #expect(guardSettings.refusal(teardowns: 8, present: 8) != nil)
            #expect(guardSettings.refusal(teardowns: 3, present: 3) == nil)
            #expect(guardSettings.refusal(teardowns: 4, present: 40) == nil)
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
        #expect(
            AgentConfig.defaultConfigSearchPaths == [
                AgentConfig.defaultConfigPath, AgentConfig.fallbackConfigPath,
            ])
    }
}
