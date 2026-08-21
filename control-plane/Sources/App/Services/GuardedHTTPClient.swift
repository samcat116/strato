import AsyncHTTPClient
import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import NIOSSL
import Vapor

/// The single outbound path for server-side fetches whose destination a tenant
/// can influence: image / artifact `sourceURL` downloads, the OCI registry
/// manifest and token calls driven by a sandbox `image:` reference, webhook
/// deliveries, and the OIDC discovery / token / JWKS / UserInfo fetches.
///
/// Every one of those is a potential SSRF pivot into the control plane's own
/// network (cloud metadata at `169.254.169.254`, loopback admin ports,
/// Postgres/Valkey, the SPIRE server), and the defense only holds if four
/// things happen together on every single fetch. This type owns all four so
/// that no call site has to remember them:
///
/// 1. **Parse once.** The URL is parsed here, and the request is built from
///    that same parse. A call site that validates one parse and then requests
///    another can pin against a host the request never uses (userinfo `@`,
///    backslashes, case): the `dnsOverride` key misses, the pin silently does
///    nothing, and validation still "passes".
/// 2. **Classify the resolved address** — `SSRFGuard.validate`, which resolves
///    the host and rejects it unless every address it resolves to is publicly
///    routable.
/// 3. **Pin the connection** to an address the guard approved
///    (AsyncHTTPClient's `dnsOverride`), so the connect cannot re-resolve the
///    name onto an internal address in the window between the check and the
///    connect. Without this, a record with a 1s TTL that alternates between a
///    public address and `169.254.169.254` passes validation on the first
///    lookup and connects on the second.
/// 4. **Disallow redirects**, so a validated host cannot 3xx the fetch onto an
///    unvalidated one. A caller that must follow redirects (the image
///    download) follows them by hand, one guarded request per hop, each with
///    its own pinned client — `dnsOverride` is fixed at client construction.
///
/// `app.client` and `app.http.client.shared` stay for **operator-configured**
/// destinations only: Loki, the audit/SSF forwarders, and
/// `AgentUpdateArtifacts` (whose base URL is `AGENT_UPDATE_ARTIFACT_BASE_URL`,
/// which attaches no credentials and needs GitHub's release-CDN 302 — that
/// exemption is a decision, not an oversight). Anything a tenant can steer
/// goes through here.
final class GuardedHTTPClient: Sendable {
    /// Resolves and classifies a URL's host, returning the IP literals approved
    /// for connection. `SSRFGuard.validate` in production; a seam so tests can
    /// drive the pinned path (which is otherwise unreachable under `.testing`,
    /// where the guard deliberately allows private hosts) and simulate a
    /// rebind by approving an address the name does not resolve to.
    typealias AddressValidator = @Sendable (URL) async throws -> [String]

    private let app: Application
    private let validator: AddressValidator

    /// TLS settings for the pinned clients. Nil in production (AsyncHTTPClient's
    /// defaults: the system trust store, full hostname verification). A seam so
    /// tests can trust a throwaway CA and assert the load-bearing property of
    /// the whole design — that certificates are still verified against the
    /// *hostname* while only resolution is overridden.
    private let tlsConfiguration: TLSConfiguration?

    /// Ceiling on a buffered response body. The buffered API serves control
    /// documents — JWKS, OIDC token/UserInfo payloads, OCI manifests — none of
    /// which are anywhere near this size; bulk transfers use the streaming API,
    /// which enforces its own caller-specific limit.
    static let maxBufferedResponseBytes = 10 * 1024 * 1024

    /// Applied when a caller passes no timeout of its own.
    static let defaultTimeout: TimeAmount = .seconds(30)

    /// How long a pinned client may spend acquiring a connection before the
    /// attempt is abandoned as a connect failure.
    ///
    /// This is deliberately shorter than AsyncHTTPClient's 10s default, because
    /// it is what makes failover reachable: a refused connection is retried
    /// with backoff inside the pool, so the *only* signal that an approved
    /// address is dead is this deadline elapsing. Leave it at 10s and a caller
    /// with a 10s request timeout (the webhook sweep) would get
    /// `deadlineExceeded` first — indistinguishable from a slow peer, so not
    /// retryable — and would never try the second address. A TCP handshake to a
    /// routable address that takes longer than this is already broken.
    static let connectTimeout: TimeAmount = .seconds(5)

    init(
        app: Application,
        validator: AddressValidator? = nil,
        tlsConfiguration: TLSConfiguration? = nil
    ) {
        self.app = app
        self.tlsConfiguration = tlsConfiguration
        if let validator {
            self.validator = validator
        } else {
            let configuration = app.controlPlaneConfiguration
            let environment = app.environment
            let threadPool = app.threadPool
            self.validator = { url in
                try await SSRFGuard.validate(
                    url: url,
                    configuration: configuration,
                    environment: environment,
                    on: threadPool)
            }
        }
    }

    // MARK: - Buffered fetches

    /// Sends `request` and buffers the whole response.
    ///
    /// Returns Vapor's `ClientResponse` so call sites keep `content.decode` and
    /// so the unpinned fallback below can be `app.client` — which is what makes
    /// a scripted client installed with `app.clients.use` still work in tests.
    func send(_ request: ClientRequest) async throws -> ClientResponse {
        let target = try await prepare(request.url.string)
        let timeout = request.timeout ?? Self.defaultTimeout
        var request = request
        request.url = URI(string: target.requestURL)
        // Stamp the resolved timeout rather than leaving the fallback on Vapor's
        // default: a fetch that hangs should hang for the same length of time
        // whichever path it took, or the local repro won't match production.
        request.timeout = timeout

        guard target.needsPinning else {
            return try await app.client.send(request)
        }

        var pinned = HTTPClientRequest(url: target.requestURL)
        pinned.method = request.method
        pinned.headers = request.headers
        if let body = request.body {
            pinned.body = .bytes(body)
        }

        return try await withPinnedClient(target) { client in
            let response = try await client.execute(pinned, timeout: timeout)
            var body: ByteBuffer?
            do {
                let collected = try await response.body.collect(upTo: Self.maxBufferedResponseBytes)
                body = collected.readableBytes > 0 ? collected : nil
            } catch is NIOTooManyBytesError {
                // The status still stands — a webhook consumer that answers 200
                // with an enormous body has delivered fine. Callers that need
                // the body (JWKS, a manifest) fail closed on the empty one.
                // Any other streaming error propagates: a truncated response
                // must not be reported as a clean status.
                self.app.logger.warning(
                    "Guarded fetch discarded an oversized response body",
                    metadata: [
                        "host": .string(target.host),
                        "limit": .stringConvertible(Self.maxBufferedResponseBytes),
                    ])
            }
            return ClientResponse(status: response.status, headers: response.headers, body: body)
        }
    }

    // MARK: - Streaming fetches

    /// Opens a guarded request and hands the response to `handle` while the
    /// connection is still live, so the body can be streamed rather than
    /// buffered. The pinned client is shut down when `handle` returns.
    ///
    /// Errors thrown by `handle` are never retried against another approved
    /// address — only a failure to establish the connection is (see
    /// `withPinnedClient`).
    func withStreamedResponse<T>(
        url: URL,
        method: HTTPMethod = .GET,
        headers: HTTPHeaders = [:],
        timeout: TimeAmount = GuardedHTTPClient.defaultTimeout,
        _ handle: (HTTPClientResponse) async throws -> T
    ) async throws -> T {
        let target = try await prepare(url.absoluteString)

        var request = HTTPClientRequest(url: target.requestURL)
        request.method = method
        request.headers = headers

        guard target.needsPinning else {
            // No pin to apply (see `Target.needsPinning`). The shared client is
            // configured with redirects disallowed in `configure`, which is the
            // property that matters here.
            let response = try await app.http.client.shared.execute(request, timeout: timeout)
            return try await handle(response)
        }

        return try await withPinnedClient(target) { client in
            let response = try await client.execute(request, timeout: timeout)
            return try await handle(response)
        }
    }

    // MARK: - Validation and normalization

    /// A validated destination: one parse, its lowercased host, and the
    /// addresses `SSRFGuard` approved for it.
    private struct Target {
        /// The normalized URL string that both the pin and the request use.
        let requestURL: String
        /// Lowercased host — the `dnsOverride` key, matched against the host
        /// AsyncHTTPClient parses out of `requestURL`.
        let host: String
        /// Addresses the guard approved, in resolution order.
        let approvedAddresses: [String]
        /// Whether the host is already an IP literal.
        let hostIsIPLiteral: Bool

        /// Pinning is skipped in exactly two cases, neither of which leaves a
        /// rebind window open:
        ///
        /// * The guard returned no addresses, which happens only when private
        ///   hosts are allowed for this environment (`.testing`/`.development`,
        ///   or the explicit `IMAGE_FETCH_ALLOW_PRIVATE_HOSTS` opt-out). There
        ///   is nothing to pin *to*, and nothing being defended.
        /// * The host is an IP literal, so no name is resolved at connect time
        ///   and the address validated is the address connected to by
        ///   construction. (It also avoids `dnsOverride`'s bracketed IPv6 key
        ///   form, which Foundation and AsyncHTTPClient spell differently.)
        var needsPinning: Bool { !approvedAddresses.isEmpty && !hostIsIPLiteral }
    }

    /// Parses `raw` once, normalizes it, and validates the result.
    ///
    /// Normalization lowercases the host so the `dnsOverride` key cannot miss
    /// on case alone, and rejects embedded credentials outright: a `user:pass@`
    /// URL is where the two parsers are most likely to disagree about which
    /// part is the host, and no guarded fetch has a reason to carry credentials
    /// in the URL. `SSRFGuard.validate` enforces the same credential rule, so
    /// the create-time pre-flights refuse what this would refuse; the check is
    /// repeated here because it must hold even where a caller supplies its own
    /// validator.
    private func prepare(_ raw: String) async throws -> Target {
        guard var components = URLComponents(string: raw) else {
            throw SSRFGuard.BlockedHostError(reason: "Fetch URL could not be parsed")
        }
        guard components.user == nil, components.password == nil else {
            throw SSRFGuard.BlockedHostError(reason: "Fetch URL must not embed credentials")
        }
        guard let host = components.host, !host.isEmpty else {
            throw SSRFGuard.BlockedHostError(reason: "Fetch URL is missing a host")
        }

        let hostIsIPLiteral = Self.isIPLiteral(host)
        let lowercasedHost = host.lowercased()
        // Leave literal hosts byte-for-byte alone: they need no lowercasing to
        // match (they are never a `dnsOverride` key) and rewriting an IPv6 host
        // through `URLComponents` risks losing its brackets.
        if !hostIsIPLiteral, lowercasedHost != host {
            components.host = lowercasedHost
        }
        guard let normalized = components.url else {
            throw SSRFGuard.BlockedHostError(reason: "Fetch URL could not be normalized")
        }

        // Fail closed on parser disagreement. The host above came from
        // `URLComponents`; AsyncHTTPClient re-parses the string it is handed
        // with `URL(string:)` and keys `dnsOverride` on *that* parse's host. The
        // two agree today, which is why the pin lands — but if they ever didn't,
        // the override key would miss and the fetch would proceed unpinned while
        // validation still "passed". Refusing is the only safe direction: an
        // unpinned fetch is exactly the bug this type exists to prevent.
        // Literal hosts are exempt because they are never pinned, and the two
        // parsers spell IPv6 brackets differently across platforms.
        if !hostIsIPLiteral {
            let requestHost = URL(string: normalized.absoluteString)?.host?.lowercased()
            guard requestHost == lowercasedHost else {
                throw SSRFGuard.BlockedHostError(
                    reason: "Fetch URL host is ambiguous and cannot be safely pinned")
            }
        }

        let approvedAddresses = try await validator(normalized)
        return Target(
            requestURL: normalized.absoluteString,
            host: lowercasedHost,
            approvedAddresses: approvedAddresses,
            hostIsIPLiteral: hostIsIPLiteral)
    }

    private static func isIPLiteral(_ host: String) -> Bool {
        var candidate = Substring(host)
        if candidate.hasPrefix("["), candidate.hasSuffix("]") {
            candidate = candidate.dropFirst().dropLast()
        }
        return (try? SocketAddress(ipAddress: String(candidate), port: 0)) != nil
    }

    // MARK: - Pinned execution

    /// Runs `body` against a client pinned to an approved address, trying the
    /// remaining approved addresses when the connection cannot be established.
    ///
    /// `dnsOverride` takes one address per host, so a single pin would drop
    /// happy-eyeballs and failover — fine for a webhook POST, a new availability
    /// failure mode for a multi-gigabyte CDN download whose first address
    /// happens to be dead. Only connection-establishment failures move on to
    /// the next address: once bytes are on the wire the request is not retried,
    /// because the peer may already have acted on it.
    ///
    /// Each attempt gets the caller's full timeout budget, so a fetch that
    /// fails over can outrun it — bounded by `connectTimeout` per dead address.
    ///
    /// KNOWN COST: a client per attempt means no connection reuse. `dnsOverride`
    /// is fixed at construction, so a pooled client can only be shared by
    /// requests that pin the same host to the same address — cacheable in
    /// principle, keyed on (host, address) with a TTL and a shutdown at app
    /// teardown, but not free. Until then the registry sync pays a handshake per
    /// call (three per repository: manifest, `/v2/` challenge, token realm) and
    /// each JWKS refresh pays one, where both previously shared Vapor's pool.
    /// Correctness first: an unpinned pooled connection is the bug this exists
    /// to prevent.
    private func withPinnedClient<T>(
        _ target: Target,
        _ body: (HTTPClient) async throws -> T
    ) async throws -> T {
        var lastError: Error?
        for (index, address) in target.approvedAddresses.enumerated() {
            var configuration = HTTPClient.Configuration()
            // A transient client must not reintroduce redirect-following, which
            // would defeat the validation of the final destination.
            configuration.redirectConfiguration = .disallow
            configuration.dnsOverride = [target.host: address]
            configuration.timeout.connect = Self.connectTimeout
            // Resolution is the only thing the override changes: AsyncHTTPClient
            // carries the original host through as the SNI/verification name, so
            // the certificate is still checked against the name, not the pin.
            if let tlsConfiguration {
                configuration.tlsConfiguration = tlsConfiguration
            }
            let client = HTTPClient(
                eventLoopGroupProvider: .shared(app.eventLoopGroup),
                configuration: configuration)
            do {
                let value = try await body(client)
                await shutdown(client, host: target.host)
                return value
            } catch {
                await shutdown(client, host: target.host)
                let hasAnotherAddress = index + 1 < target.approvedAddresses.count
                guard hasAnotherAddress, Self.isConnectionFailure(error) else { throw error }
                app.logger.debug(
                    "Guarded fetch could not connect to an approved address; trying the next",
                    metadata: [
                        "host": .string(target.host),
                        "address": .string(address),
                        "error": .string("\(error)"),
                    ])
                lastError = error
            }
        }
        throw lastError
            ?? SSRFGuard.BlockedHostError(
                reason: "No approved address for host '\(target.host)'")
    }

    /// Shuts a transient client down, logging rather than discarding the
    /// failure: a pool that refuses to close leaks event-loop resources for the
    /// process lifetime, and swallowing the error makes that undiagnosable.
    /// The shutdown itself must not fail the fetch — the response is already in
    /// hand — so this never rethrows.
    private func shutdown(_ client: HTTPClient, host: String) async {
        do {
            try await client.shutdown()
        } catch {
            app.logger.debug(
                "Guarded fetch could not shut down its pinned client",
                metadata: ["host": .string(host), "error": .string("\(error)")])
        }
    }

    /// True only for failures that happened before the request reached the
    /// peer, so retrying against another approved address cannot duplicate a
    /// side effect the peer already performed.
    private static func isConnectionFailure(_ error: Error) -> Bool {
        switch error {
        case is NIOConnectionError:
            return true
        case let error as HTTPClientError where error == .connectTimeout:
            return true
        case let error as ChannelError:
            if case .connectTimeout = error { return true }
            return false
        case let error as IOError:
            return connectErrnos.contains(error.errnoCode)
        default:
            return false
        }
    }

    /// Errnos a `connect(2)` reports when it never reached the peer.
    ///
    /// `ECONNRESET` and `ETIMEDOUT` are deliberately absent: both can arrive
    /// mid-stream, after the request was delivered, and a connect that stalls
    /// surfaces as `HTTPClientError.connectTimeout` instead (see
    /// `connectTimeout`).
    private static let connectErrnos: Set<CInt> = [
        ECONNREFUSED, EHOSTUNREACH, ENETUNREACH, EHOSTDOWN, ENETDOWN, EADDRNOTAVAIL,
    ]
}

// MARK: - Application / Request accessors

extension Application {
    private struct GuardedHTTPClientKey: StorageKey, LockKey {
        typealias Value = GuardedHTTPClient
    }

    /// The guarded outbound client. Settable so tests can install one with a
    /// scripted address validator; production never replaces it.
    var guardedHTTPClient: GuardedHTTPClient {
        get { lazyService(GuardedHTTPClientKey.self) { GuardedHTTPClient(app: self) } }
        set { setStorageValue(GuardedHTTPClientKey.self, to: newValue) }
    }
}

extension Request {
    var guardedHTTPClient: GuardedHTTPClient {
        application.guardedHTTPClient
    }
}
