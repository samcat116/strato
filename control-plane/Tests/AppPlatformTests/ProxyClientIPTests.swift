import NIOCore
import Testing
import Vapor

@testable import App

/// Pins the single client-IP resolution shared by rate-limit bucketing, audit
/// `sourceIP`, and API-key `lastUsedIP`.
///
/// The hop count is the whole point: the supported HTTPS compose topology runs
/// an nginx behind a TLS terminator and sets `RATE_LIMIT_TRUSTED_PROXY_HOPS=2`
/// (`deploy/compose/setup.sh`). Reading an unconditional rightmost entry there
/// records the *inner proxy's* address for every request, which is as useless
/// for attribution as trusting the client-supplied leftmost one is unsafe.
@Suite("Proxy client IP")
struct ProxyClientIPTests {
    private var peer: SocketAddress? {
        try? SocketAddress(ipAddress: "203.0.113.9", port: 443)
    }

    private func headers(_ forwardedFor: String?) -> HTTPHeaders {
        var headers = HTTPHeaders()
        if let forwardedFor {
            headers.add(name: "X-Forwarded-For", value: forwardedFor)
        }
        return headers
    }

    /// One proxy: it appends the real peer, so the last entry is the client and
    /// everything left of it is attacker-supplied padding.
    @Test("Single hop takes the rightmost entry, ignoring spoofed prefixes")
    func singleHopTakesRightmost() {
        let config = ProxyTrustConfig(trustForwardedFor: true, trustedProxyHops: 1)
        let resolved = config.clientIP(
            headers: headers("1.2.3.4, 198.51.100.7"), remoteAddress: peer)
        #expect(resolved == "198.51.100.7")
    }

    /// Two hops (the supported HTTPS compose stack): the terminator appends the
    /// client, nginx then appends the terminator — so the client is second from
    /// the right. Taking the last entry would yield the terminator instead.
    @Test("Two hops take the second-from-right entry, not the inner proxy")
    func twoHopsSkipInnerProxy() {
        let config = ProxyTrustConfig(trustForwardedFor: true, trustedProxyHops: 2)
        let resolved = config.clientIP(
            headers: headers("1.2.3.4, 198.51.100.7, 10.0.0.2"), remoteAddress: peer)
        #expect(resolved == "198.51.100.7")
    }

    /// A chain shorter than the configured hop count means the request didn't
    /// traverse every proxy (or the count is misconfigured). Fall back to the
    /// socket peer rather than trusting whatever the client put in the header.
    @Test("Short chain falls back to the socket peer")
    func shortChainFallsBackToPeer() {
        let config = ProxyTrustConfig(trustForwardedFor: true, trustedProxyHops: 2)
        let resolved = config.clientIP(headers: headers("1.2.3.4"), remoteAddress: peer)
        #expect(resolved == "203.0.113.9")
    }

    /// With no trusted proxy in front, the header is entirely client-controlled
    /// and must be ignored.
    @Test("Untrusted forwarding header is ignored entirely")
    func untrustedHeaderIgnored() {
        let config = ProxyTrustConfig(trustForwardedFor: false, trustedProxyHops: 1)
        let resolved = config.clientIP(
            headers: headers("1.2.3.4, 198.51.100.7"), remoteAddress: peer)
        #expect(resolved == "203.0.113.9")
    }

    @Test("Whitespace and empty entries in the chain are tolerated")
    func toleratesMessyChains() {
        let config = ProxyTrustConfig(trustForwardedFor: true, trustedProxyHops: 1)
        let resolved = config.clientIP(
            headers: headers(" 1.2.3.4 ,, 198.51.100.7 ,"), remoteAddress: peer)
        #expect(resolved == "198.51.100.7")
    }

    @Test("No header and no peer resolves to nil")
    func noSourcesResolvesToNil() {
        let config = ProxyTrustConfig(trustForwardedFor: true, trustedProxyHops: 1)
        #expect(config.clientIP(headers: headers(nil), remoteAddress: nil) == nil)
    }

    /// The hop count is floored at 1 — a `0` would index off the right end of
    /// the chain.
    @Test("Hop count is floored at one")
    func hopCountFloor() {
        #expect(ProxyTrustConfig.fromEnvironment().trustedProxyHops >= 1)
    }
}
