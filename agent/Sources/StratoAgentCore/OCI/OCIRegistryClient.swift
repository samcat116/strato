import Crypto
import Foundation
import Logging
import StratoShared

/// Agent-side OCI distribution client (issue #418): resolves a reference to a
/// single-platform manifest and fetches its blobs, speaking the distribution
/// auth flow (Docker Hub, GHCR, and any distribution-spec registry).
///
/// The agent-side twin of the control plane's `DistributionRegistryClient` —
/// same challenge parsing, token endpoint handling, and insecure-realm guard —
/// but consuming the short-lived `RegistryCredential` from
/// `DesiredSandboxState` instead of stored secrets, and extended with what
/// pulling actually needs: index → platform narrowing, digest-verified blob
/// downloads, and `ImageCacheService`-style transient-failure retries.
///
/// Credentials are used for the pull and never persisted; the only state kept
/// across calls is an in-memory cache of registry-minted pull tokens.
public actor OCIRegistryClient {
    public struct Configuration: Sendable {
        /// Attempts per network operation before giving up (matches
        /// `ImageCacheService.maxDownloadAttempts`).
        public var maxAttempts = 3
        /// Backoff before retry N is `retryBaseDelay * 2^(N-2)`: 2s, 4s.
        /// Injectable so tests don't sleep.
        public var retryBaseDelay: Duration = .seconds(2)
        /// Redirect hops to follow per request (registries bounce blob
        /// downloads to CDNs; one hop is typical).
        public var maxRedirects = 5

        public init() {}
    }

    /// A reference resolved all the way to the single-platform manifest this
    /// host would run.
    public struct ResolvedImage: Sendable {
        public let manifest: OCIManifest
        /// Digest of the platform manifest *document* — content-addresses the
        /// flattened image, so it is the rootfs cache key. When the reference
        /// pointed at an index, this is the selected entry's digest, not the
        /// index digest.
        public let manifestDigest: String

        public init(manifest: OCIManifest, manifestDigest: String) {
            self.manifest = manifest
            self.manifestDigest = manifestDigest
        }
    }

    private struct MintedToken {
        let value: String
        let expiresAt: Date
    }

    /// Registries occasionally omit `expires_in`; the spec's documented
    /// default is 60 seconds.
    private static let defaultTokenLifetime: TimeInterval = 60
    /// A cached token is considered dead this long before its real expiry.
    private static let tokenExpiryMargin: TimeInterval = 30

    private let transport: any OCIHTTPTransport
    private let logger: Logger
    private let configuration: Configuration
    private var tokenCache: [String: MintedToken] = [:]

    public init(
        transport: any OCIHTTPTransport = URLSessionOCITransport(),
        logger: Logger,
        configuration: Configuration = Configuration()
    ) {
        self.transport = transport
        self.logger = logger
        self.configuration = configuration
    }

    // MARK: - Manifest resolution

    /// Fetches the manifest for `ref`, narrowing a multi-platform index to
    /// this host's platform. Every manifest document is verified against the
    /// digest that named it (the pinned digest from the reference, or the
    /// index entry's digest); tag-addressed fetches trust the computed hash of
    /// the served bytes, which *defines* their digest.
    public func resolveManifest(
        for ref: OCIImageReference,
        architecture: CPUArchitecture = .current,
        credential: RegistryCredential? = nil
    ) async throws -> ResolvedImage {
        let document = try await fetchManifestDocument(
            reference: ref.manifestReference, expectedDigest: ref.digest, ref: ref, credential: credential)

        if isIndexDocument(document) {
            guard let index = try? JSONDecoder().decode(OCIIndex.self, from: document.body) else {
                throw OCIError.malformedResponse(detail: "undecodable image index for \(ref.repository)")
            }
            // Attestation/SBOM entries carry os "unknown" and never match.
            guard let entry = index.manifests.first(where: { $0.platform?.matches(architecture) ?? false })
            else {
                throw OCIError.noMatchingPlatform(
                    reference: "\(ref.repository):\(ref.tag)", architecture: architecture.rawValue)
            }
            guard OCIImageReference.isValidDigest(entry.digest) else {
                throw OCIError.malformedResponse(
                    detail: "index entry for \(ref.repository) has malformed digest \(entry.digest)")
            }
            let platformDocument = try await fetchManifestDocument(
                reference: entry.digest, expectedDigest: entry.digest, ref: ref, credential: credential)
            let manifest = try decodeManifest(platformDocument, ref: ref)
            return ResolvedImage(manifest: manifest, manifestDigest: entry.digest)
        }

        let manifest = try decodeManifest(document, ref: ref)
        return ResolvedImage(manifest: manifest, manifestDigest: document.digest)
    }

    private struct ManifestDocument {
        let body: Data
        let digest: String
        let contentType: String?
    }

    private func fetchManifestDocument(
        reference: String, expectedDigest: String?, ref: OCIImageReference, credential: RegistryCredential?
    ) async throws -> ManifestDocument {
        guard let url = URL(string: "\(ref.apiBaseURL)/v2/\(ref.repository)/manifests/\(reference)") else {
            throw OCIError.invalidReference("\(ref.repository)@\(reference)")
        }
        let request = OCIHTTPRequest(
            url: url,
            headers: ["Accept": OCIMediaType.manifestAcceptTypes.joined(separator: ", ")])

        let response = try await authorizedBuffered(request, ref: ref, credential: credential)
        guard response.statusCode == 200 else {
            throw OCIError.manifestUnavailable(
                reference: "\(ref.repository)@\(reference)", status: response.statusCode)
        }

        // The digest is defined as the SHA-256 of the exact bytes served.
        let digest = "sha256:" + Self.sha256Hex(of: response.body)
        if let expectedDigest, digest != expectedDigest {
            throw OCIError.digestMismatch(expected: expectedDigest, actual: digest)
        }

        let contentType = response.header("content-type")?
            .split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces) }
        return ManifestDocument(body: response.body, digest: digest, contentType: contentType)
    }

    /// Whether a manifest document is a multi-platform index. Trust the
    /// Content-Type header when it names a type we know; otherwise sniff the
    /// body (some registries serve manifests as generic JSON).
    private func isIndexDocument(_ document: ManifestDocument) -> Bool {
        if let contentType = document.contentType {
            if OCIMediaType.isIndex(contentType) { return true }
            if OCIMediaType.isManifest(contentType) { return false }
        }
        struct Probe: Decodable {
            let mediaType: String?
            let manifests: [OCIDescriptor]?
        }
        guard let probe = try? JSONDecoder().decode(Probe.self, from: document.body) else { return false }
        if let mediaType = probe.mediaType { return OCIMediaType.isIndex(mediaType) }
        return probe.manifests != nil
    }

    private func decodeManifest(_ document: ManifestDocument, ref: OCIImageReference) throws -> OCIManifest {
        if let contentType = document.contentType, !OCIMediaType.isManifest(contentType),
            OCIMediaType.isIndex(contentType)
        {
            // A nested index (index pointing at an index) is spec-legal but
            // pathological; refuse rather than recurse.
            throw OCIError.unsupportedMediaType(contentType)
        }
        guard let manifest = try? JSONDecoder().decode(OCIManifest.self, from: document.body) else {
            throw OCIError.malformedResponse(detail: "undecodable image manifest for \(ref.repository)")
        }
        return manifest
    }

    // MARK: - Blob fetch

    /// Downloads a blob to `destinationPath`, verifying its SHA-256 against
    /// the descriptor's digest before the file appears at the destination
    /// (staged as `.partial`, published by rename).
    public func fetchBlob(
        _ descriptor: OCIDescriptor,
        from ref: OCIImageReference,
        credential: RegistryCredential? = nil,
        to destinationPath: String
    ) async throws {
        guard OCIImageReference.isValidDigest(descriptor.digest) else {
            throw OCIError.malformedResponse(detail: "malformed blob digest \(descriptor.digest)")
        }
        guard let url = URL(string: "\(ref.apiBaseURL)/v2/\(ref.repository)/blobs/\(descriptor.digest)")
        else {
            throw OCIError.invalidReference("\(ref.repository)@\(descriptor.digest)")
        }

        let stagingPath = destinationPath + ".partial"
        defer { try? FileManager.default.removeItem(atPath: stagingPath) }

        let request = OCIHTTPRequest(url: url)
        let (status, _) = try await authorizedDownload(
            request, to: stagingPath, ref: ref, credential: credential)
        guard status == 200 else {
            throw OCIError.blobUnavailable(digest: descriptor.digest, status: status)
        }

        // Enforce the declared blob size against what was actually written.
        // Without this, a manifest can declare a tiny `size` (so the caller's
        // free-space precheck, computed from declared sizes, passes) while the
        // registry serves a multi-GB blob whose digest still matches — a
        // disk-exhaustion vector. A blob whose length disagrees with its
        // descriptor is rejected. (A hard mid-stream download cap is a follow-up
        // that requires a streaming transport delegate.)
        if descriptor.size > 0 {
            let writtenSize =
                ((try? FileManager.default.attributesOfItem(atPath: stagingPath)[.size]) as? Int64) ?? -1
            guard writtenSize == descriptor.size else {
                throw OCIError.malformedResponse(
                    detail:
                        "blob \(descriptor.digest) size mismatch: declared \(descriptor.size), received \(writtenSize)"
                )
            }
        }

        let actual = "sha256:" + (try Self.sha256Hex(ofFileAt: stagingPath))
        guard actual == descriptor.digest else {
            throw OCIError.digestMismatch(expected: descriptor.digest, actual: actual)
        }

        try? FileManager.default.removeItem(atPath: destinationPath)
        try FileManager.default.moveItem(atPath: stagingPath, toPath: destinationPath)
    }

    // MARK: - Authorization

    /// Runs a buffered request through the registry auth flow.
    private func authorizedBuffered(
        _ request: OCIHTTPRequest, ref: OCIImageReference, credential: RegistryCredential?
    ) async throws -> OCIHTTPResponse {
        try await withAuthorization(ref: ref, credential: credential) { authorization in
            let response = try await self.bufferedWithRetry(request, authorization: authorization)
            return (response, response.statusCode, response.header("www-authenticate"))
        }
    }

    /// Runs a download request through the registry auth flow.
    private func authorizedDownload(
        _ request: OCIHTTPRequest, to path: String, ref: OCIImageReference, credential: RegistryCredential?
    ) async throws -> (statusCode: Int, headers: [String: String]) {
        try await withAuthorization(ref: ref, credential: credential) { authorization in
            let result = try await self.downloadWithRetry(request, to: path, authorization: authorization)
            return (result, result.statusCode, result.headers["www-authenticate"])
        }
    }

    /// The distribution auth flow around one logical request:
    ///
    /// 1. Control-plane-minted bearer tokens (`credential.bearer == true`) are
    ///    presented directly — no challenge round-trip.
    /// 2. Otherwise the request goes out with a cached pull token when one is
    ///    live, or anonymously.
    /// 3. On 401, the `WWW-Authenticate` challenge picks the path: `Basic`
    ///    retries with the credential; `Bearer` mints a token from the
    ///    challenge's realm (Basic-authenticating the token endpoint when a
    ///    credential is present — anonymous minting is how public pulls work)
    ///    and retries with it.
    ///
    /// `perform` executes the request with the given `Authorization` header
    /// value and reports (result, status, WWW-Authenticate header).
    private func withAuthorization<R>(
        ref: OCIImageReference,
        credential: RegistryCredential?,
        perform: (_ authorization: String?) async throws -> (result: R, status: Int, challenge: String?)
    ) async throws -> R {
        if let credential {
            // A credential already past its expiry can only produce a doomed
            // pull; fail fast and let the next sync deliver fresh material.
            if let expiresAt = credential.expiresAt, expiresAt <= Date() {
                throw OCIError.credentialExpired(registry: ref.registry)
            }
            if credential.bearer == true {
                let (result, status, _) = try await perform("Bearer \(credential.password)")
                guard status != 401 else {
                    throw OCIError.authenticationFailed(
                        registry: ref.registry, detail: "control-plane-minted bearer token was rejected")
                }
                return result
            }
        }

        let cacheKey = "\(ref.registry)|\(ref.repository)|\(credential?.username ?? "")"
        let initialAuthorization = validCachedToken(for: cacheKey).map { "Bearer \($0)" }

        let (result, status, challengeHeader) = try await perform(initialAuthorization)
        guard status == 401 else { return result }

        guard let challengeHeader, let challenge = OCIAuthChallenge.parse(challengeHeader) else {
            throw OCIError.authenticationFailed(
                registry: ref.registry, detail: "401 without a parseable WWW-Authenticate challenge")
        }

        let retryAuthorization: String
        switch challenge {
        case .basic:
            guard let credential else {
                throw OCIError.authenticationFailed(
                    registry: ref.registry, detail: "registry requires credentials and none were provided")
            }
            retryAuthorization = Self.basicAuthorization(credential)
        case .bearer(let realm, let service, let scope):
            let token = try await mintToken(
                realm: realm, service: service, scope: scope, ref: ref, credential: credential)
            tokenCache[cacheKey] = token
            retryAuthorization = "Bearer \(token.value)"
        }

        let (retryResult, retryStatus, _) = try await perform(retryAuthorization)
        guard retryStatus != 401 else {
            tokenCache[cacheKey] = nil
            throw OCIError.authenticationFailed(
                registry: ref.registry, detail: "credentials were rejected after completing the auth flow")
        }
        return retryResult
    }

    private func validCachedToken(for key: String) -> String? {
        guard let token = tokenCache[key] else { return nil }
        guard token.expiresAt.timeIntervalSinceNow > Self.tokenExpiryMargin else {
            tokenCache[key] = nil
            return nil
        }
        return token.value
    }

    /// Mints a pull token from a Bearer challenge's realm. Mirrors the control
    /// plane's `DistributionRegistryClient.mintPullToken`, including refusing
    /// to send credentials toward a plaintext non-loopback realm.
    private func mintToken(
        realm: String, service: String?, scope: String?, ref: OCIImageReference,
        credential: RegistryCredential?
    ) async throws -> MintedToken {
        guard var components = URLComponents(string: realm), components.scheme != nil else {
            throw OCIError.malformedResponse(detail: "unparseable token realm \(realm)")
        }

        if credential != nil {
            let scheme = components.scheme?.lowercased()
            let realmIsSecure =
                scheme == "https"
                || (scheme == "http" && OCIImageReference.isLoopbackHost(components.host ?? ""))
            guard realmIsSecure else {
                throw OCIError.insecureTokenRealm(registry: ref.registry, realm: realm)
            }
        }

        var queryItems = components.queryItems ?? []
        queryItems.append(URLQueryItem(name: "scope", value: scope ?? "repository:\(ref.repository):pull"))
        if let service {
            queryItems.append(URLQueryItem(name: "service", value: service))
        }
        components.queryItems = queryItems
        guard let tokenURL = components.url else {
            throw OCIError.malformedResponse(detail: "unparseable token realm \(realm)")
        }

        var headers: [String: String] = [:]
        if let credential {
            headers["Authorization"] = Self.basicAuthorization(credential)
        }
        let response = try await bufferedWithRetry(
            OCIHTTPRequest(url: tokenURL, headers: headers), authorization: nil)
        guard response.statusCode == 200 else {
            throw OCIError.authenticationFailed(
                registry: ref.registry, detail: "token endpoint returned HTTP \(response.statusCode)")
        }

        struct TokenResponse: Decodable {
            let token: String?
            let accessToken: String?
            let expiresIn: Int?

            enum CodingKeys: String, CodingKey {
                case token
                case accessToken = "access_token"
                case expiresIn = "expires_in"
            }
        }
        guard let decoded = try? JSONDecoder().decode(TokenResponse.self, from: response.body),
            let value = decoded.token ?? decoded.accessToken, !value.isEmpty
        else {
            throw OCIError.authenticationFailed(
                registry: ref.registry, detail: "token endpoint returned no usable token")
        }
        let lifetime = decoded.expiresIn.map(TimeInterval.init) ?? Self.defaultTokenLifetime
        return MintedToken(value: value, expiresAt: Date().addingTimeInterval(lifetime))
    }

    private static func basicAuthorization(_ credential: RegistryCredential) -> String {
        let raw = Data("\(credential.username):\(credential.password)".utf8)
        return "Basic \(raw.base64EncodedString())"
    }

    // MARK: - Retry and redirect plumbing

    private func bufferedWithRetry(
        _ request: OCIHTTPRequest, authorization: String?
    ) async throws -> OCIHTTPResponse {
        try await withRetry(url: request.url, statusOf: { $0.statusCode }) {
            try await self.followRedirectsBuffered(request, authorization: authorization)
        }
    }

    private func downloadWithRetry(
        _ request: OCIHTTPRequest, to path: String, authorization: String?
    ) async throws -> (statusCode: Int, headers: [String: String]) {
        try await withRetry(url: request.url, statusOf: { $0.statusCode }) {
            try await self.followRedirectsDownload(request, to: path, authorization: authorization)
        }
    }

    /// Retries transient failures with backoff, mirroring `ImageCacheService`:
    /// thrown transport errors and retryable statuses (5xx, 408, 429) get
    /// another attempt; terminal statuses are returned to the caller to
    /// interpret; permanently-classified errors propagate immediately.
    private func withRetry<R>(
        url: URL, statusOf: (R) -> Int, _ operation: () async throws -> R
    ) async throws -> R {
        var lastError = OCIError.transferFailed(detail: "no attempt made")

        for attempt in 1...configuration.maxAttempts {
            if attempt > 1 {
                let backoff = configuration.retryBaseDelay * (1 << (attempt - 2))
                logger.warning(
                    "Retrying registry request after transient failure",
                    metadata: [
                        "url": .string(url.absoluteString),
                        "attempt": .stringConvertible(attempt),
                        "error": .string(String(describing: lastError)),
                    ])
                try? await Task.sleep(for: backoff)
            }

            do {
                let result = try await operation()
                let status = statusOf(result)
                if Self.isRetryableStatus(status) {
                    lastError = .transferFailed(detail: "HTTP \(status) from \(url.absoluteString)")
                    continue
                }
                return result
            } catch let error as OCIError {
                guard error.failureClassification == .transient else { throw error }
                lastError = error
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // Network-level errors (URLError and friends) are transient
                // by nature.
                lastError = .transferFailed(detail: String(describing: error))
            }
        }

        throw lastError
    }

    private func followRedirectsBuffered(
        _ request: OCIHTTPRequest, authorization: String?
    ) async throws -> OCIHTTPResponse {
        var url = request.url
        var hopAuthorization = authorization
        for _ in 0...configuration.maxRedirects {
            var headers = request.headers
            if let hopAuthorization {
                headers["Authorization"] = hopAuthorization
            }
            let response = try await transport.execute(
                OCIHTTPRequest(method: request.method, url: url, headers: headers))
            guard Self.isRedirect(response.statusCode) else { return response }
            url = try Self.redirectTarget(from: response.header("location"), relativeTo: url)
            // Never forward credentials across a redirect: the target is a
            // different trust domain (typically a pre-signed CDN URL).
            hopAuthorization = nil
        }
        throw OCIError.tooManyRedirects(url: request.url.absoluteString)
    }

    private func followRedirectsDownload(
        _ request: OCIHTTPRequest, to path: String, authorization: String?
    ) async throws -> (statusCode: Int, headers: [String: String]) {
        var url = request.url
        var hopAuthorization = authorization
        for _ in 0...configuration.maxRedirects {
            var headers = request.headers
            if let hopAuthorization {
                headers["Authorization"] = hopAuthorization
            }
            let (status, responseHeaders) = try await transport.download(
                OCIHTTPRequest(method: request.method, url: url, headers: headers), to: path)
            guard Self.isRedirect(status) else { return (status, responseHeaders) }
            url = try Self.redirectTarget(from: responseHeaders["location"], relativeTo: url)
            hopAuthorization = nil
        }
        throw OCIError.tooManyRedirects(url: request.url.absoluteString)
    }

    private static func redirectTarget(from location: String?, relativeTo url: URL) throws -> URL {
        guard let location, let target = URL(string: location, relativeTo: url) else {
            throw OCIError.malformedResponse(
                detail: "redirect without usable Location from \(url.absoluteString)")
        }
        return target.absoluteURL
    }

    private static func isRedirect(_ status: Int) -> Bool {
        status == 301 || status == 302 || status == 303 || status == 307 || status == 308
    }

    private static func isRetryableStatus(_ status: Int) -> Bool {
        status >= 500 || status == 408 || status == 429
    }

    // MARK: - Hashing

    static func sha256Hex(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func sha256Hex(ofFileAt path: String) throws -> String {
        guard let fileHandle = FileHandle(forReadingAtPath: path) else {
            throw OCIError.transferFailed(detail: "downloaded file missing at \(path)")
        }
        defer { try? fileHandle.close() }

        var hasher = SHA256()
        while true {
            let chunk = fileHandle.readData(ofLength: 1024 * 1024)
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// A parsed `WWW-Authenticate` challenge from a distribution registry.
/// Same grammar the control plane's `RegistryAuthChallenge` accepts, plus the
/// optional `scope` parameter (the agent honors a registry-suggested scope;
/// the control plane always constructs its own).
public enum OCIAuthChallenge: Equatable, Sendable {
    case bearer(realm: String, service: String?, scope: String?)
    case basic

    /// Parses `Bearer realm="https://...",service="..."` (parameter order and
    /// quoting vary by registry) or a `Basic ...` challenge. Nil for anything
    /// unrecognized.
    public static func parse(_ header: String) -> OCIAuthChallenge? {
        let trimmed = header.trimmingCharacters(in: .whitespaces)
        if trimmed.lowercased().hasPrefix("basic") {
            return .basic
        }
        guard trimmed.lowercased().hasPrefix("bearer") else {
            return nil
        }

        var params: [String: String] = [:]
        for part in Self.splitParameters(trimmed.dropFirst("bearer".count)) {
            let pair = part.split(separator: "=", maxSplits: 1)
            guard pair.count == 2 else { continue }
            let key = pair[0].trimmingCharacters(in: .whitespaces).lowercased()
            let value = pair[1].trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            params[key] = value
        }
        guard let realm = params["realm"], !realm.isEmpty else { return nil }
        return .bearer(realm: realm, service: params["service"], scope: params["scope"])
    }

    /// Splits challenge parameters on commas, respecting quoted values —
    /// a `scope` covering multiple repositories is comma-free, but quoted
    /// commas are legal and must not split a parameter.
    private static func splitParameters(_ text: Substring) -> [String] {
        var parts: [String] = []
        var current = ""
        var inQuotes = false
        for character in text {
            if character == "\"" {
                inQuotes.toggle()
                current.append(character)
            } else if character == "," && !inQuotes {
                parts.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty {
            parts.append(current)
        }
        return parts
    }
}
