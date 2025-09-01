import ArgumentParser
import Foundation
import Logging

@main
struct StratoAgent: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "strato-agent",
        abstract: "Strato hypervisor agent for managing VMs on QEMU",
        version: "1.0.0"
    )
    
    @Option(name: .long, help: "Control plane WebSocket URL (overrides config file)")
    var controlPlaneURL: String?
    
    @Option(name: .long, help: "Registration URL with token (for initial registration)")
    var registrationURL: String?
    
    @Option(name: .long, help: "Agent ID (defaults to hostname)")
    var agentID: String?
    
    @Option(name: .long, help: "QEMU socket directory path (overrides config file)")
    var qemuSocketDir: String?
    
    @Option(name: .long, help: "Log level (overrides config file)")
    var logLevel: String?
    
    @Option(name: .long, help: "Path to configuration file")
    var configFile: String?
    
    @Flag(name: .long, help: "Enable debug mode")
    var debug: Bool = false
    
    func run() async throws {
        // Set up custom logging with clean timestamps (no timezone suffix)
        LoggingSystem.bootstrap { label in
            var handler = CustomLogHandler(label: label)
            handler.logLevel = debug ? .debug : .info
            return handler
        }
        
        var logger = Logger(label: "strato-agent")
        logger.logLevel = debug ? .debug : .info
        
        // Load configuration from file or defaults
        let config: AgentConfig
        if let configFile = configFile {
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
        
        // Determine the WebSocket URL to use
        let finalWebSocketURL: String
        let isRegistrationMode: Bool
        
        if let regURL = registrationURL {
            // Validate registration URL format
            guard let url = URL(string: regURL),
                  let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
                  let queryItems = components.queryItems,
                  queryItems.contains(where: { $0.name == "token" }),
                  queryItems.contains(where: { $0.name == "name" }) else {
                logger.error("Invalid registration URL format. Must include 'token' and 'name' query parameters.")
                logger.error("Expected format: ws://host:port/agent/register?token=TOKEN&name=AGENT_NAME")
                throw ExitCode.failure
            }
            finalWebSocketURL = regURL
            isRegistrationMode = true
            logger.info("Using registration URL for initial agent registration")
        } else {
            // Use regular control plane URL
            if let cpURL = controlPlaneURL {
                finalWebSocketURL = cpURL
            } else {
                finalWebSocketURL = config.controlPlaneURL
            }
            isRegistrationMode = false
        }
        
        // Override config values with command-line arguments if provided
        let finalQemuSocketDir = qemuSocketDir ?? config.qemuSocketDir ?? "/var/run/qemu"
        let finalLogLevel = logLevel ?? config.logLevel ?? "info"
        let finalAgentID = agentID ?? ProcessInfo.processInfo.hostName
        
        // Update log level based on final configuration
        logger.logLevel = debug ? .debug : Logger.Level(rawValue: finalLogLevel) ?? .info
        
        logger.info("Starting Strato Agent", metadata: [
            "agentID": .string(finalAgentID),
            "webSocketURL": .string(finalWebSocketURL),
            "qemuSocketDir": .string(finalQemuSocketDir),
            "logLevel": .string(finalLogLevel),
            "registrationMode": .string(isRegistrationMode ? "yes" : "no")
        ])
        
        let agent = Agent(
            agentID: finalAgentID,
            webSocketURL: finalWebSocketURL,
            qemuSocketDir: finalQemuSocketDir,
            isRegistrationMode: isRegistrationMode,
            logger: logger
        )
        
        do {
            try await agent.start()
        } catch {
            logger.error("Agent failed to start: \(error)")
            throw ExitCode.failure
        }
    }
}