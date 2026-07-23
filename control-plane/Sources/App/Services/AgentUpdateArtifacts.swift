import Foundation
import StratoShared
import Vapor

/// The per-release `agent-manifest.json` the release workflow publishes
/// alongside the binary tarballs (issue #431): the machine-readable pointer to
/// each platform's asset URL, checksum, and the tarball member holding the
/// agent binary.
struct AgentReleaseManifest: Decodable {
    struct Asset: Decodable {
        let os: String
        let arch: String
        let asset: String
        let url: String
        let sha256: String
        let size: Int64?
        /// Tarball member to extract; names the member explicitly so an
        /// asset-shape change is just a manifest change.
        let agentBinaryPath: String?
    }

    let schemaVersion: Int
    let version: String
    let assets: [Asset]
}

/// Everything the update command needs to hand an agent.
struct ResolvedAgentArtifact: Equatable {
    let url: String
    let sha256: String
    let kind: AgentUpdateArtifactKind
    /// Member to extract when `kind == .tarball`; ignored for bare binaries.
    let tarballMember: String
}

/// The seam through which release artifacts are resolved for an agent update,
/// at rollout-assignment time (the auto-update sweep) and sync-assembly time
/// (`DesiredStateAssembler`). A value wrapping one closure so tests can
/// substitute a stub without a release host; production resolves via
/// `AgentUpdateArtifacts.resolveArtifact`.
struct AgentArtifactResolver: Sendable {
    private let resolveArtifact:
        @Sendable (String, OperatingSystem, CPUArchitecture) async throws -> ResolvedAgentArtifact

    init(
        _ resolveArtifact:
            @escaping @Sendable (String, OperatingSystem, CPUArchitecture) async throws -> ResolvedAgentArtifact
    ) {
        self.resolveArtifact = resolveArtifact
    }

    func resolve(
        version: String, operatingSystem: OperatingSystem, architecture: CPUArchitecture
    ) async throws -> ResolvedAgentArtifact {
        try await resolveArtifact(version, operatingSystem, architecture)
    }
}

extension Application {
    private struct AgentArtifactResolverKey: StorageKey {
        typealias Value = AgentArtifactResolver
    }

    /// The release-artifact resolver shared by the auto-update sweep and the
    /// desired-state assembler — one seam, so an assignment can never resolve
    /// differently from the sync that carries it. Defaults to the real release
    /// host; tests assign a stub.
    var agentArtifactResolver: AgentArtifactResolver {
        get {
            storage[AgentArtifactResolverKey.self]
                ?? AgentArtifactResolver { version, operatingSystem, architecture in
                    try await AgentUpdateArtifacts.resolveArtifact(
                        targetVersion: version,
                        operatingSystem: operatingSystem,
                        architecture: architecture,
                        client: self.client,
                        logger: self.logger)
                }
        }
        set {
            storage[AgentArtifactResolverKey.self] = newValue
        }
    }
}

/// Resolves the release artifact an agent should self-update to (issue #432).
///
/// Primary source: the release's `agent-manifest.json` (issue #431), fetched
/// at dispatch time so URL and checksum always describe the exact asset the
/// agent will download. Releases that predate the manifest fall back to the
/// same URL convention `deploy/agent/install.sh` downloads from —
/// `<base>/<tag>/strato-<os>-<arch>.tar.gz` with a `.sha256` sidecar.
///
/// `AGENT_UPDATE_ARTIFACT_BASE_URL` overrides the base for mirrors or
/// air-gapped deployments that re-host the assets (and a rewritten manifest)
/// under the same naming scheme; deployments that can't are served by the
/// endpoint's explicit `artifactUrl`/`sha256` request override instead.
enum AgentUpdateArtifacts {
    static let defaultBaseURL = "https://github.com/samcat116/strato/releases/download"

    static var baseURL: String {
        Environment.get("AGENT_UPDATE_ARTIFACT_BASE_URL") ?? defaultBaseURL
    }

    static let defaultTarballMember = "strato-agent"

    /// The release tag a version travels under. Tags are v-prefixed
    /// (`v1.2.3`) but the configured target may arrive bare (`1.2.3`, the
    /// semver image-tag form Helm feeds back as STRATO_VERSION) — collapse
    /// both to the tagged form. Non-semver values (e.g. "main") pass through
    /// and are rejected by the URL builders below, since main-branch builds
    /// publish container images, not release tarballs.
    static func releaseTag(for version: String) -> String {
        if version.first?.isNumber == true {
            return "v\(version)"
        }
        return version
    }

    /// True when a target has no release assets at all (main/dev builds) —
    /// the caller then requires an explicit artifact override.
    static func hasReleaseAssets(targetVersion: String) -> Bool {
        AgentVersionTarget.canonical(targetVersion) != "main"
    }

    private static func trimmedBase(_ baseURL: String?) -> String {
        let base = baseURL ?? Self.baseURL
        return base.hasSuffix("/") ? String(base.dropLast()) : base
    }

    /// The `agent-manifest.json` URL for a target version, or nil when the
    /// target has no release assets.
    static func manifestURL(targetVersion: String, baseURL: String? = nil) -> String? {
        guard hasReleaseAssets(targetVersion: targetVersion) else { return nil }
        return "\(trimmedBase(baseURL))/\(releaseTag(for: targetVersion))/agent-manifest.json"
    }

    /// The convention-derived asset URL for a target version on a given host
    /// platform (the pre-manifest fallback), or nil when the target has no
    /// release assets.
    static func assetURL(
        targetVersion: String,
        operatingSystem: OperatingSystem,
        architecture: CPUArchitecture,
        baseURL: String? = nil
    ) -> String? {
        guard hasReleaseAssets(targetVersion: targetVersion) else { return nil }
        let asset = "strato-\(operatingSystem.rawValue)-\(architecture.rawValue).tar.gz"
        return "\(trimmedBase(baseURL))/\(releaseTag(for: targetVersion))/\(asset)"
    }

    /// Picks the manifest asset for a host platform. Nil when the release
    /// publishes no asset for that OS/arch pair.
    static func selectAsset(
        from manifest: AgentReleaseManifest,
        operatingSystem: OperatingSystem,
        architecture: CPUArchitecture
    ) -> ResolvedAgentArtifact? {
        guard
            let asset = manifest.assets.first(where: {
                $0.os == operatingSystem.rawValue && $0.arch == architecture.rawValue
            }),
            let digest = parseChecksum(asset.sha256)
        else { return nil }
        return ResolvedAgentArtifact(
            url: asset.url,
            sha256: digest,
            kind: .tarball,
            tarballMember: asset.agentBinaryPath ?? defaultTarballMember
        )
    }

    /// Extracts the digest from a `.sha256` sidecar body (`<hex>  <filename>`,
    /// the `sha256sum` format install.sh verifies with) or a bare manifest
    /// digest. Nil when the body doesn't lead with a 64-char hex digest.
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

    /// How many redirects an artifact-metadata fetch may follow.
    private static let maxRedirects = 5

    /// GET a release-metadata URL, following redirects explicitly.
    ///
    /// The shared client has redirect-following disabled globally (see
    /// `configure`) so that tenant-influenced fetches can't be steered at
    /// internal addresses by a 3xx. These two fetches are neither tenant-
    /// influenced nor optional: the base URL is operator configuration
    /// (`AGENT_UPDATE_ARTIFACT_BASE_URL`, defaulting to the project's GitHub
    /// releases), and GitHub *always* answers a release download with a 302 to
    /// its asset CDN. Without following it the manifest read sees a 302, falls
    /// through to the pre-manifest convention path, and the checksum sidecar
    /// then fails outright — agent updates stop resolving entirely.
    ///
    /// Bounded, and restricted to http(s) so a redirect can't pivot to another
    /// scheme. No credentials are attached to these requests, so following a
    /// redirect leaks nothing.
    static func getFollowingRedirects(
        _ url: String,
        client: any Client,
        logger: Logger
    ) async throws -> ClientResponse {
        var currentURL = url
        for _ in 0...maxRedirects {
            let response = try await client.get(URI(string: currentURL))
            guard (300..<400).contains(response.status.code),
                let location = response.headers.first(name: .location)
            else {
                return response
            }
            guard let resolved = URL(string: location, relativeTo: URL(string: currentURL)),
                let scheme = resolved.scheme?.lowercased(),
                scheme == "http" || scheme == "https"
            else {
                throw Abort(
                    .badGateway,
                    reason: "Release metadata at \(currentURL) redirected to an unsupported location")
            }
            logger.debug(
                "Following release metadata redirect",
                metadata: [
                    "from": .string(currentURL),
                    "status": .stringConvertible(response.status.code),
                ])
            currentURL = resolved.absoluteString
        }
        throw Abort(
            .badGateway,
            reason: "Release metadata at \(url) exceeded \(maxRedirects) redirects")
    }

    /// Resolves the artifact for a target version and host platform:
    /// manifest first, convention + sidecar for releases that predate it.
    static func resolveArtifact(
        targetVersion: String,
        operatingSystem: OperatingSystem,
        architecture: CPUArchitecture,
        client: any Client,
        logger: Logger
    ) async throws -> ResolvedAgentArtifact {
        guard let manifestURL = manifestURL(targetVersion: targetVersion) else {
            throw Abort(
                .badRequest,
                reason:
                    "Target version '\(targetVersion)' has no published release assets (main-branch builds ship as container images). Pass artifactUrl and sha256 explicitly."
            )
        }

        let manifestResponse: ClientResponse
        do {
            manifestResponse = try await getFollowingRedirects(
                manifestURL, client: client, logger: logger)
        } catch {
            throw Abort(
                .badGateway,
                reason: "Could not fetch the release manifest from \(manifestURL): \(error)")
        }

        if manifestResponse.status == .ok {
            let body = manifestResponse.body.map { Data(buffer: $0) } ?? Data()
            let manifest: AgentReleaseManifest
            do {
                manifest = try JSONDecoder().decode(AgentReleaseManifest.self, from: body)
            } catch {
                throw Abort(
                    .badGateway,
                    reason: "The release manifest at \(manifestURL) did not parse: \(error)")
            }
            guard
                let resolved = selectAsset(
                    from: manifest, operatingSystem: operatingSystem, architecture: architecture)
            else {
                throw Abort(
                    .badGateway,
                    reason:
                        "Release \(manifest.version) publishes no asset for \(operatingSystem.rawValue)/\(architecture.rawValue). Pass artifactUrl and sha256 to override."
                )
            }
            return resolved
        }

        // Releases published before the manifest existed still have the
        // per-asset .sha256 sidecars — resolve by naming convention instead.
        logger.info(
            "Release manifest unavailable; falling back to asset-name convention",
            metadata: [
                "manifestUrl": .string(manifestURL),
                "status": .stringConvertible(manifestResponse.status.code),
            ])
        guard
            let assetURL = assetURL(
                targetVersion: targetVersion, operatingSystem: operatingSystem,
                architecture: architecture)
        else {
            // Unreachable: manifestURL above already gated on hasReleaseAssets.
            throw Abort(.badRequest, reason: "Target version '\(targetVersion)' has no release assets")
        }
        let sha256 = try await fetchChecksum(forAssetAt: assetURL, client: client, logger: logger)
        return ResolvedAgentArtifact(
            url: assetURL, sha256: sha256, kind: .tarball, tarballMember: defaultTarballMember)
    }

    /// Fetches and parses the `.sha256` sidecar for an asset URL.
    static func fetchChecksum(
        forAssetAt assetURL: String, client: any Client, logger: Logger
    ) async throws -> String {
        let checksumURL = assetURL + ".sha256"
        let response: ClientResponse
        do {
            response = try await getFollowingRedirects(checksumURL, client: client, logger: logger)
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
