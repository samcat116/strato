import StratoShared
import Vapor

/// Resolves the release artifact an agent should self-update to (issue #432).
///
/// Issue #431 (a machine-readable release manifest) has not landed yet, so
/// artifacts are resolved by the same URL convention `deploy/agent/install.sh`
/// downloads from: `<base>/<tag>/strato-<os>-<arch>.tar.gz`, each with a
/// `.sha256` sidecar the release workflow publishes alongside it. The sidecar
/// is fetched at dispatch time so the checksum always matches the exact asset
/// the agent will download. When a manifest exists this type is the one place
/// to swap the resolution strategy.
///
/// `AGENT_UPDATE_ARTIFACT_BASE_URL` overrides the base for mirrors or
/// air-gapped deployments that re-host the assets under the same naming
/// scheme; deployments that can't are served by the endpoint's explicit
/// `artifactUrl`/`sha256` request override instead.
enum AgentUpdateArtifacts {
    static let defaultBaseURL = "https://github.com/samcat116/strato/releases/download"

    static var baseURL: String {
        Environment.get("AGENT_UPDATE_ARTIFACT_BASE_URL") ?? defaultBaseURL
    }

    /// The release tag a version travels under. Tags are v-prefixed
    /// (`v1.2.3`) but the configured target may arrive bare (`1.2.3`, the
    /// semver image-tag form Helm feeds back as STRATO_VERSION) — collapse
    /// both to the tagged form. Non-semver values (e.g. "main") pass through
    /// and are rejected by `assetURL` below, since main-branch builds publish
    /// container images, not release tarballs.
    static func releaseTag(for version: String) -> String {
        if version.first?.isNumber == true {
            return "v\(version)"
        }
        return version
    }

    /// The published asset URL for a target version on a given host platform,
    /// or nil when the target has no release assets (main/dev builds) — the
    /// caller then requires an explicit artifact override.
    static func assetURL(
        targetVersion: String,
        operatingSystem: OperatingSystem,
        architecture: CPUArchitecture,
        baseURL: String? = nil
    ) -> String? {
        guard AgentVersionTarget.canonical(targetVersion) != "main" else { return nil }
        let base = (baseURL ?? Self.baseURL)
        let trimmedBase = base.hasSuffix("/") ? String(base.dropLast()) : base
        let asset = "strato-\(operatingSystem.rawValue)-\(architecture.rawValue).tar.gz"
        return "\(trimmedBase)/\(releaseTag(for: targetVersion))/\(asset)"
    }

    /// Extracts the digest from a `.sha256` sidecar body (`<hex>  <filename>`,
    /// the `sha256sum` format install.sh verifies with). Nil when the body
    /// doesn't lead with a 64-char hex digest.
    static func parseChecksum(_ body: String) -> String? {
        let token =
            body
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: \.isWhitespace)
            .first
            .map(String.init)?
            .lowercased()
        guard let token, token.count == 64, token.allSatisfy(\.isHexDigit) else { return nil }
        return token
    }

    /// Fetches and parses the `.sha256` sidecar for an asset URL.
    static func fetchChecksum(forAssetAt assetURL: String, client: any Client) async throws -> String {
        let checksumURL = assetURL + ".sha256"
        let response: ClientResponse
        do {
            response = try await client.get(URI(string: checksumURL))
        } catch {
            throw Abort(
                .badGateway,
                reason: "Could not fetch the artifact checksum from \(checksumURL): \(error)")
        }
        guard response.status == .ok else {
            throw Abort(
                .badGateway,
                reason:
                    "Could not fetch the artifact checksum (HTTP \(response.status.code) from \(checksumURL)); does the release publish this asset?"
            )
        }
        let body = response.body.map { String(buffer: $0) } ?? ""
        guard let digest = parseChecksum(body) else {
            throw Abort(
                .badGateway,
                reason: "The checksum sidecar at \(checksumURL) did not contain a SHA-256 digest")
        }
        return digest
    }
}
