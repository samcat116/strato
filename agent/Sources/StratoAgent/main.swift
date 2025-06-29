import ArgumentParser
import Foundation
import Logging

@main
struct StratoAgent: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "strato-agent",
        abstract: "Strato hypervisor agent for managing VMs on cloud-hypervisor",
        version: "1.0.0"
    )
    
    @Option(name: .long, help: "Control plane WebSocket URL")
    var controlPlaneURL: String = "ws://localhost:8080/agent/ws"
    
    @Option(name: .long, help: "Agent ID (defaults to hostname)")
    var agentID: String?
    
    @Option(name: .long, help: "Cloud Hypervisor socket path")
    var hypervisorSocket: String = "/var/run/cloud-hypervisor/cloud-hypervisor.sock"
    
    @Option(name: .long, help: "Log level")
    var logLevel: String = "info"
    
    @Flag(name: .long, help: "Enable debug mode")
    var debug: Bool = false
    
    func run() async throws {
        // Set up logging
        var logger = Logger(label: "strato-agent")
        logger.logLevel = debug ? .debug : Logger.Level(rawValue: logLevel) ?? .info
        
        let finalAgentID = agentID ?? ProcessInfo.processInfo.hostName
        
        logger.info("Starting Strato Agent", metadata: [
            "agentID": .string(finalAgentID),
            "controlPlaneURL": .string(controlPlaneURL),
            "hypervisorSocket": .string(hypervisorSocket)
        ])
        
        let agent = Agent(
            agentID: finalAgentID,
            controlPlaneURL: controlPlaneURL,
            hypervisorSocket: hypervisorSocket,
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