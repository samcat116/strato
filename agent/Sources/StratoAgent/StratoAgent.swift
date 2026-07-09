import ArgumentParser
import Foundation
import Logging
import StratoAgentCore

@main
struct StratoAgent: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "strato-agent",
        abstract: "Strato hypervisor agent for managing VMs on QEMU",
        version: "1.0.0",
        subcommands: [Run.self, Join.self],
        defaultSubcommand: Run.self
    )
}

/// Options shared by `run` and `join`.
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

    @Option(name: .long, help: "Path to the join state file (overrides config file)")
    var stateFile: String?

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

        @Option(name: .long, help: "Registration URL with token (for initial registration)")
        var registrationURL: String?

        func run() async throws {
            try await launchAgent(
                options: options,
                registrationURL: registrationURL,
                writeConfigIfMissing: false
            )
        }
    }

    struct Join: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "join",
            abstract: "Join a control plane with a registration URL, then keep running as the agent",
            discussion: """
                Takes the registration URL shown when creating an agent token in \
                the Strato UI (ws://control-plane/agent/ws?token=...&name=...). \
                On success the agent persists its rotated reconnect token to the \
                state file and, if no config file exists yet, writes a minimal \
                one — so plain `strato-agent` restarts reconnect automatically.
                """
        )

        @Argument(help: "Registration URL from the control plane (includes token and name)")
        var registrationURL: String

        @OptionGroup var options: AgentOptions

        func run() async throws {
            try await launchAgent(
                options: options,
                registrationURL: registrationURL,
                writeConfigIfMissing: true
            )
        }
    }
}

/// Shared launch path for `run` and `join`.
private func launchAgent(
    options: AgentOptions,
    registrationURL: String?,
    writeConfigIfMissing: Bool
) async throws {
    // Set up custom logging with clean timestamps (no timezone suffix)
    let debug = options.debug
    LoggingSystem.bootstrap { label in
        var handler = CustomLogHandler(label: label)
        handler.logLevel = debug ? .debug : .info
        return handler
    }

    var logger = Logger(label: "strato-agent")
    logger.logLevel = debug ? .debug : .info

    // Validate the registration URL up front so a bad copy-paste fails fast.
    if let regURL = registrationURL {
        guard let url = URL(string: regURL),
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            let queryItems = components.queryItems,
            queryItems.contains(where: { $0.name == "token" }),
            queryItems.contains(where: { $0.name == "name" })
        else {
            logger.error("Invalid registration URL format. Must include 'token' and 'name' query parameters.")
            logger.error("Expected format: ws://host:port/agent/ws?token=TOKEN&name=AGENT_NAME")
            throw ExitCode.failure
        }
    }

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
    } else if writeConfigIfMissing,
        !FileManager.default.fileExists(atPath: AgentConfig.defaultConfigPath),
        !FileManager.default.fileExists(atPath: AgentConfig.fallbackConfigPath),
        let regURL = registrationURL,
        let bareURL = WebSocketURLs.removingQuery(from: regURL)
    {
        // First join on a host with no config: derive the control plane URL
        // from the registration URL and persist it, so plain restarts work.
        config = AgentConfig(controlPlaneURL: bareURL)
        do {
            try AgentConfig.writeMinimalConfig(controlPlaneURL: bareURL, to: AgentConfig.defaultConfigPath)
            logger.info("Wrote initial configuration to \(AgentConfig.defaultConfigPath)")
        } catch {
            // Not fatal: the state file alone is enough to reconnect; the
            // config file is a convenience for further customization.
            logger.warning("Could not write configuration to \(AgentConfig.defaultConfigPath): \(error)")
        }
    } else {
        config = AgentConfig.loadDefaultConfig(logger: logger)
    }

    // Join state store: CLI flag > config file > platform default.
    let statePath = options.stateFile ?? config.stateFilePath ?? FileAgentStateStore.defaultPath
    let stateStore = FileAgentStateStore(path: statePath, logger: logger)

    // Registering consumes the single-use token, so make sure the rotated
    // replacement can actually be persisted BEFORE dialing. Otherwise a
    // non-root join would "succeed" but leave nothing on disk, and the first
    // restart could never reconnect (the join token is already spent).
    if registrationURL != nil {
        do {
            try stateStore.ensureWritable()
        } catch {
            logger.error("Cannot write the join state file at \(statePath): \(error)")
            logger.error(
                "The join state stores the reconnect credential; without it a restart cannot reconnect. Run with sufficient privileges (the default path is \(FileAgentStateStore.defaultPath)), or point --state-file (or state_file in config.toml) at a writable location."
            )
            throw ExitCode.failure
        }
    }

    // Determine the WebSocket URL and registration token, in order of preference:
    // 1. An explicit registration URL (initial join or re-join).
    // 2. Persisted join state (control plane URL + rotated reconnect token).
    // 3. The configured control plane URL as-is (SPIFFE/mTLS or dev setups).
    //
    // In all cases the token never travels in the dialed URL: it is stripped
    // out here and presented in an Authorization header, so the plaintext
    // token can't land in proxy/ingress logs.
    let finalWebSocketURL: String
    let finalRegistrationToken: String?
    let isRegistrationMode: Bool

    if let regURL = registrationURL {
        guard let (strippedURL, token) = WebSocketURLs.extractingToken(from: regURL) else {
            logger.error("Failed to extract registration token from URL")
            throw ExitCode.failure
        }
        finalWebSocketURL = strippedURL
        finalRegistrationToken = token
        isRegistrationMode = true
        logger.info("Using registration URL for initial agent registration")
    } else if let state = stateStore.load(),
        let stateURL = WebSocketURLs.appendingNameQueryParameter(
            to: state.controlPlaneURL,
            name: state.agentName
        )
    {
        finalWebSocketURL = stateURL
        finalRegistrationToken = state.reconnectToken
        isRegistrationMode = false
        logger.info(
            "Resuming from persisted join state",
            metadata: [
                "stateFile": .string(statePath),
                "agentName": .string(state.agentName),
            ])
    } else {
        finalWebSocketURL = options.controlPlaneURL ?? config.controlPlaneURL
        finalRegistrationToken = nil
        isRegistrationMode = false
        logger.info(
            "No join state found; connecting with the configured control plane URL. If the control plane requires token registration, join first with: strato-agent join '<registration-url>'"
        )
    }

    // Override config values with command-line arguments if provided
    let finalQemuSocketDir = options.qemuSocketDir ?? config.qemuSocketDir ?? AgentConfig.defaultQemuSocketDir
    let finalLogLevel = options.logLevel ?? config.logLevel ?? "info"
    let finalAgentID = options.agentID ?? ProcessInfo.processInfo.hostName
    let finalVMStoragePath = options.vmStorageDir ?? config.vmStoragePath ?? AgentConfig.defaultVMStoragePath
    let finalQemuBinaryPath = options.qemuBinaryPath ?? config.qemuBinaryPath ?? AgentConfig.defaultQemuBinaryPath

    // Resolve firmware path from config (architecture-specific)
    #if arch(arm64)
    let finalFirmwarePath = config.firmwarePathARM64
    #else
    let finalFirmwarePath = config.firmwarePathX86_64
    #endif

    // Resolve Firecracker configuration (Linux only)
    let finalFirecrackerBinaryPath =
        options.firecrackerBinaryPath ?? config.firecrackerBinaryPath ?? AgentConfig.defaultFirecrackerBinaryPath
    let finalFirecrackerSocketDir =
        options.firecrackerSocketDir ?? config.firecrackerSocketDir ?? AgentConfig.defaultFirecrackerSocketDir

    // Resolve hypervisor type
    let finalHypervisorType = config.hypervisorType ?? AgentConfig.defaultHypervisorType

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
            "qemuBinaryPath": .string(finalQemuBinaryPath),
            "firmwarePath": .string(finalFirmwarePath ?? "(platform default)"),
            "firecrackerBinaryPath": .string(finalFirecrackerBinaryPath),
            "firecrackerSocketDir": .string(finalFirecrackerSocketDir),
            "hypervisorType": .string(finalHypervisorType.rawValue),
            "hardwareAcceleration": .string(finalHardwareAcceleration ? "enabled" : "disabled"),
            "logLevel": .string(finalLogLevel),
            "stateFile": .string(statePath),
            "registrationMode": .string(isRegistrationMode ? "yes" : "no"),
        ])

    // Log SPIFFE configuration if enabled
    if let spiffe = config.spiffe, spiffe.enabled {
        logger.info(
            "SPIFFE authentication enabled",
            metadata: [
                "trustDomain": .string(spiffe.trustDomain ?? "strato.local"),
                "sourceType": .string(spiffe.sourceType ?? "workload_api"),
            ])
    }

    let agent = Agent(
        agentID: finalAgentID,
        webSocketURL: finalWebSocketURL,
        registrationToken: finalRegistrationToken,
        qemuSocketDir: finalQemuSocketDir,
        networkMode: config.networkMode,
        ovnChassisConfig: config.ovnChassisConfig,
        ovnUplink: config.ovnUplink,
        ovnNorthbound: config.ovnNorthbound,
        isRegistrationMode: isRegistrationMode,
        logger: logger,
        vmStoragePath: finalVMStoragePath,
        qemuBinaryPath: finalQemuBinaryPath,
        firmwarePath: finalFirmwarePath,
        firecrackerBinaryPath: finalFirecrackerBinaryPath,
        firecrackerSocketDir: finalFirecrackerSocketDir,
        hypervisorType: finalHypervisorType,
        hardwareAccelerationEnabled: finalHardwareAcceleration,
        spiffeConfig: config.spiffe,
        stateStore: stateStore
    )

    // Install signal handlers so `systemctl stop`/Ctrl-C triggers a graceful
    // shutdown: unregistering from the control plane, disconnecting consoles,
    // and tearing down networking. Without this the process is simply killed
    // and every restart looks like an unclean crash. The handler is retained
    // for the lifetime of this call (which blocks in agent.start()).
    let signalLogger = logger
    let signalHandler = SignalHandler { sig in
        signalLogger.info("Received signal \(sig); shutting down gracefully")
        Task {
            await agent.stop()
        }
    }
    signalHandler.install()

    do {
        try await agent.start()
    } catch let error as AgentError {
        if case .registrationRejected = error {
            logger.error("Agent failed to start: \(error)")
            logger.error(
                "The token was rejected (expired, already used, or revoked). Create a new registration token in the Strato UI (Agents → Create Registration Token) and run: strato-agent join '<registration-url>'"
            )
        } else {
            logger.error("Agent failed to start: \(error)")
        }
        throw ExitCode.failure
    } catch {
        logger.error("Agent failed to start: \(error)")
        throw ExitCode.failure
    }
}
