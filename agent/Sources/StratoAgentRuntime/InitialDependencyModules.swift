import Foundation
import StratoAgentCore

/// Parses cached installed-version probes for the initial dependency modules.
/// Callers supply a fixed executable allowlist; configuration cannot add one.
enum DependencyVersionProbe {
    static func version(
        candidates: [String],
        arguments: [String] = ["--version"],
        executor: any NodeDependencyCommandExecuting = NodeDependencyCommandExecutor()
    ) async -> String? {
        guard let executable = candidates.first(where: FileManager.default.isExecutableFile(atPath:)) else {
            return nil
        }
        do {
            let result = try await executor.execute(
                try BoundedHostCommand(
                    executable: executable, arguments: arguments,
                    timeout: .seconds(5), outputLimitBytes: 16 * 1024))
            guard result.terminationStatus == 0 else { return nil }
            return parse(result.combinedOutput)
        } catch {
            return nil
        }
    }

    static func parse(_ output: String) -> String? {
        for token in output.split(whereSeparator: { $0.isWhitespace || $0 == "," || $0 == ")" || $0 == "(" }) {
            let value = token.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
            let components = value.split(separator: ".", omittingEmptySubsequences: false)
            if (2...4).contains(components.count), components.allSatisfy({ Int($0) != nil }) {
                return value
            }
        }
        return nil
    }
}
