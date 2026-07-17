import Fluent
import Foundation
import NIOCore
import Testing
import Vapor

@testable import App

/// Exercises the real `ImageFetchService` download path (not the mock) against a
/// real HTTP server, because every mirror in the Popular images catalog is
/// reached through a redirector: Fedora, openSUSE and Rocky all answer with a
/// 302 to whichever mirror they pick, and Fedora picks a different one per
/// request. `downloadFile` checks `response.status == .ok`, so whether that
/// guard sees the 302 or the final 200 decides whether those imports work at
/// all. AsyncHTTPClient follows redirects by default, and this pins that: a
/// stray `.disallow`, or a config change upstream, would break the catalog.
@Suite("Image Fetch Redirect Tests", .serialized)
struct ImageFetchRedirectTests {

    /// Minimal qcow2: the 4-byte magic plus enough filler to look like a header.
    static func qcow2Bytes() -> [UInt8] {
        var bytes: [UInt8] = [0x51, 0x46, 0x49, 0xFB]
        bytes.append(contentsOf: [UInt8](repeating: 0x00, count: 508))
        return bytes
    }

    /// A bare Vapor app acting as the upstream mirror. Deliberately *not* the
    /// control-plane app: routes registered there sit behind its auth
    /// middleware and answer 401, which has nothing to do with the fetch path.
    private static func makeOriginApp(redirectHops: Int) async throws -> (Application, Int) {
        var env = Environment.testing
        env.arguments = ["vapor"]
        let origin = try await Application.make(env)
        origin.logger.logLevel = .error

        let payload = qcow2Bytes()
        origin.get("image.qcow2") { _ -> Response in
            Response(
                status: .ok,
                headers: ["Content-Type": "application/octet-stream"],
                body: .init(buffer: ByteBuffer(bytes: payload)))
        }
        // /redirect -> /hop/n -> ... -> /image.qcow2, the way a mirror
        // redirector bounces a request onward.
        origin.get("redirect") { _ -> Response in
            let target = redirectHops > 1 ? "/hop/\(redirectHops - 1)" : "/image.qcow2"
            return Response(status: .found, headers: ["Location": target])
        }
        origin.get("hop", ":n") { req -> Response in
            let n = req.parameters.get("n", as: Int.self) ?? 0
            let target = n > 1 ? "/hop/\(n - 1)" : "/image.qcow2"
            return Response(status: .found, headers: ["Location": target])
        }

        try await origin.server.start(address: .hostname("127.0.0.1", port: 0))
        guard let port = origin.http.server.shared.localAddress?.port else {
            try? await origin.server.shutdown()
            try await origin.asyncShutdown()
            throw ImageError.downloadFailed("origin server did not report a bound port")
        }
        return (origin, port)
    }

    /// Boots the control plane with the REAL fetch service, plus a separate
    /// origin server, and hands the test the origin's port.
    private func withFetchApp(
        redirectHops: Int = 1,
        _ test: (Application, Int) async throws -> Void
    ) async throws {
        let (origin, port) = try await Self.makeOriginApp(redirectHops: redirectHops)
        let app = try await Application.makeForTesting()
        let storagePath = NSTemporaryDirectory().appending("strato-fetch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            atPath: storagePath, withIntermediateDirectories: true)

        func teardown() async {
            try? await origin.server.shutdown()
            try? await origin.asyncShutdown()
            try? await app.asyncShutdown()
            try? FileManager.default.removeItem(atPath: storagePath)
        }

        do {
            try await configure(app)
            app.imageStoragePath = storagePath
            // Deliberately NOT the mock: the point is the real HTTP path.
            app.imageFetchService = ImageFetchService(app: app)
            try await app.autoMigrate()

            try await test(app, port)
        } catch {
            await teardown()
            throw error
        }
        await teardown()
    }

    /// Saves a pending image pointing at `sourceURL` and returns its id.
    private func makePendingImage(
        app: Application, sourceURL: String, expectedChecksum: String? = nil
    ) async throws -> UUID {
        let builder = TestDataBuilder(db: app.db)
        let user = try await builder.createUser()
        let org = try await builder.createOrganization()
        let project = try await builder.createProject(
            name: "Fetch Project", description: "", organization: org)

        let image = Image(
            name: "redirected",
            description: "",
            projectID: try project.requireID(),
            filename: "image.qcow2",
            architecture: .x86_64,
            status: .pending,
            uploadedByID: try user.requireID(),
            sourceURL: sourceURL
        )
        image.expectedChecksum = expectedChecksum
        try await image.save(on: app.db)
        return try image.requireID()
    }

    /// Polls until the image leaves the in-flight states, so the test doesn't
    /// race the detached fetch task.
    private func waitForTerminalStatus(
        app: Application, imageID: UUID, timeout: Duration = .seconds(10)
    ) async throws -> Image {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if let image = try await Image.find(imageID, on: app.db),
                image.status == .ready || image.status == .error
            {
                return image
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        let last = try await Image.find(imageID, on: app.db)
        Issue.record("Fetch did not settle; last status \(String(describing: last?.status))")
        throw ImageError.downloadFailed("timed out waiting for fetch")
    }

    @Test("A 302 to the real image is followed and the image becomes ready")
    func testFetchFollowsRedirect() async throws {
        try await withFetchApp { app, port in
            let imageID = try await makePendingImage(
                app: app, sourceURL: "http://127.0.0.1:\(port)/redirect")

            try await app.imageFetchService.startFetch(imageId: imageID)
            let image = try await waitForTerminalStatus(app: app, imageID: imageID)

            #expect(image.status == .ready)
            #expect(image.errorMessage == nil)
            #expect(image.format == .qcow2)
            #expect(image.size == Int64(Self.qcow2Bytes().count))
        }
    }

    @Test("A redirect chain is followed to the image")
    func testFetchFollowsRedirectChain() async throws {
        try await withFetchApp(redirectHops: 3) { app, port in
            let imageID = try await makePendingImage(
                app: app, sourceURL: "http://127.0.0.1:\(port)/redirect")

            try await app.imageFetchService.startFetch(imageId: imageID)
            let image = try await waitForTerminalStatus(app: app, imageID: imageID)

            #expect(image.status == .ready)
            #expect(image.format == .qcow2)
        }
    }

    /// The checksum guard added alongside the catalog, exercised against real
    /// bytes rather than a stored field.
    @Test("A redirected download still fails a mismatched checksum")
    func testRedirectedFetchVerifiesChecksum() async throws {
        try await withFetchApp { app, port in
            let imageID = try await makePendingImage(
                app: app,
                sourceURL: "http://127.0.0.1:\(port)/redirect",
                expectedChecksum: String(repeating: "0", count: 64))

            try await app.imageFetchService.startFetch(imageId: imageID)
            let image = try await waitForTerminalStatus(app: app, imageID: imageID)

            #expect(image.status == .error)
            #expect(image.errorMessage?.contains("Checksum verification failed") == true)
        }
    }

    @Test("A redirected download accepts a matching checksum")
    func testRedirectedFetchAcceptsMatchingChecksum() async throws {
        let expected = ImageValidationService.computeChecksum(
            from: ByteBuffer(bytes: Self.qcow2Bytes()))

        try await withFetchApp { app, port in
            let imageID = try await makePendingImage(
                app: app,
                sourceURL: "http://127.0.0.1:\(port)/redirect",
                expectedChecksum: expected)

            try await app.imageFetchService.startFetch(imageId: imageID)
            let image = try await waitForTerminalStatus(app: app, imageID: imageID)

            #expect(image.status == .ready)
            #expect(image.checksum == expected)
        }
    }
}
