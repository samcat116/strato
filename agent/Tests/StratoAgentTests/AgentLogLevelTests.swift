import InMemoryLogging
import Logging
import StratoShared
import Testing
@testable import StratoAgentCore

@Suite("Agent log level")
struct AgentLogLevelTests {
    @Test("The authoritative parser accepts every supported level", arguments: AgentLogLevel.allCases)
    func parsesSupportedLevel(_ expected: AgentLogLevel) throws {
        #expect(try AgentLogLevel(parsing: expected.rawValue) == expected)
    }

    @Test(
        "The authoritative parser rejects aliases and non-exact values",
        arguments: ["warn", "WARN", "TRACE", " trace", "verbose", ""])
    func rejectsUnsupportedLevel(_ value: String) {
        #expect(throws: AgentLogLevelError.invalid(value)) {
            try AgentLogLevel(parsing: value)
        }
    }

    @Test(
        "CLI log levels resolve through the authoritative parser",
        arguments: [AgentLogLevel.trace, .info, .warning])
    func resolvesCommandLineLevel(_ expected: AgentLogLevel) throws {
        let resolved = try AgentLogLevel.resolve(
            commandLineValue: expected.rawValue,
            configuredValue: .critical,
            debug: false)

        #expect(resolved == expected)
    }

    @Test("Invalid CLI input fails even when the debug flag would take precedence")
    func rejectsInvalidCommandLineLevelWithDebug() {
        #expect(throws: AgentLogLevelError.invalid("verbose")) {
            try AgentLogLevel.resolve(
                commandLineValue: "verbose",
                configuredValue: .warning,
                debug: true)
        }
    }

    @Test("The debug flag retains precedence over a valid configured threshold")
    func debugFlagOverridesConfiguredLevel() throws {
        let resolved = try AgentLogLevel.resolve(
            commandLineValue: "warning",
            configuredValue: .critical,
            debug: true)

        #expect(resolved == .debug)
    }

    @Test("The final factory filters every isolated logger at the configured threshold")
    func appliesConfiguredThreshold() {
        let processMetadata = DynamicLogMetadata([
            LogMetadata.Key.serviceName: "strato-agent"
        ])
        let factory = AgentLogHandlerFactory(
            logLevel: .warning,
            metadataProvider: processMetadata.provider)
        let handler = InMemoryLogHandler()
        var configuredHandler = handler
        factory.configure(&configuredHandler)

        let labels = [
            "strato-agent",
            "strato-agent.storage-device-inventory",
            "dependency-created-logger",
        ]
        let loggers = labels.map { label in
            Logger(label: label) { _ in configuredHandler }
        }
        processMetadata[metadataKey: LogMetadata.Key.agentName] = "agent-284"

        for logger in loggers {
            #expect(logger.logLevel == .warning)
            logger.info("filtered")
        }
        loggers[2].warning("visible")

        #expect(handler.entries.count == 1)
        #expect(handler.entries.first?.level == .warning)
        #expect(handler.entries.first?.message == "visible")
        #expect(handler.entries.first?.metadata[LogMetadata.Key.serviceName] == "strato-agent")
        #expect(handler.entries.first?.metadata[LogMetadata.Key.agentName] == "agent-284")
    }
}
