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

    // MARK: - Sandbox knobs (issue #470)

    @Test("Sandbox log interval defaults on, 0 disables, and set values convert to a Duration")
    func resolvedSandboxLogInterval() {
        let defaulted = SimulationConfig(enabled: true)
        #expect(
            defaulted.resolvedSandboxLogInterval
                == .milliseconds(SimulationConfig.defaultSandboxLogIntervalMS))

        let disabled = SimulationConfig(enabled: true, sandboxLogIntervalMS: 0)
        #expect(disabled.resolvedSandboxLogInterval == nil)

        let custom = SimulationConfig(enabled: true, sandboxLogIntervalMS: 250)
        #expect(custom.resolvedSandboxLogInterval == .milliseconds(250))
    }

    @Test("Sandbox workload lifetime defaults off (workloads run until stopped)")
    func resolvedSandboxLifetime() {
        #expect(SimulationConfig(enabled: true).resolvedSandboxLifetime == nil)
        #expect(SimulationConfig(enabled: true, sandboxExitAfterSeconds: 0).resolvedSandboxLifetime == nil)
        let oneShot = SimulationConfig(enabled: true, sandboxExitAfterSeconds: 90)
        #expect(oneShot.resolvedSandboxLifetime == .seconds(90))
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
                sandbox_log_interval_ms = 1000
                sandbox_exit_after_seconds = 120
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
            #expect(sim.sandboxLogIntervalMS == 1000)
            #expect(sim.sandboxExitAfterSeconds == 120)
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
            #expect(sim.sandboxLogIntervalMS == nil)
            #expect(sim.sandboxExitAfterSeconds == nil)
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
