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

    /// Registers `name` as an agent row and grants it `image`, standing in for
    /// the desired-state sync that would have handed it the download URLs
    /// (issue #562). The route serves an agent only images it holds a grant
    /// for, so every success path here needs one.
    private func grantImage(app: Application, agentName: String, image: Image) async throws {
        let agent = Agent(
            name: agentName,
            hostname: "\(agentName).test",
            version: "1.0.0",
            capabilities: ["qemu"],
            status: .online,
            resources: AgentResources(
                totalCPU: 8, availableCPU: 8,
                totalMemory: 1 << 33, availableMemory: 1 << 33,
                totalDisk: 1 << 40, availableDisk: 1 << 40
            )
        )
        try await agent.save(on: app.db)
        await app.coordination.grantImageDownload(agentId: agent.id!.uuidString, imageId: image.id!)
    }

    /// A ready image whose bytes live in the app's object store, plus the
    /// content the download should stream back.
    /// `suffix` distinguishes a second image in the same test (unique username,
    /// email, and object key).
    private func makeReadyImage(app: Application, suffix: String = "") async throws -> (
        project: Project, image: Image, bytes: String
    ) {
        let builder = TestDataBuilder(db: app.db)
        let user = try await builder.createUser(username: "dl-user\(suffix)", email: "dl\(suffix)@example.com")
        let org = try await builder.createOrganization(name: "DL Org\(suffix)")
        let project = try await builder.createProject(
            name: "DL Project\(suffix)", description: "image download tests", organization: org)

        let bytes = "image bytes served over agent mTLS"
        let key = "dl-tests/disk\(suffix).qcow2"
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

    @Test("An agent SVID identity downloads an image it was assigned")
    func agentIdentityDownloads() async throws {
        try await withRunningImageApp { app, port in
            self.enableSPIRE(on: app)
            let (project, image, bytes) = try await self.makeReadyImage(app: app)
            try await self.grantImage(app: app, agentName: "dl-agent", image: image)

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
            try await self.grantImage(app: app, agentName: "dl-agent", image: image)

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

    @Test("A client certificate forwarded by a non-loopback peer is refused")
    func xfccFromNonLoopbackPeerRefused() async throws {
        guard let hostIP = nonLoopbackIPv4() else {
            // Nothing but loopback on this host, so the rejection path cannot
            // be reached; the accept path above still covers the check.
            return
        }

        try await withRunningImageApp { app, port in
            self.enableSPIRE(on: app)
            let (project, image, _) = try await self.makeReadyImage(app: app)
            // Granted, so a rejection here can only be the provenance check.
            try await self.grantImage(app: app, agentName: "dl-agent", image: image)

            // Only the co-located Envoy sidecar forwards on loopback. The very
            // same header from anywhere else is a spoofing attempt: an
            // attacker who can reach the control plane's plain HTTP listener
            // must not be able to mint an agent identity by setting a header.
            let header = self.xfccHeader(identity: "agent/dl-agent")
            let response = try await app.client.get(
                URI(string: "http://\(hostIP):\(port)\(self.downloadPath(project: project, image: image))")
            ) { req in
                req.headers.add(name: header.name, value: header.value)
            }

            #expect(response.status == .forbidden)
        }
    }

    @Test("An agent is refused an image it was never assigned")
    func unassignedImageRefused() async throws {
        try await withRunningImageApp { app, port in
            self.enableSPIRE(on: app)
            let (project, image, _) = try await self.makeReadyImage(app: app)

            // Enrolled and authenticated, but holding no claim on this image:
            // before issue #562 any agent identity could pull any ready image
            // in any project given the UUIDs.
            let other = try await self.makeReadyImage(app: app, suffix: "-other")
            try await self.grantImage(app: app, agentName: "dl-agent", image: other.image)

            let header = self.xfccHeader(identity: "agent/dl-agent")
            let response = try await app.client.get(
                URI(string: "http://127.0.0.1:\(port)\(self.downloadPath(project: project, image: image))")
            ) { req in
                req.headers.add(name: header.name, value: header.value)
            }

            #expect(response.status == .forbidden)
        }
    }

    @Test("An agent identity with no registered agent is refused")
    func unregisteredAgentRefused() async throws {
        try await withRunningImageApp { app, port in
            self.enableSPIRE(on: app)
            let (project, image, _) = try await self.makeReadyImage(app: app)

            // A valid SVID for a node that enrolled but never registered holds
            // no placements, so it can hold no grant either.
            let header = self.xfccHeader(identity: "agent/never-registered")
            let response = try await app.client.get(
                URI(string: "http://127.0.0.1:\(port)\(self.downloadPath(project: project, image: image))")
            ) { req in
                req.headers.add(name: header.name, value: header.value)
            }

            #expect(response.status == .forbidden)
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

        // Bound on 0.0.0.0 rather than 127.0.0.1 so a test can also reach the
        // server on a non-loopback address and exercise the rejection path.
        try await app.server.start(address: .hostname("0.0.0.0", port: 0))

        // `defer` cannot hold an `await`, so the outcome is captured and
        // rethrown after the one shutdown that every path runs through —
        // leaving the server up would strand it until app teardown and invite
        // the ServeCommand deinit race.
        let outcome: Result<Void, any Error>
        do {
            let port = try #require(
                app.http.server.shared.localAddress?.port, "HTTP server did not report a bound port")
            try await test(app, port)
            outcome = .success(())
        } catch {
            outcome = .failure(error)
        }
        await app.server.shutdown()
        try outcome.get()
    }
}

/// A non-loopback IPv4 address of this host, or nil when there isn't one (a
/// network-isolated CI container). Used to prove the XFCC provenance check
/// rejects a peer that did not arrive from the pod-local sidecar.
private func nonLoopbackIPv4() -> String? {
    for device in (try? System.enumerateDevices()) ?? [] {
        guard let address = device.address, case .v4 = address, let ip = address.ipAddress else { continue }
        guard !ip.hasPrefix("127.") else { continue }
        return ip
    }
    return nil
}
