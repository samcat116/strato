import Foundation
import Logging
import StratoShared
import Testing

@testable import StratoAgentCore

/// End-to-end materialization against a scripted registry: manifest (and
/// index) resolution, config staging, layer flattening with whiteouts, image
/// build, digest cache, and index aliases — everything but real ext4
/// formatting, which `RecordingImageBuilder` stands in for (covered by
/// `Ext4ImageBuilderTests`).
@Suite("Sandbox Image Service")
struct SandboxImageServiceTests {

    private let image = "registry.example.com/acme/app:v1"
    private let apiBase = "https://registry.example.com/v2/acme/app"

    private func makeTempDir() throws -> String {
        let dir = NSTemporaryDirectory() + "sandbox-image-tests-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A two-layer fixture image: layer 2 replaces a file and whites out
    /// another, exercising ordering and whiteouts through the whole pipeline.
    private struct Fixture {
        let manifestData: Data
        let manifestDigest: String
        let configDigest: String
        let layerDigests: [String]
        let blobs: [String: Data]  // digest → bytes
        let guestConfigEntrypoint: [String]
    }

    private func makeFixture() throws -> Fixture {
        let configJSON = """
            {"architecture":"arm64","os":"linux","config":{
             "Env":["PATH=/usr/bin","MODE=fixture"],
             "Entrypoint":["/bin/app"],"Cmd":["--serve"],
             "WorkingDir":"/srv","User":"1000:1000"}}
            """
        let configData = Data(configJSON.utf8)
        let configDigest = testSHA256Digest(of: configData)

        var layer1 = TarTestBuilder()
        layer1.addDirectory("app")
        layer1.addFile("app/hello.txt", content: Data("from-layer-1".utf8))
        layer1.addFile("replace.txt", content: Data("old".utf8))
        let layer1Data = layer1.finish()

        var layer2 = TarTestBuilder()
        layer2.addFile("replace.txt", content: Data("new".utf8))
        layer2.addFile("app/.wh.hello.txt", content: Data())
        let layer2Data = layer2.finish()

        let layer1Digest = testSHA256Digest(of: layer1Data)
        let layer2Digest = testSHA256Digest(of: layer2Data)

        let manifest = OCIManifest(
            config: OCIDescriptor(
                mediaType: OCIMediaType.ociConfig, digest: configDigest, size: Int64(configData.count)),
            layers: [
                OCIDescriptor(
                    mediaType: "application/vnd.oci.image.layer.v1.tar", digest: layer1Digest,
                    size: Int64(layer1Data.count)),
                OCIDescriptor(
                    mediaType: "application/vnd.oci.image.layer.v1.tar", digest: layer2Digest,
                    size: Int64(layer2Data.count)),
            ])
        let manifestData = try JSONEncoder().encode(manifest)

        return Fixture(
            manifestData: manifestData,
            manifestDigest: testSHA256Digest(of: manifestData),
            configDigest: configDigest,
            layerDigests: [layer1Digest, layer2Digest],
            blobs: [configDigest: configData, layer1Digest: layer1Data, layer2Digest: layer2Data],
            guestConfigEntrypoint: ["/bin/app"]
        )
    }

    private func scriptBlobs(_ fixture: Fixture, on transport: MockOCITransport) async {
        for (digest, bytes) in fixture.blobs {
            await transport.script("\(apiBase)/blobs/\(digest)", .init(status: 200, body: bytes))
        }
    }

    private func makeService(
        cacheRoot: String, transport: MockOCITransport, builder: RecordingImageBuilder
    ) -> SandboxImageService {
        var configuration = OCIRegistryClient.Configuration()
        configuration.retryBaseDelay = .milliseconds(1)
        return SandboxImageService(
            logger: Logger(label: "test"),
            cacheRootPath: cacheRoot,
            transport: transport,
            clientConfiguration: configuration,
            imageBuilder: builder
        )
    }

    @Test("materializes a rootfs end to end and caches it by digest")
    func fullMaterialization() async throws {
        let cacheRoot = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: cacheRoot) }

        let fixture = try makeFixture()
        let transport = MockOCITransport()
        await transport.script(
            "\(apiBase)/manifests/v1",
            .init(
                status: 200, headers: ["Content-Type": OCIMediaType.ociManifest],
                body: fixture.manifestData))
        await scriptBlobs(fixture, on: transport)

        let builder = RecordingImageBuilder()
        let service = makeService(cacheRoot: cacheRoot, transport: transport, builder: builder)

        let result = try await service.materializeRootfs(image: image)

        #expect(result.manifestDigest == fixture.manifestDigest)
        #expect(result.guestConfig.entrypoint == ["/bin/app"])
        #expect(result.guestConfig.cmd == ["--serve"])
        #expect(result.guestConfig.env == ["PATH=/usr/bin", "MODE=fixture"])
        #expect(result.guestConfig.workingDir == "/srv")
        #expect(result.guestConfig.user == "1000:1000")

        // The staged config decodes back to the same guest config.
        let stagedData = FileManager.default.contents(atPath: result.configPath)
        let staged = try JSONDecoder().decode(SandboxGuestConfig.self, from: stagedData ?? Data())
        #expect(staged == result.guestConfig)

        // The flattened tree the builder saw: layer 2 replaced and whited out.
        let tree = await builder.snapshots.first
        #expect(tree?["replace.txt"] == "new")
        #expect(tree?["app/hello.txt"] == nil)
        #expect(tree?.keys.contains("app/.wh.hello.txt") == false)

        // Work directory cleaned up; rootfs published into the cache.
        let workEntries = try? FileManager.default.contentsOfDirectory(atPath: cacheRoot + "/work")
        #expect(workEntries?.isEmpty ?? true)
        #expect(result.rootfsPath.hasSuffix("rootfs.ext4"))
        #expect(FileManager.default.fileExists(atPath: result.rootfsPath))

        // Second materialization: the tag is mutable so the manifest is
        // re-resolved (exactly one request), but the digest hits the cache —
        // no blob traffic and no rebuild.
        let requestsBefore = await transport.requests.count
        let second = try await service.materializeRootfs(image: image)
        let requestsAfter = await transport.requests.count
        #expect(second.rootfsPath == result.rootfsPath)
        #expect(requestsAfter == requestsBefore + 1)
        let buildCount = await builder.snapshots.count
        #expect(buildCount == 1)
    }

    @Test("a pinned index digest narrows once, then hits the cache offline")
    func indexPinAlias() async throws {
        let cacheRoot = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: cacheRoot) }

        let fixture = try makeFixture()
        let index = OCIIndex(manifests: [
            OCIDescriptor(
                mediaType: OCIMediaType.ociManifest, digest: fixture.manifestDigest,
                size: Int64(fixture.manifestData.count),
                platform: OCIPlatform(architecture: "arm64", os: "linux")),
            OCIDescriptor(
                mediaType: OCIMediaType.ociManifest,
                digest: "sha256:" + String(repeating: "a", count: 64), size: 1,
                platform: OCIPlatform(architecture: "amd64", os: "linux")),
        ])
        let indexData = try JSONEncoder().encode(index)
        let indexDigest = testSHA256Digest(of: indexData)

        let transport = MockOCITransport()
        await transport.script(
            "\(apiBase)/manifests/\(indexDigest)",
            .init(status: 200, headers: ["Content-Type": OCIMediaType.ociIndex], body: indexData))
        await transport.script(
            "\(apiBase)/manifests/\(fixture.manifestDigest)",
            .init(
                status: 200, headers: ["Content-Type": OCIMediaType.ociManifest],
                body: fixture.manifestData))
        await scriptBlobs(fixture, on: transport)

        let builder = RecordingImageBuilder()
        let service = makeService(cacheRoot: cacheRoot, transport: transport, builder: builder)

        let result = try await service.materializeRootfs(
            image: image, imageDigest: indexDigest, architecture: .arm64)
        #expect(result.manifestDigest == fixture.manifestDigest)

        // Same pin again: served from cache through the alias, offline.
        let requestsBefore = await transport.requests.count
        let second = try await service.materializeRootfs(
            image: image, imageDigest: indexDigest, architecture: .arm64)
        let requestsAfter = await transport.requests.count
        #expect(second.manifestDigest == fixture.manifestDigest)
        #expect(requestsAfter == requestsBefore)
    }

    @Test("an unsupported layer media type fails before any blob is fetched")
    func unsupportedLayer() async throws {
        let cacheRoot = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: cacheRoot) }

        let manifest = OCIManifest(
            config: OCIDescriptor(
                mediaType: OCIMediaType.ociConfig,
                digest: "sha256:" + String(repeating: "b", count: 64), size: 2),
            layers: [
                OCIDescriptor(
                    mediaType: "application/vnd.oci.image.layer.v1.squashfs",
                    digest: "sha256:" + String(repeating: "c", count: 64), size: 10)
            ])
        let manifestData = try JSONEncoder().encode(manifest)

        let transport = MockOCITransport()
        await transport.script(
            "\(apiBase)/manifests/v1",
            .init(status: 200, headers: ["Content-Type": OCIMediaType.ociManifest], body: manifestData))

        let service = makeService(
            cacheRoot: cacheRoot, transport: transport, builder: RecordingImageBuilder())
        do {
            _ = try await service.materializeRootfs(image: image)
            Issue.record("expected unsupportedMediaType")
        } catch let error as OCIError {
            guard case .unsupportedMediaType = error else {
                Issue.record("expected unsupportedMediaType, got \(error)")
                return
            }
        }
        // Only the manifest was requested — no blob traffic for a doomed pull.
        let requests = await transport.requests
        #expect(requests.count == 1)
    }

    @Test("a preposterously large image fails the free-space precheck up front")
    func freeSpacePrecheck() async throws {
        let cacheRoot = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: cacheRoot) }

        let manifest = OCIManifest(
            config: OCIDescriptor(
                mediaType: OCIMediaType.ociConfig,
                digest: "sha256:" + String(repeating: "b", count: 64), size: 2),
            layers: [
                OCIDescriptor(
                    mediaType: "application/vnd.oci.image.layer.v1.tar",
                    digest: "sha256:" + String(repeating: "c", count: 64),
                    size: 1 << 60)  // an exbibyte of compressed layer
            ])
        let manifestData = try JSONEncoder().encode(manifest)

        let transport = MockOCITransport()
        await transport.script(
            "\(apiBase)/manifests/v1",
            .init(status: 200, headers: ["Content-Type": OCIMediaType.ociManifest], body: manifestData))

        let service = makeService(
            cacheRoot: cacheRoot, transport: transport, builder: RecordingImageBuilder())
        do {
            _ = try await service.materializeRootfs(image: image)
            Issue.record("expected insufficientDiskSpace")
        } catch let error as OCIError {
            guard case .insufficientDiskSpace = error else {
                Issue.record("expected insufficientDiskSpace, got \(error)")
                return
            }
            #expect(error.failureClassification == .permanent)
        }
    }

    @Test("an unparseable image reference is rejected up front")
    func invalidReference() async throws {
        let cacheRoot = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: cacheRoot) }
        let service = makeService(
            cacheRoot: cacheRoot, transport: MockOCITransport(), builder: RecordingImageBuilder())

        do {
            _ = try await service.materializeRootfs(image: "registry.example.com/bad ref:v1")
            Issue.record("expected invalidReference")
        } catch let error as OCIError {
            guard case .invalidReference = error else {
                Issue.record("expected invalidReference, got \(error)")
                return
            }
        }
    }
}

/// Stands in for `Ext4ImageBuilder`: snapshots the flattened tree it was
/// given (relative path → file contents) and writes a marker image file.
actor RecordingImageBuilder: RootfsImageBuilder {
    private(set) var snapshots: [[String: String]] = []

    func buildImage(fromTree treePath: String, at imagePath: String) async throws {
        var snapshot: [String: String] = [:]
        if let enumerator = FileManager.default.enumerator(atPath: treePath) {
            while let relative = enumerator.nextObject() as? String {
                let full = treePath + "/" + relative
                var isDirectory: ObjCBool = false
                if FileManager.default.fileExists(atPath: full, isDirectory: &isDirectory),
                    !isDirectory.boolValue,
                    let data = FileManager.default.contents(atPath: full)
                {
                    snapshot[relative] = String(decoding: data, as: UTF8.self)
                }
            }
        }
        snapshots.append(snapshot)
        try Data("ext4-image-marker".utf8).write(to: URL(fileURLWithPath: imagePath))
    }
}
