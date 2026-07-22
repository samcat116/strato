#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif
import ArgumentParser
import Foundation
import Logging
import StratoAgentCore

@main
struct StratoAgent: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "strato-agent",
        abstract: "Strato hypervisor agent for managing VMs on QEMU",
        version: BuildInfo.displayVersion,
        subcommands: [Run.self],
        defaultSubcommand: Run.self
    )
}

/// Options for `run`.
struct AgentOptions: ParsableArguments {
    @Option(name: .long, help: "Control plane WebSocket URL (overrides config file)")
    var controlPlaneURL: String?

    @Option(name: .long, help: "Agent ID (defaults to hostname)")
    var agentID: String?

    @Option(name: .long, help: "QEMU socket directory path (overrides config file)")
    var qemuSocketDir: String?

    @Option(name: .long, help: "Log level (overrides config file)")
    var logLevel: String?

    @Option(name: .long, help: "Path to configuration file")
    var configFile: String?

    @Option(name: .long, help: "VM storage directory path (overrides config file)")
    var vmStorageDir: String?

    @Option(name: .long, help: "QEMU binary path (overrides config file)")
    var qemuBinaryPath: String?

    @Option(name: .long, help: "Firecracker binary path (overrides config file, Linux only)")
    var firecrackerBinaryPath: String?

    @Option(name: .long, help: "Firecracker socket directory (overrides config file, Linux only)")
    var firecrackerSocketDir: String?

    @Flag(name: .long, help: "Run as a simulated 'dummy' agent: no real VMs, fake capacity (for scale testing)")
    var simulate: Bool = false

    @Option(name: .long, help: "Simulated logical CPU core count (simulation mode; overrides config)")
    var simCpus: Int?

    @Option(name: .long, help: "Simulated total memory in MB (simulation mode; overrides config)")
    var simMemoryMb: Int?

    @Option(name: .long, help: "Simulated total disk in GB (simulation mode; overrides config)")
    var simDiskGb: Int?

    @Flag(name: .long, help: "Enable debug mode")
    var debug: Bool = false
}

extension StratoAgent {
    struct Run: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "run",
            abstract: "Run the agent (default command)"
        )

        @OptionGroup var options: AgentOptions

        func run() async throws {
            try await launchAgent(options: options)
        }
    }
}

/// Launch path for `run`.
private func launchAgent(options: AgentOptions) async throws {
    // Set up custom logging with clean timestamps (no timezone suffix)
    let debug = options.debug
    LoggingSystem.bootstrap { label in
        var handler = CustomLogHandler(label: label)
        handler.logLevel = debug ? .debug : .info
        return handler
    }

    var logger = Logger(label: "strato-agent")
    logger.logLevel = debug ? .debug : .info

    // Load configuration from file or defaults
    let config: AgentConfig
    if let configFile = options.configFile {
        do {
            config = try AgentConfig.load(from: configFile)
            logger.info("Loaded configuration from: \(configFile)")
        } catch {
            logger.error("Failed to load configuration from \(configFile): \(error)")
            throw ExitCode.failure
        }
    } else {
        config = AgentConfig.loadDefaultConfig(logger: logger)
    }

    // Override config values with command-line arguments if provided
    let finalQemuSocketDir = options.qemuSocketDir ?? config.qemuSocketDir ?? AgentConfig.defaultQemuSocketDir
    let finalLogLevel = options.logLevel ?? config.logLevel ?? "info"
    let finalAgentID = options.agentID ?? ProcessInfo.processInfo.hostName

    // The agent authenticates solely with its SPIRE-issued X.509 SVID, so the
    // dialed URL carries no credential — just the configured control-plane URL
    // plus the agent's own name.
    let baseControlPlaneURL = options.controlPlaneURL ?? config.controlPlaneURL
    guard
        let finalWebSocketURL = WebSocketURLs.appendingNameQueryParameter(
            to: baseControlPlaneURL,
            name: finalAgentID
        )
    else {
        logger.error("Invalid control plane URL: \(baseControlPlaneURL)")
        logger.error("Expected format: wss://host:port/agent/ws")
        throw ExitCode.failure
    }
    let finalVMStoragePath = options.vmStorageDir ?? config.vmStoragePath ?? AgentConfig.defaultVMStoragePath
    let finalVolumeStoragePath = config.volumeStoragePath ?? FileSystemStorageBackend.defaultStoragePath
    let finalQemuBinaryPath = options.qemuBinaryPath ?? config.qemuBinaryPath ?? AgentConfig.defaultQemuBinaryPath

    // Resolve firmware configuration. The monolithic `firmware_path_*` keys
    // stay architecture-specific (they name one host's image); the split
    // CODE/VARS keys are not, since an agent only ever resolves firmware for
    // the architecture it runs (issue #565).
    #if arch(arm64)
    let finalMonolithicFirmwarePath = config.firmwarePathARM64
    #else
    let finalMonolithicFirmwarePath = config.firmwarePathX86_64
    #endif
    let finalFirmware = FirmwareOverrides(
        codePath: config.firmwareCodePath,
        varsTemplatePath: config.firmwareVarsTemplate,
        secureBootCodePath: config.secureBootFirmwareCodePath,
        secureBootVarsTemplatePath: config.secureBootFirmwareVarsTemplate,
        monolithicPath: finalMonolithicFirmwarePath
    )
    let finalSwtpmBinaryPath = config.swtpmBinaryPath ?? AgentConfig.defaultSwtpmBinaryPath

    // Resolve Firecracker configuration (Linux only)
    let finalFirecrackerBinaryPath =
        options.firecrackerBinaryPath ?? config.firecrackerBinaryPath ?? AgentConfig.defaultFirecrackerBinaryPath
    let finalFirecrackerSocketDir =
        options.firecrackerSocketDir ?? config.firecrackerSocketDir ?? AgentConfig.defaultFirecrackerSocketDir
    let finalSandboxGuestImagePath =
        config.sandboxGuestImagePath ?? AgentConfig.defaultSandboxGuestImagePath

    // Resolve the sandbox jailer settings (issue #425)
    let finalSandboxJailerMode = config.sandboxJailerMode ?? .auto
    let finalSandboxJailerBinaryPath =
        config.sandboxJailerBinaryPath
        ?? AgentConfig.defaultSandboxJailerBinaryPath(firecrackerBinaryPath: finalFirecrackerBinaryPath)
    let finalSandboxJailerChrootDir =
        config.sandboxJailerChrootDir
        ?? AgentConfig.defaultSandboxJailerChrootDir(vmStoragePath: finalVMStoragePath)
    let finalSandboxJailerUidBase = config.sandboxJailerUidBase ?? AgentConfig.defaultSandboxJailerUidBase

    // Resolve hypervisor type
    let finalHypervisorType = config.hypervisorType ?? AgentConfig.defaultHypervisorType

    // Resolve simulation ("dummy agent") settings: the `--simulate` flag or the
    // config's [simulation] section turns it on, and CLI capacity flags override
    // config values. When off, `finalSimulation` is nil and the agent runs real
    // backends.
    let simulationEnabled = options.simulate || (config.simulation?.enabled ?? false)
    let finalSimulation: SimulationConfig? =
        simulationEnabled
        ? SimulationConfig(
            enabled: true,
            cpuCores: options.simCpus ?? config.simulation?.cpuCores,
            memoryMB: options.simMemoryMb ?? config.simulation?.memoryMB,
            diskGB: options.simDiskGb ?? config.simulation?.diskGB,
            sandboxLogIntervalMS: config.simulation?.sandboxLogIntervalMS,
            sandboxExitAfterSeconds: config.simulation?.sandboxExitAfterSeconds)
        : nil

    // Resolve hardware acceleration preference. Acceleration is on by default;
    // operators can disable it (forcing TCG emulation) via config. `enable_kvm`
    // applies on Linux and `enable_hvf` on macOS — the other is ignored per platform.
    #if os(macOS)
    let finalHardwareAcceleration = config.enableHVF ?? true
    #elseif os(Linux)
    let finalHardwareAcceleration = config.enableKVM ?? true
    #else
    let finalHardwareAcceleration = false
    #endif

    // Update log level based on final configuration
    logger.logLevel = debug ? .debug : Logger.Level(rawValue: finalLogLevel) ?? .info

    logger.info(
        "Starting Strato Agent",
        metadata: [
            "agentID": .string(finalAgentID),
            "webSocketURL": .string(finalWebSocketURL),
            "qemuSocketDir": .string(finalQemuSocketDir),
            "vmStoragePath": .string(finalVMStoragePath),
            "volumeStoragePath": .string(finalVolumeStoragePath),
            "imageCacheDir": .string(config.imageCacheDir ?? ImageCacheService.defaultCachePath),
            "imageCacheMaxSize": .string(config.imageCacheMaxSizeGB.map { "\($0)GB" } ?? "unbounded"),
            "sandboxImageCacheMaxSize": .string(
                config.sandboxImageCacheMaxSizeGB.map { "\($0)GB" } ?? "unbounded"),
            "qemuBinaryPath": .string(finalQemuBinaryPath),
            "firmwarePath": .string(finalMonolithicFirmwarePath ?? "(platform default)"),
            "firmwareCodePath": .string(config.firmwareCodePath ?? "(platform default)"),
            "swtpmBinaryPath": .string(finalSwtpmBinaryPath ?? "(not installed)"),
            "firecrackerBinaryPath": .string(finalFirecrackerBinaryPath),
            "firecrackerSocketDir": .string(finalFirecrackerSocketDir),
            "sandboxGuestImagePath": .string(finalSandboxGuestImagePath),
            "sandboxJailerMode": .string(finalSandboxJailerMode.rawValue),
            "hypervisorType": .string(finalHypervisorType.rawValue),
            "hardwareAcceleration": .string(finalHardwareAcceleration ? "enabled" : "disabled"),
            "logLevel": .string(finalLogLevel),
            "simulation": .string(finalSimulation?.enabled == true ? "enabled" : "disabled"),
        ])

    if let sim = finalSimulation, sim.enabled {
        logger.warning(
            "Simulation mode: this agent will NOT run real VMs; reporting fake capacity",
            metadata: [
                "cpuCores": .stringConvertible(sim.resolvedCPUCores),
                "memoryMB": .stringConvertible(sim.resolvedMemoryBytes / (1024 * 1024)),
                "diskGB": .stringConvertible(sim.resolvedDiskBytes / (1024 * 1024 * 1024)),
            ])
    }

    // SPIFFE/SPIRE mTLS is the agent's only means of authenticating to the
    // control plane, so it is mandatory. Agent.start() enforces this too; the
    // check here fails before any subsystem is initialized.
    guard let spiffe = config.spiffe, spiffe.enabled else {
        logger.error("SPIFFE authentication is not configured; the agent cannot authenticate to the control plane.")
        logger.error(
            "Add a [spiffe] section with enabled = true (and trust_domain / source_type) to the agent config file."
        )
        throw ExitCode.failure
    }
    logger.info(
        "SPIFFE authentication enabled",
        metadata: [
            "trustDomain": .string(spiffe.trustDomain ?? "strato.local"),
            "sourceType": .string(spiffe.sourceType ?? "workload_api"),
        ])

    let agent = Agent(
        agentID: finalAgentID,
        webSocketURL: finalWebSocketURL,
        qemuSocketDir: finalQemuSocketDir,
        networkMode: config.networkMode,
        ovnChassisConfig: config.ovnChassisConfig,
        ovnUplink: config.ovnUplink,
        ovnDynamicRouting: config.ovnDynamicRouting,
        ovnNorthbound: config.ovnNorthbound,
        ovnNorthboundTLS: config.ovnNorthboundTLS,
        logger: logger,
        imageCachePath: config.imageCacheDir,
        imageCacheMaxSizeBytes: config.imageCacheMaxSizeBytes,
        sandboxImageCachePath: config.sandboxImageCacheDir,
        sandboxImageCacheMaxSizeBytes: config.sandboxImageCacheMaxSizeBytes,
        vmStoragePath: finalVMStoragePath,
        volumeStoragePath: finalVolumeStoragePath,
        qemuBinaryPath: finalQemuBinaryPath,
        firmware: finalFirmware,
        swtpmBinaryPath: finalSwtpmBinaryPath,
        firecrackerBinaryPath: finalFirecrackerBinaryPath,
        firecrackerSocketDir: finalFirecrackerSocketDir,
        sandboxGuestImagePath: finalSandboxGuestImagePath,
        sandboxJailerMode: finalSandboxJailerMode,
        sandboxJailerBinaryPath: finalSandboxJailerBinaryPath,
        sandboxJailerChrootDir: finalSandboxJailerChrootDir,
        sandboxJailerUidBase: finalSandboxJailerUidBase,
        sandboxWarmStart: config.sandboxWarmStart ?? true,
        sandboxWarmCacheMaxSizeBytes: config.sandboxWarmCacheMaxSizeBytes,
        hypervisorType: finalHypervisorType,
        hardwareAccelerationEnabled: finalHardwareAcceleration,
        simulation: finalSimulation,
        spiffeConfig: config.spiffe
    )

    // Install signal handlers so `systemctl stop`/Ctrl-C triggers a graceful
    // shutdown: unregistering from the control plane, disconnecting consoles,
    // and tearing down networking. Without this the process is simply killed
    // and every restart looks like an unclean crash. The handler is retained
    // for the lifetime of this call (which blocks in agent.start()).
    let signalLogger = logger
    let signalHandler = SignalHandler { sig in
        signalLogger.info("Received signal \(sig); shutting down gracefully")
        // Watchdog: leave regardless of what shutdown does. Whatever we would
        // still be waiting on, waiting longer does not help — a stop that has
        // not finished in this long is wedged, and the workloads that matter
        // (QEMU/Firecracker) are separate processes that outlive us by design.
        //
        // Deliberately a Dispatch timer, not `Task.sleep`: the failure this
        // guards against includes the concurrency runtime itself failing to
        // wind the process down, and a watchdog that runs on the pool it is
        // watching is no watchdog at all.
        DispatchQueue.global().asyncAfter(deadline: .now() + shutdownWatchdogSeconds) {
            signalLogger.error(
                "Shutdown did not reach process exit within \(Int(shutdownWatchdogSeconds))s; exiting now")
            exitImmediately(0)
        }
        Task {
            await agent.stop()
        }
    }
    signalHandler.install()

    do {
        try await agent.start()
    } catch let error as AgentError {
        logger.error("Agent failed to start: \(error)")
        if case .registrationRejected = error {
            logger.error(
                "The control plane rejected this agent's identity. Verify the SPIRE registration entry for this agent's SPIFFE ID and that the control plane trusts the same trust domain."
            )
        }
        // Same reason as the success path below: subsystems have already spun
        // up threads by the time start() can fail, so leave explicitly.
        exitImmediately(1)
    } catch {
        logger.error("Agent failed to start: \(error)")
        exitImmediately(1)
    }

    // A successful self-update ends with a deliberate non-zero exit so a
    // supervisor with Restart=on-failure (what install.sh writes) starts the
    // new binary; a plain `systemctl stop`/Ctrl-C shutdown still exits 0.
    if await agent.updateRestartPending {
        logger.notice(
            "Exiting with code \(AgentUpdater.restartExitCode) so the supervisor restarts the updated binary")
        exitImmediately(AgentUpdater.restartExitCode)
    }

    exitImmediately(0)
}

/// How long after a termination signal the agent gives graceful shutdown before
/// leaving anyway. Comfortably above a healthy shutdown (a second or two) and
/// well under the unit's `TimeoutStopSec`, so a wedged stop still produces a
/// clean exit rather than a SIGKILL.
private let shutdownWatchdogSeconds: Double = 20

/// Ends the process now, without unwinding.
///
/// Nothing else here terminates the process on a clean shutdown. ArgumentParser
/// only calls `exit` when a command *throws*; returning normally hands control
/// back to the Swift runtime's async-main shim, whose closing `exit(0)` is
/// MainActor-isolated and so has to be drained off the main dispatch queue —
/// after `dispatch_main()` has already `pthread_exit`ed the main thread. In the
/// field that last hop did not happen: the agent logged its final shutdown step
/// and then sat there until systemd's 90s `TimeoutStopSec` SIGKILLed a process
/// with nothing left to do (issue #522). It also explains why the self-update
/// path, which throws `ExitCode` and thus exits directly, was never affected.
///
/// Calling it here runs on the cooperative thread that finished shutdown and
/// needs no hop. `_exit` rather than `exit` so it cannot deadlock in an atexit
/// handler or a static destructor; there is nothing to lose — the log handler
/// writes to stderr with unbuffered `write(2)` — beyond stdio, flushed below.
private func exitImmediately(_ code: Int32) -> Never {
    // `fflush(nil)` flushes every open stream. Naming `stdout`/`stderr`
    // individually does not compile under strict concurrency on Glibc, where
    // they are non-Sendable global `var`s.
    fflush(nil)
    _exit(code)
}
