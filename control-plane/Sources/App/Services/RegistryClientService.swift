import Crypto
import Foundation
import NIOCore
import StratoShared
import Vapor

/// Plaintext credential material for registry API calls — a decrypted
/// `RegistryPullSecret`. Exists only in memory on the way to a registry
/// request; never stored or logged.
struct RegistryBasicCredential: Sendable {
    let username: String
    let password: String
}

/// A short-lived distribution bearer token minted from a registry's token
/// service, scoped to pulling one repository.
struct RegistryPullToken: Sendable {
    let token: String
    let expiresAt: Date
}

/// Registry operations the control plane needs for sandboxes (issue #414):
/// tag→digest resolution at sync assembly and minting the short-lived pull
/// credentials carried in `DesiredSandboxState`. Protocol-typed on
/// `Application` storage so tests substitute a scripted client and the test
/// environment defaults to one that never touches the network.
protocol RegistryClientProtocol: Sendable {
    /// Resolves a reference to its manifest digest (`sha256:...`). Nil means
    /// the client deliberately does not resolve (the testing default); a
    /// thrown error means resolution was attempted and failed.
    func resolveDigest(
        for ref: OCIImageReference, credential: RegistryBasicCredential?
    ) async throws -> String?

    /// Mints a pull-scoped bearer token for the reference's repository. Nil
    /// means the registry doesn't use token auth (Basic-only or entirely
    /// unauthenticated), in which case the caller falls back to Basic
    /// credentials. Anonymous minting (nil credential) is how Docker Hub and
    /// GHCR authorize public pulls.
    func mintPullToken(
        for ref: OCIImageReference, credential: RegistryBasicCredential?
    ) async throws -> RegistryPullToken?
}

/// Failures the sync-assembly caller must treat as *policy*, not transience:
/// falling back to Basic credentials after one of these would defeat the
/// protection that produced it.
enum RegistryClientError: Error, LocalizedError {
    /// The registry's Bearer realm is plaintext HTTP on a non-loopback host.
    /// No credential material may travel toward it — not from the control
    /// plane, and not from an agent handed the stored secret to run the
    /// challenge flow itself.
    case insecureTokenRealm(registry: String, realm: String)

    var errorDescription: String? {
        switch self {
        case .insecureTokenRealm(let registry, let realm):
            return
                "Registry \(registry) advertises a plaintext token realm (\(realm)); refusing to send credentials"
        }
    }
}

/// The no-network client installed under `.testing`: resolves nothing and
/// mints nothing, so sync assembly in tests neither performs HTTP nor pins
/// digests unless a test installs a scripted client of its own.
struct NoopRegistryClient: RegistryClientProtocol {
    func resolveDigest(
        for ref: OCIImageReference, credential: RegistryBasicCredential?
    ) async throws -> String? { nil }

    func mintPullToken(
        for ref: OCIImageReference, credential: RegistryBasicCredential?
    ) async throws -> RegistryPullToken? { nil }
}

/// Real client speaking the OCI distribution auth flow (Docker Hub, GHCR, and
/// any distribution-spec registry):
///
/// 1. `GET /v2/` probes the registry's challenge. `Bearer` challenges carry
///    the token service's realm; the pull scope is constructed client-side as
///    `repository:<repo>:pull` per the distribution spec.
/// 2. The token endpoint is queried with the stored credential as Basic auth
///    (or anonymously for public pulls) and returns a short-lived JWT.
/// 3. Manifest requests carry the token; the digest comes from the
///    `Docker-Content-Digest` header, falling back to hashing the canonical
///    manifest bytes (the digest *is* the SHA-256 of those bytes).
///
/// Minted tokens are cached per (registry, repository, username) until close
/// to expiry so the periodic sync doesn't hammer token endpoints.
final class DistributionRegistryClient: RegistryClientProtocol {
    /// Held to resolve `app.client` per call, so a scripted client installed
    /// via `app.clients.use` is honored. Vapor's `Application` is Sendable.
    private let app: Application
    private let tokenCache = TokenCache()

    /// Registries occasionally omit `expires_in`; the spec's documented
    /// default is 60 seconds.
    private static let defaultTokenLifetime: TimeInterval = 60
    /// Bound every registry round-trip: sync assembly runs on the agent
    /// message path, so a wedged registry must not stall syncs indefinitely.
    private static let requestTimeout: TimeAmount = .seconds(15)

    private static let manifestAcceptTypes = [
        "application/vnd.oci.image.index.v1+json",
        "application/vnd.oci.image.manifest.v1+json",
        "application/vnd.docker.distribution.manifest.list.v2+json",
        "application/vnd.docker.distribution.manifest.v2+json",
    ]

    init(app: Application) {
        self.app = app
    }

    // MARK: - Digest resolution

    func resolveDigest(
        for ref: OCIImageReference, credential: RegistryBasicCredential?
    ) async throws -> String? {
        if let digest = ref.digest {
            return digest
        }

        var headers = HTTPHeaders()
        headers.add(name: .accept, value: Self.manifestAcceptTypes.joined(separator: ", "))
        if let token = try await mintPullToken(for: ref, credential: credential) {
            headers.bearerAuthorization = BearerAuthorization(token: token.token)
        } else if let credential {
            headers.basicAuthorization = BasicAuthorization(
                username: credential.username, password: credential.password)
        }

        let url = "\(ref.apiBaseURL)/v2/\(ref.repository)/manifests/\(ref.tag)"
        let response = try await send(.GET, url: url, headers: headers)
        guard response.status == .ok else {
            throw Abort(
                .badGateway,
                reason:
                    "Registry \(ref.registry) returned \(response.status.code) resolving \(ref.repository):\(ref.tag)"
            )
        }

        if let digest = response.headers.first(name: "Docker-Content-Digest") {
            guard OCIImageReference.isValidDigest(digest) else {
                throw Abort(
                    .badGateway, reason: "Registry \(ref.registry) returned a malformed manifest digest")
            }
            return digest
        }

        // No digest header (it's a SHOULD in the spec): the digest is defined
        // as the SHA-256 of the exact manifest bytes served, so compute it.
        guard let body = response.body else {
            throw Abort(.badGateway, reason: "Registry \(ref.registry) returned an empty manifest")
        }
        let bytes = body.getBytes(at: body.readerIndex, length: body.readableBytes) ?? []
        let hash = SHA256.hash(data: Data(bytes))
        return "sha256:" + hash.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Token minting

    func mintPullToken(
        for ref: OCIImageReference, credential: RegistryBasicCredential?
    ) async throws -> RegistryPullToken? {
        let cacheKey = "\(ref.registry)|\(ref.repository)|\(credential?.username ?? "")"
        if let cached = await tokenCache.validToken(for: cacheKey) {
            return cached
        }

        // Probe the registry's auth challenge. 200 means unauthenticated pulls
        // are fine; a Basic challenge means there is no token service.
        let probe = try await send(.GET, url: "\(ref.apiBaseURL)/v2/", headers: [:])
        if probe.status != .unauthorized {
            return nil
        }
        guard
            let challengeHeader = probe.headers.first(name: .wwwAuthenticate),
            let challenge = RegistryAuthChallenge.parse(challengeHeader)
        else {
            return nil
        }
        guard case .bearer(let realm, let service) = challenge else {
            return nil
        }

        var tokenURI = URI(string: realm)

        // The stored secret travels to the realm as Basic auth, so the realm
        // must be trustworthy: HTTPS anywhere, or plain HTTP only on a real
        // loopback host (dev registries). A plaintext non-loopback realm —
        // misconfigured or malicious challenge — must never see credentials.
        if credential != nil {
            let scheme = tokenURI.scheme?.lowercased()
            let realmIsSecure =
                scheme == "https"
                || (scheme == "http" && OCIImageReference.isLoopbackHost(tokenURI.host ?? ""))
            guard realmIsSecure else {
                throw RegistryClientError.insecureTokenRealm(registry: ref.registry, realm: realm)
            }
        }
        var query: [String] = ["scope=repository:\(urlQueryEncode(ref.repository)):pull"]
        if let service {
            query.append("service=\(urlQueryEncode(service))")
        }
        if let existing = tokenURI.query, !existing.isEmpty {
            query.insert(existing, at: 0)
        }
        tokenURI.query = query.joined(separator: "&")

        var headers = HTTPHeaders()
        if let credential {
            headers.basicAuthorization = BasicAuthorization(
                username: credential.username, password: credential.password)
        }
        let response = try await send(.GET, url: tokenURI.string, headers: headers)
        guard response.status == .ok else {
            throw Abort(
                .badGateway,
                reason:
                    "Token endpoint for \(ref.registry) returned \(response.status.code) for \(ref.repository)")
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
        // Decode straight from the body: token endpoints don't reliably set a
        // JSON content-type, which Vapor's content negotiation would reject.
        guard let body = response.body,
            let bodyData = body.getData(at: body.readerIndex, length: body.readableBytes),
            let decoded = try? JSONDecoder().decode(TokenResponse.self, from: bodyData)
        else {
            throw Abort(
                .badGateway, reason: "Token endpoint for \(ref.registry) returned an unparseable response")
        }
        guard let tokenValue = decoded.token ?? decoded.accessToken, !tokenValue.isEmpty else {
            throw Abort(
                .badGateway, reason: "Token endpoint for \(ref.registry) returned no usable token")
        }

        let lifetime = decoded.expiresIn.map(TimeInterval.init) ?? Self.defaultTokenLifetime
        let token = RegistryPullToken(token: tokenValue, expiresAt: Date().addingTimeInterval(lifetime))
        await tokenCache.store(token, for: cacheKey)
        return token
    }

    // MARK: - Plumbing

    private func send(_ method: HTTPMethod, url: String, headers: HTTPHeaders) async throws -> ClientResponse {
        // The registry host, and any Bearer token realm advertised by it, come
        // straight from a tenant-supplied image reference (e.g. a sandbox
        // `image: "169.254.169.254/x:latest"`). Every hop this method makes —
        // the manifest GET, the `/v2/` challenge probe, and the token-realm GET
        // — must resolve to a public address, or the control plane becomes an
        // SSRF proxy into cloud metadata and internal services (and could leak
        // a decrypted pull secret to an attacker-chosen realm). Validation is
        // environment-gated, so loopback/private dev registries still work.
        guard let parsedURL = URL(string: url) else {
            throw Abort(.badRequest, reason: "Invalid registry URL")
        }
        _ = try await SSRFGuard.validate(
            url: parsedURL, environment: app.environment, on: app.threadPool)

        let request = ClientRequest(
            method: method, url: URI(string: url), headers: headers, body: nil,
            timeout: Self.requestTimeout)
        return try await app.client.send(request)
    }

    /// Percent-encodes a query-string value, keeping RFC 3986 unreserved
    /// characters (so `ghcr.io` stays readable but `/` in repository paths is
    /// escaped).
    private func urlQueryEncode(_ value: String) -> String {
        let unreserved = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        return value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? value
    }

    private actor TokenCache {
        /// Reuse margin: a token is considered expired this long before its
        /// real expiry, so an agent-bound token isn't already dead on arrival.
        private static let expiryMargin: TimeInterval = 30

        private var tokens: [String: RegistryPullToken] = [:]

        func validToken(for key: String) -> RegistryPullToken? {
            guard let token = tokens[key] else { return nil }
            guard token.expiresAt.timeIntervalSinceNow > Self.expiryMargin else {
                tokens[key] = nil
                return nil
            }
            return token
        }

        func store(_ token: RegistryPullToken, for key: String) {
            tokens[key] = token
        }
    }
}

/// A parsed `WWW-Authenticate` challenge from a distribution registry.
enum RegistryAuthChallenge: Equatable {
    case bearer(realm: String, service: String?)
    case basic

    /// Parses `Bearer realm="https://...",service="..."` (parameter order and
    /// quoting vary by registry) or a `Basic ...` challenge. Nil for anything
    /// unrecognized.
    static func parse(_ header: String) -> RegistryAuthChallenge? {
        let trimmed = header.trimmingCharacters(in: .whitespaces)
        if trimmed.lowercased().hasPrefix("basic") {
            return .basic
        }
        guard trimmed.lowercased().hasPrefix("bearer") else {
            return nil
        }

        var params: [String: String] = [:]
        let paramString = trimmed.dropFirst("bearer".count)
        for part in paramString.split(separator: ",") {
            let pair = part.split(separator: "=", maxSplits: 1)
            guard pair.count == 2 else { continue }
            let key = pair[0].trimmingCharacters(in: .whitespaces).lowercased()
            let value = pair[1].trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            params[key] = value
        }
        guard let realm = params["realm"], !realm.isEmpty else { return nil }
        return .bearer(realm: realm, service: params["service"])
    }
}

extension Application {
    private struct RegistryClientKey: StorageKey {
        typealias Value = any RegistryClientProtocol
    }

    /// The application's registry client. `configure()` installs the real
    /// distribution client (or the no-network one under `.testing`); the
    /// default here is the no-network client so nothing accidentally does
    /// registry I/O before configuration.
    var registryClient: any RegistryClientProtocol {
        get { storage[RegistryClientKey.self] ?? NoopRegistryClient() }
        set { setStorageValue(RegistryClientKey.self, to: newValue) }
    }
}
