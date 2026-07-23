import Foundation
import NIOCore
import Vapor

/// How far to trust `X-Forwarded-For` when deriving a client's address.
///
/// This is a property of the *deployment topology*, not of any one feature, so
/// it is resolved once and shared by every consumer that needs a client IP:
/// rate-limit bucketing, audit `sourceIP`, and an API key's `lastUsedIP`. They
/// used to each extract the address their own way — the rate limiter counting
/// hops in from the right, the other two taking the raw (leftmost,
/// client-controlled) value — which meant the same request could be attributed
/// to three different addresses, and two of the three were forgeable.
///
/// The environment variables keep their `RATE_LIMIT_` names because that is
/// what existing deployments already set (see `deploy/compose/setup.sh`); they
/// describe the proxy chain rather than the limiter.
struct ProxyTrustConfig: Sendable {
    /// Trust `X-Forwarded-For` at all. Correct when the control plane sits
    /// behind a trusted ingress (the supported deployment); disable if clients
    /// can reach it directly and could spoof the header.
    var trustForwardedFor: Bool

    /// Number of trusted proxy hops in front of the control plane. The client
    /// is read as the `trustedProxyHops`-th entry from the *right* of
    /// `X-Forwarded-For` — the address the outermost trusted proxy observed.
    ///
    /// - 1 (default): a single reverse proxy directly facing clients.
    /// - 2: an upstream TLS terminator in front of that proxy (the supported
    ///   HTTPS compose topology, which `setup.sh` configures).
    var trustedProxyHops: Int

    static func fromEnvironment() -> ProxyTrustConfig {
        ProxyTrustConfig(
            trustForwardedFor: Environment.get("RATE_LIMIT_TRUST_FORWARDED_FOR").flatMap(Bool.init) ?? true,
            trustedProxyHops: max(1, Environment.get("RATE_LIMIT_TRUSTED_PROXY_HOPS").flatMap(Int.init) ?? 1)
        )
    }

    /// The client address for a request, or nil when none can be determined.
    ///
    /// Counts `trustedProxyHops` in from the RIGHT of `X-Forwarded-For`: our own
    /// proxies append their peer on the right, so the rightmost hops are
    /// trustworthy and everything further left is client-supplied and
    /// spoofable. A chain shorter than expected (misconfigured hop count, or a
    /// request that didn't traverse every proxy) falls back to the socket peer
    /// rather than trusting a client-supplied entry.
    ///
    /// `X-Real-IP` is deliberately not consulted: behind an upstream TLS
    /// terminator nginx sets it to the terminator's address, which would
    /// collapse every client onto one value.
    func clientIP(headers: HTTPHeaders, remoteAddress: SocketAddress?) -> String? {
        if trustForwardedFor {
            let forwarded =
                headers.first(name: "X-Forwarded-For")?
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty } ?? []
            if forwarded.count >= trustedProxyHops {
                return forwarded[forwarded.count - trustedProxyHops]
            }
        }
        return remoteAddress?.ipAddress
    }
}

extension Application {
    private struct ProxyTrustConfigKey: StorageKey {
        typealias Value = ProxyTrustConfig
    }

    /// Set once in `configure`; falls back to the environment so services
    /// constructed in tests without a full `configure` still resolve sanely.
    var proxyTrust: ProxyTrustConfig {
        get { storage[ProxyTrustConfigKey.self] ?? .fromEnvironment() }
        set { setStorageValue(ProxyTrustConfigKey.self, to: newValue) }
    }
}

extension Request {
    /// The client address, honoring the configured proxy chain. Nil only when
    /// there is neither a usable forwarding header nor a socket peer.
    var trustedClientIP: String? {
        application.proxyTrust.clientIP(headers: headers, remoteAddress: remoteAddress)
    }
}
