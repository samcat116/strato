import Foundation
import StratoShared

public struct BoundedHostCommand: Sendable, Equatable {
    public let executable: String
    public let arguments: [String]
    public let timeout: Duration
    public let outputLimitBytes: Int

    public init(
        executable: String,
        arguments: [String],
        timeout: Duration = .seconds(5),
        outputLimitBytes: Int = 64 * 1024
    ) throws {
        guard executable.hasPrefix("/") else {
            throw BoundedHostCommandError.executableMustBeAbsolute(executable)
        }
        self.executable = executable
        self.arguments = arguments
        self.timeout = timeout
        self.outputLimitBytes = max(1, outputLimitBytes)
    }
}

public enum BoundedHostCommandError: Error, Equatable, CustomStringConvertible {
    case executableMustBeAbsolute(String)
    case outputLimitExceeded(Int)

    public var description: String {
        switch self {
        case .executableMustBeAbsolute(let executable):
            return "dependency commands require an absolute executable, got \(executable)"
        case .outputLimitExceeded(let limit):
            return "dependency command output exceeded \(limit) bytes"
        }
    }
}

public protocol NodeDependencyCommandExecuting: Sendable {
    func execute(_ command: BoundedHostCommand) async throws -> ProcessResult
}

public struct NodeDependencyCommandExecutor: NodeDependencyCommandExecuting {
    public init() {}

    public func execute(_ command: BoundedHostCommand) async throws -> ProcessResult {
        do {
            return try await ProcessRunner.run(
                executableURL: URL(fileURLWithPath: command.executable),
                arguments: command.arguments,
                timeout: command.timeout,
                maxOutputBytes: command.outputLimitBytes)
        } catch ProcessRunnerError.outputLimitExceeded {
            throw BoundedHostCommandError.outputLimitExceeded(command.outputLimitBytes)
        }
    }
}

public struct SystemdUnitObservation: Sendable, Equatable {
    public let name: String
    public let loadState: String
    public let activeState: String
    public let subState: String
    public let unitFileState: String

    public init(name: String, loadState: String, activeState: String, subState: String, unitFileState: String) {
        self.name = name
        self.loadState = loadState
        self.activeState = activeState
        self.subState = subState
        self.unitFileState = unitFileState
    }

    public var supervisorState: NodeDependencySupervisorState {
        switch loadState {
        case "not-found":
            return .missing
        case "unknown":
            // The host adapter synthesizes this value when systemctl fails or
            // its output cannot be parsed. It is not evidence about the unit.
            return .unknown
        case "masked", "bad-setting", "error":
            // systemd returned a definitive load failure. Preserve it as a
            // categorical local-unit failure instead of confusing it with
            // failed inspection.
            return .failed
        case "loaded":
            switch activeState {
            case "active": return .active
            case "activating", "reloading": return .activating
            case "failed": return .failed
            case "inactive", "deactivating": return .inactive
            default: return .unknown
            }
        default:
            // Other states such as stub or merged do not by themselves prove
            // that the local service failed.
            return .unknown
        }
    }
}

public protocol SystemdControlling: Sendable {
    func inspect(unit: String) async -> SystemdUnitObservation
    func discoverFirst(units: [String]) async -> SystemdUnitObservation
    func enable(unit: String) async throws
    func start(unit: String) async throws
    func restart(unit: String) async throws
}

public struct SystemdOperationError: Error, Sendable, CustomStringConvertible {
    public let detail: String
    public var description: String { detail }
}

public struct SystemdHostAdapter: SystemdControlling {
    public static let defaultExecutable = "/usr/bin/systemctl"
    private let executor: any NodeDependencyCommandExecuting
    private let executable: String

    public init(
        executor: any NodeDependencyCommandExecuting = NodeDependencyCommandExecutor(),
        executable: String = defaultExecutable
    ) {
        self.executor = executor
        self.executable = executable
    }

    public func inspect(unit: String) async -> SystemdUnitObservation {
        do {
            let command = try BoundedHostCommand(
                executable: executable,
                arguments: [
                    "show", unit,
                    "--property=LoadState", "--property=ActiveState",
                    "--property=SubState", "--property=UnitFileState",
                ])
            let result = try await executor.execute(command)
            let output = String(data: result.standardOutput, encoding: .utf8) ?? ""
            return Self.parse(unit: unit, output: output)
                ?? SystemdUnitObservation(
                    name: unit, loadState: "unknown", activeState: "unknown",
                    subState: "unknown", unitFileState: "unknown")
        } catch {
            return SystemdUnitObservation(
                name: unit, loadState: "unknown", activeState: "unknown",
                subState: "unknown", unitFileState: "unknown")
        }
    }

    public func discoverFirst(units: [String]) async -> SystemdUnitObservation {
        var firstLoaded: SystemdUnitObservation?
        var firstLoadFailure: SystemdUnitObservation?
        var firstUnknown: SystemdUnitObservation?
        for unit in units {
            let observation = await inspect(unit: unit)
            if observation.loadState == "loaded" {
                if observation.supervisorState == .active { return observation }
                if firstLoaded == nil { firstLoaded = observation }
            } else if observation.supervisorState == .failed, firstLoadFailure == nil {
                firstLoadFailure = observation
            } else if observation.supervisorState == .unknown, firstUnknown == nil {
                firstUnknown = observation
            }
        }
        if let firstLoaded { return firstLoaded }
        if let firstLoadFailure { return firstLoadFailure }
        if let firstUnknown { return firstUnknown }
        return SystemdUnitObservation(
            name: units.first ?? "unknown", loadState: "not-found", activeState: "inactive",
            subState: "dead", unitFileState: "unknown")
    }

    public func enable(unit: String) async throws { try await run(["enable", unit]) }
    public func start(unit: String) async throws { try await run(["start", unit]) }
    public func restart(unit: String) async throws { try await run(["restart", unit]) }

    private func run(_ arguments: [String]) async throws {
        let result = try await executor.execute(
            try BoundedHostCommand(executable: executable, arguments: arguments, timeout: .seconds(30)))
        guard result.terminationStatus == 0 else {
            throw SystemdOperationError(
                detail: result.combinedOutput.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    public static func parse(unit: String, output: String) -> SystemdUnitObservation? {
        var values: [String: String] = [:]
        for line in output.split(separator: "\n", omittingEmptySubsequences: false) {
            guard let separator = line.firstIndex(of: "=") else { continue }
            values[String(line[..<separator])] = String(line[line.index(after: separator)...])
        }
        guard let load = values["LoadState"], let active = values["ActiveState"] else { return nil }
        return SystemdUnitObservation(
            name: unit, loadState: load, activeState: active,
            subState: values["SubState"] ?? "unknown",
            unitFileState: values["UnitFileState"] ?? "unknown")
    }
}

/// Cache for expensive version probes. Functional probes remain live; modules
/// use this only for information that cannot change without a package upgrade.
public actor NodeDependencyProbeCache<Value: Sendable> {
    private var cached: (value: Value, at: Date)?

    public init() {}

    public func value(
        maxAge: TimeInterval,
        now: Date = Date(),
        load: @Sendable () async -> Value
    ) async -> Value {
        if let cached, now.timeIntervalSince(cached.at) < maxAge { return cached.value }
        let value = await load()
        cached = (value, now)
        return value
    }
}
