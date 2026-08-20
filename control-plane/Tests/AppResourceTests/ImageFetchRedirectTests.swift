import Fluent
import Foundation
import NIOCore
import StratoShared
import Testing
import Vapor

import AppTestSupport
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
            await origin.server.shutdown()
            try await origin.asyncShutdown()
            throw ImageError.downloadFailed("origin server did not report a bound port")
        }
        return (origin, port)
    }

    /// Boots the control plane with the REAL fetch service, plus a separate
    /// origin server, and hands the test the origin's port.
    ///
    /// `approvedAddresses`, when set, installs a guarded client with a scripted
    /// address validator. That is the only way to exercise the connection pin
    /// from a test: under `.testing` the guard deliberately allows private
    /// hosts, so it approves nothing and there is nothing to pin.
    private func withFetchApp(
        redirectHops: Int = 1,
        approvedAddresses: [String]? = nil,
        _ test: (Application, Int) async throws -> Void
    ) async throws {
        let (origin, port) = try await Self.makeOriginApp(redirectHops: redirectHops)
        let app = try await Application.makeForTesting()
        let storagePath = NSTemporaryDirectory().appending("strato-fetch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            atPath: storagePath, withIntermediateDirectories: true)

        func teardown() async {
            await origin.server.shutdown()
            try? await origin.asyncShutdown()
            try? await app.asyncShutdown()
            try? FileManager.default.removeItem(atPath: storagePath)
        }

        do {
            try await configure(app)
            if let approvedAddresses {
                app.guardedHTTPClient = GuardedHTTPClient(
                    app: app, validator: { _ in approvedAddresses })
            }
            app.imageObjectStore = FilesystemImageObjectStore(rootPath: storagePath)
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

    /// Saves a pending disk artifact pointing at `sourceURL`.
    private func makePendingImage(
        app: Application, sourceURL: String, expectedChecksum: String? = nil
    ) async throws -> (imageID: UUID, artifactID: UUID) {
        let builder = TestDataBuilder(db: app.db)
        let user = try await builder.createUser()
        let org = try await builder.createOrganization()
        let project = try await builder.createProject(
            name: "Fetch Project", description: "", organization: org)

        let image = Image(
            name: "redirected",
            description: "",
            projectID: try project.requireID(),
            architecture: .x86_64,
            status: .pending,
            uploadedByID: try user.requireID()
        )
        try await image.save(on: app.db)
        let imageID = try image.requireID()
        let artifact = try await LegacyImageArtifactStore.insert(
            imageID: imageID,
            kind: .diskImage,
            format: nil,
            architecture: .x86_64,
            filename: "image.qcow2",
            size: 0,
            checksum: "",
            storagePath: ImageObjectKey.artifact(
                projectId: try project.requireID(), imageId: imageID,
                kind: ArtifactKind.diskImage.rawValue, filename: "image.qcow2"),
            status: .pending,
            sourceURL: sourceURL,
            expectedChecksum: expectedChecksum,
            on: app.db
        )
        return (imageID, artifact.id)
    }

    /// Polls until the image leaves the in-flight states, so the test doesn't
    /// race the detached fetch task.
    private func waitForTerminalStatus(
        app: Application, imageID: UUID, timeout: Duration = .seconds(10)
    ) async throws -> (Image, ImageArtifactSnapshot) {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if let image = try await LegacyImageStore.image(id: imageID, on: app.db),
                let artifact = try await LegacyImageArtifactStore.artifact(
                    imageID: imageID, kind: .diskImage, on: app.db),
                artifact.status == .ready || artifact.status == .error
            {
                return (image, artifact)
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        let last = try await LegacyImageStore.image(id: imageID, on: app.db)
        Issue.record("Fetch did not settle; last status \(String(describing: last?.status))")
        throw ImageError.downloadFailed("timed out waiting for fetch")
    }

    @Test("A 302 to the real image is followed and the image becomes ready")
    func testFetchFollowsRedirect() async throws {
        try await withFetchApp { app, port in
            let ids = try await makePendingImage(
                app: app, sourceURL: "http://127.0.0.1:\(port)/redirect")

            try await app.imageFetchService.startArtifactFetch(artifactId: ids.artifactID)
            let (image, artifact) = try await waitForTerminalStatus(app: app, imageID: ids.imageID)

            #expect(image.status == .ready)
            #expect(artifact.errorMessage == nil)
            #expect(artifact.format == .qcow2)
            #expect(artifact.size == Int64(Self.qcow2Bytes().count))
        }
    }

    @Test("A redirect chain is followed to the image")
    func testFetchFollowsRedirectChain() async throws {
        try await withFetchApp(redirectHops: 3) { app, port in
            let ids = try await makePendingImage(
                app: app, sourceURL: "http://127.0.0.1:\(port)/redirect")

            try await app.imageFetchService.startArtifactFetch(artifactId: ids.artifactID)
            let (image, artifact) = try await waitForTerminalStatus(app: app, imageID: ids.imageID)

            #expect(image.status == .ready)
            #expect(artifact.format == .qcow2)
        }
    }

    /// The checksum guard added alongside the catalog, exercised against real
    /// bytes rather than a stored field.
    @Test("A redirected download still fails a mismatched checksum")
    func testRedirectedFetchVerifiesChecksum() async throws {
        try await withFetchApp { app, port in
            let ids = try await makePendingImage(
                app: app,
                sourceURL: "http://127.0.0.1:\(port)/redirect",
                expectedChecksum: String(repeating: "0", count: 64))

            try await app.imageFetchService.startArtifactFetch(artifactId: ids.artifactID)
            let (image, artifact) = try await waitForTerminalStatus(app: app, imageID: ids.imageID)

            #expect(image.status == .error)
            #expect(artifact.errorMessage?.contains("Checksum verification failed") == true)
        }
    }

    /// The rebind simulation on the practically exploitable path. Validation
    /// approves `::1`; the host resolves to `127.0.0.1`, where the origin is
    /// serving the image. If the connection re-resolved the name instead of
    /// using the address that was validated, those bytes would land in the
    /// project's image object — an arbitrary internal GET with the response
    /// exfiltrated to whoever can then download or boot the image.
    @Test("A fetch connects to the validated address, not a re-resolved one")
    func testFetchPinsTheValidatedAddress() async throws {
        try await withFetchApp(approvedAddresses: ["::1"]) { app, port in
            let ids = try await makePendingImage(
                app: app, sourceURL: "http://localhost:\(port)/image.qcow2")

            try await app.imageFetchService.startArtifactFetch(artifactId: ids.artifactID)
            // Longer than the guarded client's connect timeout: the fetch settles
            // only once the connection to the pinned address has given up.
            let (image, artifact) = try await waitForTerminalStatus(
                app: app, imageID: ids.imageID, timeout: .seconds(20))

            #expect(image.status == .error)
            #expect(artifact.size == 0)
        }
    }

    /// The same path with the pin aimed where the origin actually is: every
    /// redirect hop gets its own pinned client (`dnsOverride` is fixed at
    /// client construction), so the chain must still complete.
    @Test("A pinned fetch follows its redirect chain to the image")
    func testPinnedFetchFollowsRedirectChain() async throws {
        try await withFetchApp(redirectHops: 2, approvedAddresses: ["127.0.0.1"]) { app, port in
            let ids = try await makePendingImage(
                app: app, sourceURL: "http://localhost:\(port)/redirect")

            try await app.imageFetchService.startArtifactFetch(artifactId: ids.artifactID)
            let (image, artifact) = try await waitForTerminalStatus(app: app, imageID: ids.imageID)

            #expect(image.status == .ready)
            #expect(artifact.format == .qcow2)
            #expect(artifact.size == Int64(Self.qcow2Bytes().count))
        }
    }

    @Test("A redirected download accepts a matching checksum")
    func testRedirectedFetchAcceptsMatchingChecksum() async throws {
        let expected = ImageValidationService.computeChecksum(
            from: ByteBuffer(bytes: Self.qcow2Bytes()))

        try await withFetchApp { app, port in
            let ids = try await makePendingImage(
                app: app,
                sourceURL: "http://127.0.0.1:\(port)/redirect",
                expectedChecksum: expected)

            try await app.imageFetchService.startArtifactFetch(artifactId: ids.artifactID)
            let (image, artifact) = try await waitForTerminalStatus(app: app, imageID: ids.imageID)

            #expect(image.status == .ready)
            #expect(artifact.checksum == expected)
        }
    }
}
