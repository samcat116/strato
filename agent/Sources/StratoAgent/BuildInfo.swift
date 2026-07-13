import Foundation

/// Build-time identity of this agent binary.
///
/// Mirrors the control plane's `BuildInfo`, with one addition: container
/// images inject `STRATO_VERSION` / `STRATO_GIT_SHA` as environment variables
/// at image build, but the release-tarball binaries run outside any image, so
/// CI also compiles the values in via `CompiledBuildInfo`. A local dev build
/// has neither and falls back to sentinel values so registration never sends
/// an empty identity.
enum BuildInfo {
    /// Human-readable version (e.g. a git tag or "main"). "dev" when unset.
    static let version: String =
        ProcessInfo.processInfo.environment["STRATO_VERSION"]
        ?? CompiledBuildInfo.version
        ?? "dev"

    /// Git commit SHA the binary was built from. "unknown" when unset.
    static let gitSHA: String =
        ProcessInfo.processInfo.environment["STRATO_GIT_SHA"]
        ?? CompiledBuildInfo.gitSHA
        ?? "unknown"

    /// What `strato-agent --version` prints: the version, plus the commit SHA
    /// when one is known.
    static var displayVersion: String {
        gitSHA == "unknown" ? version : "\(version) (\(gitSHA))"
    }
}
