import Foundation

/// Injectable execution contract: each operation supplies both resource ceilings.
public typealias SubprocessRunner =
    @Sendable (_ executableURL: URL, _ arguments: [String], _ budget: SubprocessBudget) async throws -> ProcessResult

/// Command-family policy for storage and provisioning; see storage.md for rationale.
public struct SubprocessBudget: Sendable, Equatable {
    public let timeout: Duration
    public let maxOutputBytes: Int

    public init(timeout: Duration, maxOutputBytes: Int = 1 << 20) {
        precondition(timeout > .zero && maxOutputBytes > 0)
        self.timeout = timeout
        self.maxOutputBytes = maxOutputBytes
    }

    public static let inspection = Self(timeout: .seconds(30))
    public static let mutation = Self(timeout: .seconds(120))
    public static let varstore = Self(timeout: .seconds(StageBudget.varstoreMaterializationSeconds))
    public static let cloudInit = Self(timeout: .seconds(120))
    public static let updateProbe = Self(timeout: .seconds(30), maxOutputBytes: 64 << 10)

    /// Five minutes setup plus one second per MiB (a conservative 1 MiB/s),
    /// capped at one day. Unknown-size remote copies get a one-hour runway.
    public static func imageWork(bytes: Int64?) -> Self {
        guard let bytes else { return Self(timeout: .seconds(3600)) }
        let mib = max(0, bytes) / (1 << 20)
        return Self(timeout: .seconds(min(86400, 300 + mib)))
    }

    static func fileBytes(_ path: String) -> Int64? {
        ProcessRunner.fileSize(atPath: path)
    }

    static func storage(executable: URL, arguments: [String]) -> Self {
        let tool = executable.lastPathComponent
        if tool == "qemu-img" {
            if arguments.first == "convert" {
                return imageWork(bytes: arguments.dropLast().last.flatMap(fileBytes))
            }
            if ["info", "bench"].contains(arguments.first ?? "") { return .inspection }
        }
        if tool == "rbd" {
            if let index = arguments.firstIndex(of: "import"), arguments.indices.contains(index + 1) {
                return imageWork(bytes: fileBytes(arguments[index + 1]))
            }
            if arguments.contains("cp") || arguments.contains("flatten") { return imageWork(bytes: nil) }
            if arguments.contains("info") || arguments.contains("list") || arguments.contains("ls") {
                return .inspection
            }
        }
        return .mutation
    }

    @Sendable public static func run(
        _ executable: URL, _ arguments: [String], _ budget: Self
    ) async throws -> ProcessResult {
        try await ProcessRunner.run(
            executableURL: executable, arguments: arguments,
            timeout: budget.timeout, maxOutputBytes: budget.maxOutputBytes)
    }

    /// Exit observation for a direct child does not prove its descendants have
    /// stopped using files. Conservatively retain inputs and staging after any
    /// watchdog/output abort; a retry uses fresh staging, never reclaims it.
    static func preserveStaging(after error: any Error) -> Bool {
        error is ProcessTimedOutError || error is ProcessRunnerError || error is CancellationError
    }
}

extension ProcessTimedOutError: ClassifiableError {
    public var failureClassification: FailureClassification { .transient }
}

extension ProcessRunnerError: ClassifiableError {
    public var failureClassification: FailureClassification { .transient }
}

/// Repair must establish that no builder uses this staging before removing it.
struct SubprocessStagingBlockedError: Error, LocalizedError, ClassifiableError {
    let path: String
    var failureClassification: FailureClassification { .blocked }
    var errorDescription: String? {
        "Process termination is unconfirmed for staging at \(path); verify the builder has stopped before removing staging and retrying."
    }
}
