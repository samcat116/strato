import Foundation
import Logging
import StratoShared
import Testing
@testable import StratoAgentCore

@Suite("Agent log level")
struct AgentLogLevelTests {
    private static let bootstrapChildEnvironmentKey = "STRATO_AGENT_LOG_LEVEL_BOOTSTRAP_CHILD"
    private static let filteredMessage = "STRATO_AGENT_INFO_MUST_BE_FILTERED"
    private static let visibleMessage = "STRATO_AGENT_WARNING_MUST_BE_VISIBLE"
    private static let childSentinel = "STRATO_AGENT_LOG_LEVEL_BOOTSTRAP_PASSED"
    private static let agentNameMetadata = #""strato.agent.name":"agent-284""#

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

    @Test("The final factory filters plain root, subsystem, and dependency loggers process-wide")
    func appliesProcessWideThreshold() async throws {
        if ProcessInfo.processInfo.environment[Self.bootstrapChildEnvironmentKey] != "1" {
            try await launchIsolatedBootstrapTest()
            return
        }

        let processMetadata = DynamicLogMetadata([
            LogMetadata.Key.serviceName: "strato-agent"
        ])
        let factory = AgentLogHandlerFactory(
            logLevel: .warning,
            metadataProvider: processMetadata.provider)
        factory.bootstrap()
        let root = Logger(label: "strato-agent")
        processMetadata[metadataKey: LogMetadata.Key.agentName] = "agent-284"
        let subsystem = Logger(label: "strato-agent.storage-device-inventory")
        let dependencyLogger = Logger(label: "dependency-created-logger")

        #expect(root.logLevel == .warning)
        #expect(subsystem.logLevel == .warning)
        #expect(dependencyLogger.logLevel == .warning)
        root.info("\(Self.filteredMessage)")
        dependencyLogger.warning("\(Self.visibleMessage)")
        print(Self.childSentinel)
    }

    private func launchIsolatedBootstrapTest() async throws {
        var environment = ProcessInfo.processInfo.environment
        environment[Self.bootstrapChildEnvironmentKey] = "1"
        var arguments = Array(CommandLine.arguments.dropFirst())
        if let filterIndex = arguments.firstIndex(of: "--filter"),
            arguments.indices.contains(filterIndex + 1)
        {
            arguments[filterIndex + 1] = "AgentLogLevelTests.appliesProcessWideThreshold"
        } else {
            arguments.append(
                contentsOf: ["--filter", "AgentLogLevelTests.appliesProcessWideThreshold"])
        }

        let result = try await ProcessRunner.run(
            executableURL: URL(fileURLWithPath: CommandLine.arguments[0]),
            arguments: arguments,
            timeout: .seconds(30),
            environment: environment,
            maxOutputBytes: 1 << 20)
        let output = result.combinedOutput

        try #require(result.terminationStatus == 0, "isolated logging test failed: \(output)")
        #expect(output.contains(Self.childSentinel))
        #expect(output.contains(Self.visibleMessage))
        #expect(output.contains(Self.agentNameMetadata))
        #expect(!output.contains(Self.filteredMessage))
    }
}
