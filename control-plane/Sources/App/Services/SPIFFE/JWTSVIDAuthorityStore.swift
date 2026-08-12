import Foundation
import SPIREServerAPI
import Vapor

/// Where a trust domain's JWT authorities come from (issue #495).
///
/// A protocol so the store can be driven from a fixed JWKS in tests, and so a
/// Workload API (`FetchJWTBundles`) source can be added later without touching
/// the verification path.
protocol JWTAuthoritySource: Sendable {
    /// The trust domain these authorities verify identities for.
    var trustDomain: String { get }

    /// The current JWT signing keys, as a JWKS document.
    func fetchJWKS() async throws -> Data
}

/// JWT authorities read from the SPIRE server's bundle API.
///
/// This is the source that works in both supported deployments: compose and
/// Helm both configure `SPIRE_SERVER_API_ADDRESS`, while the workload API
/// socket is only mounted into the control plane under Helm.
struct SPIREServerJWTAuthoritySource: JWTAuthoritySource {
    let registration: SPIRERegistrationService

    var trustDomain: String { registration.trustDomain }

    func fetchJWKS() async throws -> Data {
        let bundle = try await registration.getBundle()
        // SPIRE reports each authority as a DER SubjectPublicKeyInfo; JOSE
        // wants JWKs. A tainted key is one SPIRE has marked for rotation out
        // and will stop signing with — but tokens it already signed are still
        // valid until they expire, so it stays in the verification set.
        let authorities = bundle.jwtAuthorities.map {
            (keyID: $0.keyID, publicKeyDER: $0.publicKey)
        }
        guard let jwks = JWTAuthorityJWK.makeJWKS(authorities: authorities) else {
            throw JWTSVIDVerificationError.noAuthorities(trustDomain: trustDomain)
        }
        return jwks
    }
}

/// Caches a trust domain's JWT verification keys and verifies JWT-SVIDs
/// against them (issue #495).
///
/// SPIRE rotates its JWT signing keys, so the cached set expires and is
/// re-fetched — lazily, on the first request past `refreshInterval`; there is
/// no background refresh task. A token naming a `kid` the cached set doesn't
/// know also triggers one immediate re-fetch (rate-limited, so an attacker
/// replaying junk `kid`s cannot turn the authenticator into a load generator
/// against the SPIRE server). Every failure path denies — an unavailable
/// authority set means "cannot verify", never "accept".
///
/// Concurrent fetches collapse onto one in-flight request. Without that, the
/// actor's re-entrancy at the `await` means a cold cache under load lets every
/// concurrent first-request see `cached == nil` and dial SPIRE, so a restart
/// would fan out one `getBundle()` per in-flight request.
actor JWTSVIDAuthorityStore {
    private let source: any JWTAuthoritySource
    private let logger: Logger

    /// This control plane's audience name. A JWT-SVID must name it exactly.
    let audience: String

    /// How long a fetched authority set is served before the next request
    /// re-fetches it.
    private let refreshInterval: TimeInterval

    /// Floor between unknown-`kid`-triggered refreshes.
    private let unknownKeyRefreshCooldown: TimeInterval

    private var cached: (verifiers: JWTSVIDVerifiers, fetchedAt: Date)?
    private var lastUnknownKeyRefresh: Date?

    /// The fetch currently in flight, if any, so concurrent callers join it
    /// instead of starting their own.
    private var inFlightFetch: Task<JWTSVIDVerifiers, any Error>?

    init(
        source: any JWTAuthoritySource,
        audience: String,
        logger: Logger,
        refreshInterval: TimeInterval = 300,
        unknownKeyRefreshCooldown: TimeInterval = 10
    ) {
        self.source = source
        self.audience = audience
        self.logger = logger
        self.refreshInterval = refreshInterval
        self.unknownKeyRefreshCooldown = unknownKeyRefreshCooldown
    }

    var trustDomain: String { source.trustDomain }

    /// Verify a JWT-SVID and return the identity it names.
    ///
    /// - Throws: `JWTSVIDVerificationError` for every rejection, so the caller
    ///   can log the reason without leaking it to the client.
    func verify(token: String) async throws -> VerifiedJWTSVID {
        let header = try JWTSVIDVerification.decodeHeader(token)

        let verifiers = try await currentVerifiers()
        do {
            return try await verifiers.verify(
                token, header: header, audience: audience, trustDomain: source.trustDomain)
        } catch let error as JWTSVIDVerificationError {
            // An unknown `kid` is the signature of a key rotation we have not
            // picked up yet. Re-fetch once and retry before rejecting — but
            // only if the header actually names a kid we don't hold, and only
            // outside the cooldown.
            guard case .rejected = error, let kid = header.kid, !verifiers.knownKeyIDs.contains(kid),
                let refreshed = try await refreshForUnknownKey(kid: kid)
            else { throw error }

            return try await refreshed.verify(
                token, header: header, audience: audience, trustDomain: source.trustDomain)
        }
    }

    /// The cached verifiers, refreshing when the cache is cold or stale.
    ///
    /// A refresh failure with a still-usable cached set keeps serving it: the
    /// SPIRE server being briefly unreachable must not lock out every workload
    /// whose keys we already hold.
    private func currentVerifiers() async throws -> JWTSVIDVerifiers {
        if let cached, Date().timeIntervalSince(cached.fetchedAt) < refreshInterval {
            return cached.verifiers
        }
        do {
            return try await fetchVerifiers()
        } catch {
            guard let cached else { throw error }
            logger.warning(
                "JWT authority refresh failed; reusing cached keys",
                metadata: [
                    "trustDomain": .string(source.trustDomain),
                    "error": .string("\(error)"),
                ])
            return cached.verifiers
        }
    }

    /// Re-fetch because a token named a key we do not hold. Returns nil when
    /// the cooldown has not elapsed or the refresh did not produce the key, so
    /// the caller falls back to rejecting the token.
    private func refreshForUnknownKey(kid: String) async throws -> JWTSVIDVerifiers? {
        if let last = lastUnknownKeyRefresh, Date().timeIntervalSince(last) < unknownKeyRefreshCooldown {
            return nil
        }
        lastUnknownKeyRefresh = Date()

        let verifiers: JWTSVIDVerifiers
        do {
            verifiers = try await fetchVerifiers()
        } catch {
            logger.warning(
                "JWT authority refresh for an unknown key id failed",
                metadata: ["kid": .string(kid), "error": .string("\(error)")])
            return nil
        }
        guard verifiers.knownKeyIDs.contains(kid) else { return nil }

        logger.info(
            "Picked up a rotated JWT authority",
            metadata: ["kid": .string(kid), "trustDomain": .string(source.trustDomain)])
        return verifiers
    }

    /// Fetch the authority set, collapsing concurrent callers onto one request.
    ///
    /// The actor suspends at the `await` below, so without the in-flight handle
    /// every caller that arrived while a fetch was outstanding would start
    /// another one — a cold cache under load would fan out one `getBundle()`
    /// per request. Joiners await the same task and therefore share its
    /// outcome, including its failure.
    ///
    /// An unstructured `Task` rather than a detached one: it inherits the task
    /// locals carrying the tracing context, so the SPIRE call stays inside the
    /// span of whichever request happened to trigger it.
    private func fetchVerifiers() async throws -> JWTSVIDVerifiers {
        if let existing = inFlightFetch {
            return try await existing.value
        }

        let source = self.source
        let logger = self.logger
        let task = Task<JWTSVIDVerifiers, any Error> {
            let jwks = try await source.fetchJWKS()
            return try await JWTSVIDVerification.makeVerifiers(jwksJSON: jwks, logger: logger)
        }
        inFlightFetch = task
        defer { inFlightFetch = nil }

        let verifiers = try await task.value
        cached = (verifiers, Date())
        return verifiers
    }
}

// MARK: - Application wiring

extension Application {
    private struct JWTSVIDAuthorityStoreKey: StorageKey {
        typealias Value = JWTSVIDAuthorityStore
    }

    /// The JWT-SVID authority store, or nil when JWT-SVID authentication is not
    /// configured (SPIRE disabled, no server API address, or explicitly turned
    /// off). Nil means the authenticator is a no-op: JWT-SVIDs are simply not
    /// an accepted credential.
    var jwtSVIDAuthorityStore: JWTSVIDAuthorityStore? {
        get { storage[JWTSVIDAuthorityStoreKey.self] }
        set { setStorageValue(JWTSVIDAuthorityStoreKey.self, to: newValue) }
    }

    /// Configure JWT-SVID authentication (issue #495).
    ///
    /// Requires SPIRE and the SPIRE server API — the JWT authorities live
    /// there. Off by default: it widens the credential surface from "mTLS only"
    /// to "bearer tokens accepted", which an operator should opt into.
    ///
    /// The audience defaults to the control plane's own SPIFFE ID, which is
    /// what a workload naturally names when minting a token for us.
    func configureJWTSVIDAuthentication() {
        guard controlPlaneConfiguration.bool(.spiffeJWTSVIDAuthEnabled) == true else { return }

        guard let registration = spireRegistrationService else {
            logger.warning(
                """
                SPIFFE_JWT_SVID_AUTH_ENABLED is set but SPIRE is not configured \
                (needs SPIRE_ENABLED=true and SPIRE_SERVER_API_ADDRESS); JWT-SVIDs will not be accepted
                """
            )
            return
        }

        let audience =
            controlPlaneConfiguration.string(.spiffeJWTAudience)
            ?? "spiffe://\(registration.trustDomain)/control-plane"
        let refreshInterval =
            controlPlaneConfiguration.double(.spiffeJWTBundleRefreshInterval)

        jwtSVIDAuthorityStore = JWTSVIDAuthorityStore(
            source: SPIREServerJWTAuthoritySource(registration: registration),
            audience: audience,
            logger: logger,
            refreshInterval: refreshInterval
        )

        logger.info(
            "JWT-SVID authentication enabled",
            metadata: [
                "trustDomain": .string(registration.trustDomain),
                "audience": .string(audience),
            ])
    }
}
