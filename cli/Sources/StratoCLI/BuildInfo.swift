import Foundation

/// Build-time identity of this CLI binary, mirroring the agent's `BuildInfo`:
/// CI overwrites `CompiledBuildInfo.swift` at release time; local dev builds
/// fall back to sentinels.
enum BuildInfo {
    static let version: String =
        ProcessInfo.processInfo.environment["STRATO_VERSION"]
        ?? CompiledBuildInfo.version
        ?? "dev"

    static let gitSHA: String =
        ProcessInfo.processInfo.environment["STRATO_GIT_SHA"]
        ?? CompiledBuildInfo.gitSHA
        ?? "unknown"

    static var displayVersion: String {
        gitSHA == "unknown" ? version : "\(version) (\(gitSHA))"
    }
}
