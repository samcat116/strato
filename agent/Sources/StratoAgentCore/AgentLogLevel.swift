import Foundation
import Logging

/// The log levels accepted by every strato-agent configuration source.
public enum AgentLogLevel: String, CaseIterable, Equatable, Sendable {
    case trace
    case debug
    case info
    case notice
    case warning
    case error
    case critical

    public init(parsing value: String) throws {
        guard let level = Self(rawValue: value) else {
            throw AgentLogLevelError.invalid(value)
        }
        self = level
    }

    public var loggerLevel: Logger.Level {
        switch self {
        case .trace: .trace
        case .debug: .debug
        case .info: .info
        case .notice: .notice
        case .warning: .warning
        case .error: .error
        case .critical: .critical
        }
    }

    public static func resolve(
        commandLineValue: String?,
        configuredValue: AgentLogLevel?,
        debug: Bool
    ) throws -> AgentLogLevel {
        // Validate an explicit CLI value even when --debug wins precedence.
        let commandLineLevel = try commandLineValue.map(Self.init(parsing:))
        return debug ? .debug : commandLineLevel ?? configuredValue ?? .info
    }
}

public enum AgentLogLevelError: Error, LocalizedError, Equatable, Sendable {
    case invalid(String)

    public var errorDescription: String? {
        switch self {
        case .invalid(let value):
            let supported = AgentLogLevel.allCases.map(\.rawValue).joined(separator: ", ")
            return "log level must be one of \(supported), got '\(value)'"
        }
    }
}

/// Builds every handler at one validated threshold.
public struct AgentLogHandlerFactory: Sendable {
    public let logLevel: AgentLogLevel

    public init(logLevel: AgentLogLevel) {
        self.logLevel = logLevel
    }

    public func makeHandler(label: String) -> CustomLogHandler {
        var handler = CustomLogHandler(label: label)
        handler.logLevel = logLevel.loggerLevel
        return handler
    }

    public func bootstrap() {
        LoggingSystem.bootstrap { label in
            makeHandler(label: label)
        }
    }
}
