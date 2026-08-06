import NIOConcurrencyHelpers
import NIOCore
import Testing
import Vapor

@testable import App

/// Exercises `GuardedHTTPClient` — the single outbound path every
/// tenant-influenced fetch goes through — against a real origin server.
///
/// The property under test is that **the address validated is the address
/// connected to**: `SSRFGuard` classifying a host is worthless if the connect
/// then re-resolves the name, because a low-TTL record can rebind it to an
/// internal address in between. That is not reproducible with real DNS, so the
/// tests inject the address validator and approve an address the URL's host
/// does *not* resolve to. If the pin works, the origin — sitting at the address
/// the name really resolves to — never sees the request.
///
/// `[::1]` is the stand-in for "an approved address with nothing behind it":
/// the origin binds `127.0.0.1` only, so a connection aimed at IPv6 loopback on
/// the same port is refused rather than silently succeeding.
@Suite("Guarded HTTP Client", .serialized)
struct GuardedHTTPClientTests {
    /// An origin server on `127.0.0.1` that counts the requests that actually
    /// reached it, plus a second bare application to host the client under test.
    private func withOrigin(
        _ test: (Application, Int, NIOLockedValueBox<Int>) async throws -> Void
    ) async throws {
        var env = Environment.testing
        env.arguments = ["vapor"]

        let origin = try await Application.make(env)
        origin.logger.logLevel = .error
        let hits = NIOLockedValueBox(0)
        origin.get("ping") { _ -> String in
            hits.withLockedValue { $0 += 1 }
            return "pong"
        }
        try await origin.server.start(address: .hostname("127.0.0.1", port: 0))

        let app = try await Application.make(env)
        app.logger.logLevel = .error

        func teardown() async {
            await origin.server.shutdown()
            try? await origin.asyncShutdown()
            try? await app.asyncShutdown()
        }

        do {
            guard let port = origin.http.server.shared.localAddress?.port else {
                Issue.record("origin server did not report a bound port")
                await teardown()
                return
            }
            try await test(app, port, hits)
        } catch {
            await teardown()
            throw error
        }
        await teardown()
    }

    /// A generous request timeout on purpose: the client's own (shorter)
    /// connect timeout should be what a dead address trips, not the caller's
    /// deadline — only the former is classified as a connect failure.
    private func get(_ url: String, timeout: TimeAmount = .seconds(30)) -> ClientRequest {
        ClientRequest(method: .GET, url: URI(string: url), headers: [:], body: nil, timeout: timeout)
    }

    /// The rebind simulation: validation approves `::1`, the URL's host resolves
    /// to `127.0.0.1` where the origin is listening. The fetch must fail rather
    /// than reach the origin — the connection followed the validated address,
    /// not a second, independent resolution of the name.
    @Test("Connects to the validated address, not a re-resolution of the name")
    func pinsTheValidatedAddress() async throws {
        try await withOrigin { app, port, hits in
            app.guardedHTTPClient = GuardedHTTPClient(app: app, validator: { _ in ["::1"] })

            await #expect(throws: (any Error).self) {
                try await app.guardedHTTPClient.send(self.get("http://localhost:\(port)/ping"))
            }
            #expect(hits.withLockedValue { $0 } == 0)
        }
    }

    /// The `dnsOverride` key is matched against the host AsyncHTTPClient parses
    /// out of the request URL, so a host that differs only in case would miss
    /// the pin — and the connection would resolve the name fresh while
    /// validation still "passed". A missed pin here would show up as a *hit* on
    /// the origin, because `LOCALHOST` resolves to where it is listening.
    @Test("Pin is not defeated by host case")
    func pinMatchesRegardlessOfHostCase() async throws {
        try await withOrigin { app, port, hits in
            app.guardedHTTPClient = GuardedHTTPClient(app: app, validator: { _ in ["::1"] })

            await #expect(throws: (any Error).self) {
                try await app.guardedHTTPClient.send(self.get("http://LOCALHOST:\(port)/ping"))
            }
            #expect(hits.withLockedValue { $0 } == 0)
        }
    }

    /// `dnsOverride` takes one address per host, so pinning to the first
    /// approved address alone would turn a dead address into an outage — for a
    /// multi-gigabyte image download, a new availability failure mode. The
    /// remaining approved addresses are tried when the connection cannot be
    /// established.
    @Test("A dead first address falls over to the next approved address")
    func failsOverToNextApprovedAddress() async throws {
        try await withOrigin { app, port, hits in
            app.guardedHTTPClient = GuardedHTTPClient(
                app: app, validator: { _ in ["::1", "127.0.0.1"] })

            let response = try await app.guardedHTTPClient.send(
                self.get("http://localhost:\(port)/ping"))

            #expect(response.status == .ok)
            #expect(response.body.map { String(buffer: $0) } == "pong")
            #expect(hits.withLockedValue { $0 } == 1)
        }
    }

    /// A `user:pass@host` URL is where two parsers are most likely to disagree
    /// about which part is the host — exactly the case that makes a pin miss
    /// silently — and no guarded fetch needs credentials in the URL.
    @Test("Rejects a URL with embedded credentials")
    func rejectsEmbeddedCredentials() async throws {
        try await withOrigin { app, port, hits in
            app.guardedHTTPClient = GuardedHTTPClient(app: app, validator: { _ in ["127.0.0.1"] })

            await #expect(throws: SSRFGuard.BlockedHostError.self) {
                try await app.guardedHTTPClient.send(
                    self.get("http://user:pass@localhost:\(port)/ping"))
            }
            #expect(hits.withLockedValue { $0 } == 0)
        }
    }

    /// When the guard approves nothing there is nothing to pin to — that only
    /// happens where private hosts are deliberately allowed
    /// (`.testing`/`.development`, or `IMAGE_FETCH_ALLOW_PRIVATE_HOSTS`). The
    /// fetch still goes out, through `app.client`, so a scripted client
    /// installed by a test is still honored.
    @Test("Falls back to the shared client when there is nothing to pin")
    func fallsBackWhenNothingToPin() async throws {
        try await withOrigin { app, port, hits in
            app.guardedHTTPClient = GuardedHTTPClient(app: app, validator: { _ in [] })

            let response = try await app.guardedHTTPClient.send(
                self.get("http://localhost:\(port)/ping"))

            #expect(response.status == .ok)
            #expect(hits.withLockedValue { $0 } == 1)
        }
    }

    /// A host that is already an IP literal has no name to rebind, so it takes
    /// the unpinned path — and must still reach its destination.
    @Test("An IP-literal host needs no pin and still connects")
    func ipLiteralHostConnects() async throws {
        try await withOrigin { app, port, hits in
            app.guardedHTTPClient = GuardedHTTPClient(app: app, validator: { _ in ["127.0.0.1"] })

            let response = try await app.guardedHTTPClient.send(
                self.get("http://127.0.0.1:\(port)/ping"))

            #expect(response.status == .ok)
            #expect(hits.withLockedValue { $0 } == 1)
        }
    }
}
