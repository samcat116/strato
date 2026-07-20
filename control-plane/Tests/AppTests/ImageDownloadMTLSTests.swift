import Fluent
import Foundation
import NIOCore
import StratoShared
import Testing
import Vapor

@testable import App

/// End-to-end tests for the SVID-mTLS-authenticated image download route
/// (issue #493). Agents fetch image bytes with their SPIFFE SVID as the
/// client certificate; Envoy terminates the mTLS and forwards the verified
/// identity in `X-Forwarded-Client-Cert`, which the controller re-verifies.
///
/// These bind a real HTTP server on an ephemeral loopback port because the
/// XFCC trust check requires provenance from the pod-local sidecar: the header
/// is only accepted from a loopback peer, and Vapor's in-memory `test()`
/// harness has no remote address at all, so both the accept and reject paths
/// need a genuine socket.
@Suite("Image download over agent mTLS", .serialized)
struct ImageDownloadMTLSTests {

    /// Enable SPIRE mTLS auth without a trust bundle: with
    /// `hasTrustBundle == false` the XFCC `URI=` alone establishes identity
    /// (relying on Envoy's own verification), which is what these tests drive.
    private func enableSPIRE(on app: Application) {
        let config = SPIREServiceConfig(
            enabled: true,
            trustDomain: "strato.local"
        )
        app.spireService = SPIREService(config: config, logger: app.logger, httpClient: app.client)
    }

    private func xfccHeader(identity: String) -> (name: String, value: String) {
        ("X-Forwarded-Client-Cert", "URI=spiffe://strato.local/\(identity)")
    }

    /// A ready image whose bytes live in the app's object store, plus the
    /// content the download should stream back.
    private func makeReadyImage(app: Application) async throws -> (project: Project, image: Image, bytes: String) {
        let builder = TestDataBuilder(db: app.db)
        let user = try await builder.createUser(username: "dl-user", email: "dl@example.com")
        let org = try await builder.createOrganization(name: "DL Org")
        let project = try await builder.createProject(
            name: "DL Project", description: "image download tests", organization: org)

        let bytes = "image bytes served over agent mTLS"
        let key = "dl-tests/disk.qcow2"
        let writer = try await app.imageObjectStore.openWriter(key: key)
        try await writer.write(ByteBuffer(string: bytes))
        try await writer.finish()

        let image = try await builder.createImage(
            project: project,
            size: Int64(bytes.utf8.count),
            uploadedBy: user,
            storagePath: key
        )
        return (project, image, bytes)
    }

    private func downloadPath(project: Project, image: Image) -> String {
        "/api/projects/\(project.id!)/images/\(image.id!)/download"
    }

    @Test("An agent SVID identity downloads image bytes")
    func agentIdentityDownloads() async throws {
        try await withRunningImageApp { app, port in
            self.enableSPIRE(on: app)
            let (project, image, bytes) = try await self.makeReadyImage(app: app)

            let header = self.xfccHeader(identity: "agent/dl-agent")
            let response = try await app.client.get(
                URI(string: "http://127.0.0.1:\(port)\(self.downloadPath(project: project, image: image))")
            ) { req in
                req.headers.add(name: header.name, value: header.value)
            }

            #expect(response.status == .ok)
            let body = response.body.map { String(buffer: $0) } ?? ""
            #expect(body == bytes)
        }
    }

    @Test("A non-agent SPIFFE identity is refused")
    func nonAgentIdentityRefused() async throws {
        try await withRunningImageApp { app, port in
            self.enableSPIRE(on: app)
            let (project, image, _) = try await self.makeReadyImage(app: app)

            // Trust-domain membership is not enough: the control plane's own
            // identity must not be able to pull tenant images.
            let header = self.xfccHeader(identity: "control-plane")
            let response = try await app.client.get(
                URI(string: "http://127.0.0.1:\(port)\(self.downloadPath(project: project, image: image))")
            ) { req in
                req.headers.add(name: header.name, value: header.value)
            }

            #expect(response.status == .forbidden)
        }
    }

    @Test("An agent asking for an artifact kind the image lacks gets 404")
    func missingArtifactKindIs404() async throws {
        try await withRunningImageApp { app, port in
            self.enableSPIRE(on: app)
            let (project, image, _) = try await self.makeReadyImage(app: app)

            let header = self.xfccHeader(identity: "agent/dl-agent")
            let response = try await app.client.get(
                URI(
                    string:
                        "http://127.0.0.1:\(port)\(self.downloadPath(project: project, image: image))?artifact=kernel"
                )
            ) { req in
                req.headers.add(name: header.name, value: header.value)
            }

            #expect(response.status == .notFound)
        }
    }

    @Test("A request with neither certificate nor session is unauthorized")
    func noCredentialIsUnauthorized() async throws {
        try await withRunningImageApp { app, port in
            self.enableSPIRE(on: app)
            let (project, image, _) = try await self.makeReadyImage(app: app)

            let response = try await app.client.get(
                URI(string: "http://127.0.0.1:\(port)\(self.downloadPath(project: project, image: image))"))

            #expect(response.status == .unauthorized)
        }
    }

    @Test("A client certificate is refused when SPIRE is not configured")
    func xfccWithoutSPIRERefused() async throws {
        try await withRunningImageApp { app, port in
            // No enableSPIRE: nothing an agent presents can authenticate here,
            // so this is surfaced as operator misconfiguration, not 403.
            let (project, image, _) = try await self.makeReadyImage(app: app)

            let header = self.xfccHeader(identity: "agent/dl-agent")
            let response = try await app.client.get(
                URI(string: "http://127.0.0.1:\(port)\(self.downloadPath(project: project, image: image))")
            ) { req in
                req.headers.add(name: header.name, value: header.value)
            }

            #expect(response.status == .serviceUnavailable)
        }
    }
}

// MARK: - Running-server harness with object-backed image storage

/// Like the agent WebSocket suites' running-app harness, plus a temp-directory
/// object store so download responses have real bytes to stream.
private func withRunningImageApp(_ test: (Application, Int) async throws -> Void) async throws {
    try await withApp { app in
        let tempStorage = NSTemporaryDirectory() + "strato-dl-mtls-tests-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: tempStorage, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tempStorage) }
        app.imageObjectStore = FilesystemImageObjectStore(rootPath: tempStorage)

        try await app.server.start(address: .hostname("127.0.0.1", port: 0))
        do {
            guard let port = app.http.server.shared.localAddress?.port else {
                Issue.record("HTTP server did not report a bound port")
                await app.server.shutdown()
                return
            }
            try await test(app, port)
        } catch {
            await app.server.shutdown()
            throw error
        }
        await app.server.shutdown()
    }
}
