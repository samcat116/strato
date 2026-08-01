import NIOPosix
import Testing
import Vapor

@testable import App

/// Directly exercises `SSRFGuard`, the shared allow/deny decision that backs
/// every server-side fetch in the control plane — image/artifact downloads
/// (`ImageFetchService`), and the OCI registry client (`RegistryClientService`,
/// which routes the manifest GET, the `/v2/` challenge probe, and the token
/// realm GET through it). A regression here would silently reopen SSRF on all
/// of them, so the classification is pinned here.
///
/// The addresses under test are IP literals: `getaddrinfo` resolves a literal
/// to itself, so these cases make no network or DNS calls.
@Suite("SSRFGuard")
struct SSRFGuardTests {
    private func withThreadPool(_ body: (NIOThreadPool) async throws -> Void) async throws {
        let pool = NIOThreadPool(numberOfThreads: 1)
        pool.start()
        do {
            try await body(pool)
        } catch {
            try await pool.shutdownGracefully()
            throw error
        }
        try await pool.shutdownGracefully()
    }

    /// Every non-public range a fetch might be steered at must be rejected in a
    /// production environment. `169.254.169.254` (cloud metadata) is the marquee
    /// case, alongside loopback, RFC1918, CGNAT, and IPv4-mapped IPv6.
    @Test("Blocks metadata, loopback, and private addresses in production")
    func blocksNonPublicHosts() async throws {
        let blocked = [
            "http://169.254.169.254/latest/meta-data/",  // link-local metadata
            "http://127.0.0.1/",  // loopback
            "http://10.0.0.5/x",  // RFC1918
            "http://172.16.9.9/",  // RFC1918
            "http://192.168.1.1/",  // RFC1918
            "http://100.64.0.1/",  // CGNAT
            "https://[::1]/",  // IPv6 loopback
            "http://[::ffff:169.254.169.254]/",  // IPv4-mapped metadata
            "http://0.0.0.0/",  // "this network"
        ]
        try await withThreadPool { pool in
            for raw in blocked {
                let url = try #require(URL(string: raw))
                await #expect(throws: SSRFGuard.BlockedHostError.self) {
                    try await SSRFGuard.validate(url: url, environment: .production, on: pool)
                }
            }
        }
    }

    /// A non-http(s) scheme (e.g. `file://`, `gopher://`) is rejected before any
    /// resolution — those are classic SSRF pivots.
    @Test("Rejects non-http(s) schemes")
    func rejectsNonHTTPSchemes() async throws {
        try await withThreadPool { pool in
            for raw in ["file:///etc/passwd", "gopher://127.0.0.1/", "ftp://example.com/"] {
                let url = try #require(URL(string: raw))
                await #expect(throws: SSRFGuard.BlockedHostError.self) {
                    try await SSRFGuard.validate(url: url, environment: .production, on: pool)
                }
            }
        }
    }

    /// A routable public literal passes and is returned for potential pinning.
    @Test("Allows a public address")
    func allowsPublicHost() async throws {
        try await withThreadPool { pool in
            let url = try #require(URL(string: "https://93.184.216.34/img"))  // routable public literal (no DNS)
            let approved = try await SSRFGuard.validate(url: url, environment: .production, on: pool)
            #expect(approved.contains("93.184.216.34"))
        }
    }

    /// In `.testing`/`.development`, private hosts are intentionally allowed so
    /// the redirect tests and local dev registries/mirrors work; validation
    /// short-circuits without resolving.
    @Test("Permits private hosts in development environments")
    func permitsPrivateHostsInDev() async throws {
        try await withThreadPool { pool in
            let url = try #require(URL(string: "http://127.0.0.1/"))
            let approved = try await SSRFGuard.validate(url: url, environment: .development, on: pool)
            #expect(approved.isEmpty)
        }
    }
}
