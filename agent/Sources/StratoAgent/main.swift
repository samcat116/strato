import ArgumentParser
import Foundation
import Logging

struct StratoAgent: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "strato-agent",
        abstract: "Strato hypervisor agent for managing VMs on QEMU",
        version: "1.0.0"
    )
    
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
    
    @Flag(name: .long, help: "Enable debug mode")
    var debug: Bool = false
    
    func run() async throws {
        // Set up initial logging
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
        
        // Override config values with command-line arguments if provided
        let finalControlPlaneURL = controlPlaneURL ?? config.controlPlaneURL
        let finalQemuSocketDir = qemuSocketDir ?? config.qemuSocketDir ?? "/var/run/qemu"
        let finalLogLevel = logLevel ?? config.logLevel ?? "info"
        let finalAgentID = agentID ?? ProcessInfo.processInfo.hostName
        
        // Update log level based on final configuration
        logger.logLevel = debug ? .debug : Logger.Level(rawValue: finalLogLevel) ?? .info
        
        logger.info("Starting Strato Agent", metadata: [
            "agentID": .string(finalAgentID),
            "controlPlaneURL": .string(finalControlPlaneURL),
            "qemuSocketDir": .string(finalQemuSocketDir),
            "logLevel": .string(finalLogLevel)
        ])
        
        let agent = Agent(
            agentID: finalAgentID,
            controlPlaneURL: finalControlPlaneURL,
            qemuSocketDir: finalQemuSocketDir,
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

// Entry point
StratoAgent.main()