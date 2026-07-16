import Foundation
import Testing

@testable import StratoAgentCore

@Suite("Simulation Config")
struct SimulationConfigTests {

    // Helper to create and clean up temporary directories
    private func withTempDirectory<T>(_ body: (URL) throws -> T) rethrows -> T {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sim-config-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }
        return try body(tempDirectory)
    }

    // MARK: - Resolved capacity

    @Test("Unset fields resolve to the documented defaults")
    func resolvedDefaults() {
        let sim = SimulationConfig(enabled: true)
        #expect(sim.resolvedCPUCores == SimulationConfig.defaultCPUCores)
        #expect(sim.resolvedMemoryBytes == Int64(SimulationConfig.defaultMemoryMB) * 1024 * 1024)
        #expect(sim.resolvedDiskBytes == Int64(SimulationConfig.defaultDiskGB) * 1024 * 1024 * 1024)
    }

    @Test("Set fields convert MB/GB to bytes correctly")
    func resolvedOverrides() {
        let sim = SimulationConfig(enabled: true, cpuCores: 32, memoryMB: 65536, diskGB: 1024)
        #expect(sim.resolvedCPUCores == 32)
        #expect(sim.resolvedMemoryBytes == 65536 * 1024 * 1024)
        #expect(sim.resolvedDiskBytes == 1024 * 1024 * 1024 * 1024)
    }

    @Test("disabled is a convenient off switch")
    func disabledDefault() {
        #expect(SimulationConfig.disabled.enabled == false)
    }

    // MARK: - TOML parsing

    @Test("Load [simulation] section from config")
    func loadSimulationSection() throws {
        try withTempDirectory { tempDirectory in
            let tomlContent = """
                control_plane_url = "ws://localhost:8080/agent/ws"

                [simulation]
                enabled = true
                cpu_cores = 16
                memory_mb = 32768
                disk_gb = 500
                """
            let configPath = tempDirectory.appendingPathComponent("config.toml").path
            try tomlContent.write(toFile: configPath, atomically: true, encoding: .utf8)

            let config = try AgentConfig.load(from: configPath)
            let sim = try #require(config.simulation)
            #expect(sim.enabled == true)
            #expect(sim.cpuCores == 16)
            #expect(sim.memoryMB == 32768)
            #expect(sim.diskGB == 500)
            #expect(sim.resolvedMemoryBytes == 32768 * 1024 * 1024)
        }
    }

    @Test("A [simulation] section with only enabled uses capacity defaults")
    func loadSimulationSectionDefaults() throws {
        try withTempDirectory { tempDirectory in
            let tomlContent = """
                control_plane_url = "ws://localhost:8080/agent/ws"

                [simulation]
                enabled = true
                """
            let configPath = tempDirectory.appendingPathComponent("config.toml").path
            try tomlContent.write(toFile: configPath, atomically: true, encoding: .utf8)

            let config = try AgentConfig.load(from: configPath)
            let sim = try #require(config.simulation)
            #expect(sim.enabled == true)
            #expect(sim.cpuCores == nil)
            #expect(sim.resolvedCPUCores == SimulationConfig.defaultCPUCores)
        }
    }

    @Test("No [simulation] section leaves simulation nil (normal agent)")
    func noSimulationSection() throws {
        try withTempDirectory { tempDirectory in
            let tomlContent = """
                control_plane_url = "ws://localhost:8080/agent/ws"
                network_mode = "ovn"
                """
            let configPath = tempDirectory.appendingPathComponent("config.toml").path
            try tomlContent.write(toFile: configPath, atomically: true, encoding: .utf8)

            let config = try AgentConfig.load(from: configPath)
            #expect(config.simulation == nil)
        }
    }
}
