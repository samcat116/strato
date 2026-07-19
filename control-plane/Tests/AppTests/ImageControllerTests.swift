import Testing
import Vapor
import Fluent
import VaporTesting
import NIOCore
import NIOHTTP1
import StratoShared
@testable import App

@Suite("Image Controller Tests", .serialized)
final class ImageControllerTests {

    // MARK: - Test Data Helpers

    /// Creates a ByteBuffer with QCOW2 magic bytes
    static func createQCOW2Buffer(size: Int = 1024) -> ByteBuffer {
        var buffer = ByteBufferAllocator().buffer(capacity: max(size, 72))

        // Magic: QFI\xFB (0x514649FB)
        buffer.writeBytes([0x51, 0x46, 0x49, 0xFB])

        // Version 3 (big-endian)
        buffer.writeInteger(UInt32(3).bigEndian)

        // Backing file offset
        buffer.writeInteger(UInt64(0).bigEndian)

        // Backing file size
        buffer.writeInteger(UInt32(0).bigEndian)

        // Cluster bits
        buffer.writeInteger(UInt32(16).bigEndian)

        // Virtual size (10GB)
        buffer.writeInteger(UInt64(10 * 1024 * 1024 * 1024).bigEndian)

        // Fill remaining with zeros
        let remaining = max(0, size - buffer.writerIndex)
        if remaining > 0 {
            buffer.writeRepeatingByte(0, count: remaining)
        }

        return buffer
    }

    /// Creates a ByteBuffer with raw (non-QCOW2) data
    static func createRawBuffer(size: Int = 1024) -> ByteBuffer {
        var buffer = ByteBufferAllocator().buffer(capacity: size)
        buffer.writeRepeatingByte(0x00, count: size)
        return buffer
    }

    /// Creates a temporary storage directory
    static func createTempStorageDirectory() throws -> String {
        let tempDir = FileManager.default.temporaryDirectory
        let storagePath = tempDir.appendingPathComponent("strato-test-images-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: storagePath, withIntermediateDirectories: true)
        return storagePath
    }

    /// Cleans up temporary storage directory
    static func cleanupTempStorageDirectory(_ path: String) {
        try? FileManager.default.removeItem(atPath: path)
    }

    /// Creates multipart form data for image upload
    static func createMultipartFormData(
        name: String,
        description: String?,
        filename: String,
        fileContent: ByteBuffer,
        format: String? = nil,
        boundary: String = "----TestBoundary\(UUID().uuidString)"
    ) -> (Data, String) {
        var body = Data()

        // Name field
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"name\"\r\n\r\n".data(using: .utf8)!)
        body.append("\(name)\r\n".data(using: .utf8)!)

        // Description field (if provided)
        if let desc = description {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"description\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(desc)\r\n".data(using: .utf8)!)
        }

        // Explicit disk format (if provided). Omitting it is the client's
        // "auto" case: the server detects from the file header instead.
        if let format {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"format\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(format)\r\n".data(using: .utf8)!)
        }

        // File field
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: application/octet-stream\r\n\r\n".data(using: .utf8)!)

        var tempBuffer = fileContent
        if let bytes = tempBuffer.readBytes(length: tempBuffer.readableBytes) {
            body.append(Data(bytes))
        }
        body.append("\r\n".data(using: .utf8)!)

        // End boundary
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        return (body, boundary)
    }

    /// Creates multipart form data for a typed-artifact upload (`kind` + `file`).
    static func createArtifactMultipartFormData(
        kind: String,
        filename: String,
        fileContent: ByteBuffer,
        boundary: String = "----TestBoundary\(UUID().uuidString)"
    ) -> (Data, String) {
        var body = Data()

        // Kind field
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"kind\"\r\n\r\n".data(using: .utf8)!)
        body.append("\(kind)\r\n".data(using: .utf8)!)

        // File field
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: application/octet-stream\r\n\r\n".data(using: .utf8)!)

        var tempBuffer = fileContent
        if let bytes = tempBuffer.readBytes(length: tempBuffer.readableBytes) {
            body.append(Data(bytes))
        }
        body.append("\r\n".data(using: .utf8)!)

        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        return (body, boundary)
    }

    /// Creates an empty image shell and returns its ID.
    static func createEmptyImage(
        app: Application,
        project: Project,
        authToken: String,
        name: String = "FC Image",
        architecture: CPUArchitecture = .x86_64
    ) async throws -> UUID {
        var imageID: UUID?
        try await app.test(.POST, "/api/projects/\(project.id!)/images") { req in
            req.headers.bearerAuthorization = BearerAuthorization(token: authToken)
            req.headers.contentType = .json
            try req.content.encode(
                CreateImageRequest(name: name, sourceURL: nil, architecture: architecture))
        } afterResponse: { res in
            #expect(res.status == .ok)
            imageID = try res.content.decode(ImageResponse.self).id
        }
        return try #require(imageID)
    }

    /// Uploads a single artifact to an image, returning the decoded response.
    static func uploadArtifact(
        app: Application,
        project: Project,
        imageID: UUID,
        authToken: String,
        kind: String,
        filename: String,
        fileContent: ByteBuffer
    ) async throws -> ImageResponse {
        let (body, boundary) = createArtifactMultipartFormData(
            kind: kind, filename: filename, fileContent: fileContent)

        var decoded: ImageResponse?
        try await app.test(.POST, "/api/projects/\(project.id!)/images/\(imageID)/artifacts") { req in
            req.headers.bearerAuthorization = BearerAuthorization(token: authToken)
            req.headers.contentType = HTTPMediaType(
                type: "multipart", subType: "form-data", parameters: ["boundary": boundary])
            req.body = ByteBuffer(data: body)
        } afterResponse: { res in
            #expect(res.status == .ok)
            decoded = try res.content.decode(ImageResponse.self)
        }
        return try #require(decoded)
    }

    // MARK: - Test App Helper

    func withImageTestApp(_ test: (Application, User, Organization, Project, String, String) async throws -> Void)
        async throws
    {
        let app = try await Application.makeForTesting()
        let tempStoragePath = try Self.createTempStorageDirectory()

        do {
            try await configure(app)

            // Point image storage at the temp directory by installing a store
            // directly; mutating the process environment would race other
            // parallel test suites reading it.
            app.imageObjectStore = FilesystemImageObjectStore(rootPath: tempStoragePath)

            // Inject mock ImageFetchService to prevent real HTTP requests
            app.imageFetchService = MockImageFetchService()

            try await app.autoMigrate()

            // Create test user
            let testUser = User(
                username: "imageuser",
                email: "imagetest@example.com",
                displayName: "Image Test User",
                isSystemAdmin: false
            )
            try await testUser.save(on: app.db)

            // Create test organization
            let testOrganization = Organization(
                name: "Image Test Org",
                description: "Organization for image tests"
            )
            try await testOrganization.save(on: app.db)

            // Add user to organization
            let userOrg = UserOrganization(
                userID: testUser.id!,
                organizationID: testOrganization.id!,
                role: "admin"
            )
            try await userOrg.save(on: app.db)

            // Create test project
            let testProject = Project(
                name: "Image Test Project",
                description: "Project for image tests",
                organizationID: testOrganization.id,
                path: ""
            )
            try await testProject.save(on: app.db)
            testProject.path = try await testProject.buildPath(on: app.db)
            try await testProject.save(on: app.db)

            // Generate auth token
            let authToken = try await testUser.generateAPIKey(on: app.db)

            try await test(app, testUser, testOrganization, testProject, authToken, tempStoragePath)

        } catch {
            try await app.shutdownForTesting()
            Self.cleanupTempStorageDirectory(tempStoragePath)
            throw error
        }

        try await app.shutdownForTesting()
        Self.cleanupTempStorageDirectory(tempStoragePath)
    }

    // MARK: - Artifact Disk Format Tests

    /// The artifact path validates filenames through a separate whitelist to the
    /// upload path. When `ImageFormat` grew vmdk/vhd/vhdx, only the upload one
    /// was widened, so replacing a disk-image artifact with a format the API
    /// advertised was refused before detection ever ran.
    @Test(
        "Disk-image artifacts accept every advertised disk format",
        arguments: ["vmdk", "vhd", "vhdx"])
    func testUploadDiskImageArtifactWithHypervisorFormat(ext: String) async throws {
        try await withImageTestApp { app, _, _, project, authToken, _ in
            let imageID = try await Self.createEmptyImage(
                app: app, project: project, authToken: authToken, name: "artifact-\(ext)")

            let image = try await Self.uploadArtifact(
                app: app,
                project: project,
                imageID: imageID,
                authToken: authToken,
                kind: "disk-image",
                filename: "disk.\(ext)",
                fileContent: Self.createQCOW2Buffer())

            #expect(image.artifacts.contains { $0.kind == .diskImage })
        }
    }

    @Test("Rootfs artifacts accept a vmdk filename")
    func testUploadRootfsArtifactWithVMDK() async throws {
        try await withImageTestApp { app, _, _, project, authToken, _ in
            let imageID = try await Self.createEmptyImage(
                app: app, project: project, authToken: authToken, name: "rootfs-vmdk")

            let image = try await Self.uploadArtifact(
                app: app,
                project: project,
                imageID: imageID,
                authToken: authToken,
                kind: "rootfs",
                filename: "rootfs.vmdk",
                fileContent: Self.createRawBuffer())

            #expect(image.artifacts.contains { $0.kind == .rootfs })
        }
    }

    // MARK: - Explicit Disk Format Tests

    /// The regression behind the "raw .img stored as qcow2" report: an upload
    /// with no explicit format must be detected, never assumed. `.img` names no
    /// format, so the bytes are the only evidence.
    @Test("Upload without an explicit format detects raw from the file header")
    func testUploadWithoutFormatDetectsRaw() async throws {
        try await withImageTestApp { app, _, _, project, authToken, _ in
            let (body, boundary) = Self.createMultipartFormData(
                name: "raw-img",
                description: nil,
                filename: "disk.img",
                fileContent: Self.createRawBuffer())

            try await app.test(.POST, "/api/projects/\(project.id!)/images") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: authToken)
                req.headers.contentType = .init(
                    type: "multipart", subType: "form-data",
                    parameters: ["boundary": boundary])
                req.body = ByteBuffer(data: body)
            } afterResponse: { res in
                #expect(res.status == .ok)
                let image = try res.content.decode(ImageResponse.self)
                #expect(image.format == .raw)
            }
        }
    }

    /// A headerless file could be raw, a fixed VHD, or a flat VMDK — detection
    /// can't tell, so an explicit claim of those is taken on trust.
    @Test("Explicit format is honoured when the header can't contradict it")
    func testUploadExplicitFormatOnHeaderlessFile() async throws {
        try await withImageTestApp { app, _, _, project, authToken, _ in
            let (body, boundary) = Self.createMultipartFormData(
                name: "flat-vmdk",
                description: nil,
                filename: "disk.vmdk",
                fileContent: Self.createRawBuffer(),
                format: "vmdk")

            try await app.test(.POST, "/api/projects/\(project.id!)/images") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: authToken)
                req.headers.contentType = .init(
                    type: "multipart", subType: "form-data",
                    parameters: ["boundary": boundary])
                req.body = ByteBuffer(data: body)
            } afterResponse: { res in
                #expect(res.status == .ok)
                let image = try res.content.decode(ImageResponse.self)
                #expect(image.format == .vmdk)
            }
        }
    }

    /// qcow2 always carries its magic, so claiming it for a headerless file is
    /// refused rather than stored as a format the bytes plainly aren't.
    @Test("Claiming qcow2 for a file with no qcow2 magic is refused")
    func testUploadRejectsUndetectableQcow2Claim() async throws {
        try await withImageTestApp { app, _, _, project, authToken, _ in
            let (body, boundary) = Self.createMultipartFormData(
                name: "lying-qcow2",
                description: nil,
                filename: "disk.img",
                fileContent: Self.createRawBuffer(),
                format: "qcow2")

            try await app.test(.POST, "/api/projects/\(project.id!)/images") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: authToken)
                req.headers.contentType = .init(
                    type: "multipart", subType: "form-data",
                    parameters: ["boundary": boundary])
                req.body = ByteBuffer(data: body)
            } afterResponse: { res in
                #expect(res.status == .badRequest)
            }
        }
    }

    @Test("Claiming raw for a qcow2 file is refused")
    func testUploadRejectsContradictedClaim() async throws {
        try await withImageTestApp { app, _, _, project, authToken, _ in
            let (body, boundary) = Self.createMultipartFormData(
                name: "lying-raw",
                description: nil,
                filename: "disk.qcow2",
                fileContent: Self.createQCOW2Buffer(),
                format: "raw")

            try await app.test(.POST, "/api/projects/\(project.id!)/images") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: authToken)
                req.headers.contentType = .init(
                    type: "multipart", subType: "form-data",
                    parameters: ["boundary": boundary])
                req.body = ByteBuffer(data: body)
            } afterResponse: { res in
                #expect(res.status == .badRequest)
            }
        }
    }

    @Test("An unknown disk format is refused")
    func testUploadRejectsUnknownFormat() async throws {
        try await withImageTestApp { app, _, _, project, authToken, _ in
            let (body, boundary) = Self.createMultipartFormData(
                name: "bogus-format",
                description: nil,
                filename: "disk.qcow2",
                fileContent: Self.createQCOW2Buffer(),
                format: "wat")

            try await app.test(.POST, "/api/projects/\(project.id!)/images") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: authToken)
                req.headers.contentType = .init(
                    type: "multipart", subType: "form-data",
                    parameters: ["boundary": boundary])
                req.body = ByteBuffer(data: body)
            } afterResponse: { res in
                #expect(res.status == .badRequest)
            }
        }
    }

    // MARK: - Expected Checksum Tests

    /// A digest that could never match is a client error, not a download that
    /// runs to completion and then fails verification.
    @Test(
        "Create from URL rejects a malformed checksum",
        arguments: [
            "deadbeef",  // too short
            String(repeating: "a", count: 63),  // off by one
            String(repeating: "a", count: 65),  // off by one the other way
            String(repeating: "z", count: 64),  // right length, not hex
        ])
    func testCreateFromURLRejectsMalformedChecksum(checksum: String) async throws {
        try await withImageTestApp { app, _, _, project, authToken, _ in
            try await app.test(.POST, "/api/projects/\(project.id!)/images") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: authToken)
                req.headers.contentType = .json
                try req.content.encode(
                    CreateImageRequest(
                        name: "bad-checksum",
                        sourceURL: "https://example.com/disk.qcow2",
                        checksum: checksum))
            } afterResponse: { res in
                #expect(res.status == .badRequest)
            }
        }
    }

    @Test("Create from URL stores a valid checksum as the expected digest")
    func testCreateFromURLStoresExpectedChecksum() async throws {
        try await withImageTestApp { app, _, _, project, authToken, _ in
            // Uppercase on the way in: it should be normalised so the
            // post-download compare can be a plain equality check.
            let supplied = String(repeating: "AB", count: 32)
            var imageID: UUID?

            try await app.test(.POST, "/api/projects/\(project.id!)/images") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: authToken)
                req.headers.contentType = .json
                try req.content.encode(
                    CreateImageRequest(
                        name: "with-checksum",
                        sourceURL: "https://example.com/disk.qcow2",
                        checksum: supplied))
            } afterResponse: { res in
                #expect(res.status == .ok)
                imageID = try res.content.decode(ImageResponse.self).id
            }

            let id = try #require(imageID)
            let saved = try await Image.find(id, on: app.db)
            let image = try #require(saved)
            #expect(image.expectedChecksum == supplied.lowercased())
            // The observed digest stays empty until the download actually runs;
            // the caller's claim must never be mistaken for it.
            #expect(image.checksum == nil)
        }
    }

    @Test("Create from URL leaves the expected digest unset when omitted")
    func testCreateFromURLWithoutChecksum() async throws {
        try await withImageTestApp { app, _, _, project, authToken, _ in
            var imageID: UUID?
            try await app.test(.POST, "/api/projects/\(project.id!)/images") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: authToken)
                req.headers.contentType = .json
                try req.content.encode(
                    CreateImageRequest(
                        name: "no-checksum",
                        sourceURL: "https://example.com/disk.qcow2"))
            } afterResponse: { res in
                #expect(res.status == .ok)
                imageID = try res.content.decode(ImageResponse.self).id
            }

            let id = try #require(imageID)
            let saved = try await Image.find(id, on: app.db)
            let image = try #require(saved)
            #expect(image.expectedChecksum == nil)
        }
    }

    // MARK: - List Images Tests

    @Test("List images returns empty array for new project")
    func testListImagesEmptyProject() async throws {
        try await withImageTestApp { app, _, _, project, authToken, _ in
            try await app.test(.GET, "/api/projects/\(project.id!)/images") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: authToken)
            } afterResponse: { res in
                #expect(res.status == .ok)

                let images = try res.content.decode([ImageResponse].self)
                #expect(images.isEmpty)
            }
        }
    }

    @Test("List images returns images for project")
    func testListImagesSuccess() async throws {
        try await withImageTestApp { app, user, _, project, authToken, _ in
            // Create an image
            let builder = TestDataBuilder(db: app.db)
            let image = try await builder.createImage(
                name: "Test Image",
                project: project,
                uploadedBy: user
            )

            try await app.test(.GET, "/api/projects/\(project.id!)/images") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: authToken)
            } afterResponse: { res in
                #expect(res.status == .ok)

                let images = try res.content.decode([ImageResponse].self)
                #expect(images.count == 1)
                #expect(images[0].id == image.id)
                #expect(images[0].name == "Test Image")
            }
        }
    }

    @Test("List images returns 401 without auth token")
    func testListImagesUnauthorized() async throws {
        try await withImageTestApp { app, _, _, project, _, _ in
            try await app.test(.GET, "/api/projects/\(project.id!)/images") { _ in
                // No auth header
            } afterResponse: { res in
                #expect(res.status == .unauthorized)
            }
        }
    }

    @Test("List images returns 404 for non-existent project")
    func testListImagesProjectNotFound() async throws {
        try await withImageTestApp { app, _, _, _, authToken, _ in
            let fakeProjectId = UUID()

            try await app.test(.GET, "/api/projects/\(fakeProjectId)/images") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: authToken)
            } afterResponse: { res in
                #expect(res.status == .notFound)
            }
        }
    }

    // MARK: - Get Image Tests

    @Test("Get image returns image details")
    func testGetImageSuccess() async throws {
        try await withImageTestApp { app, user, _, project, authToken, _ in
            let builder = TestDataBuilder(db: app.db)
            let image = try await builder.createImage(
                name: "Detail Test Image",
                description: "Image description",
                project: project,
                filename: "detail.qcow2",
                uploadedBy: user
            )

            try await app.test(.GET, "/api/projects/\(project.id!)/images/\(image.id!)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: authToken)
            } afterResponse: { res in
                #expect(res.status == .ok)

                let response = try res.content.decode(ImageResponse.self)
                #expect(response.id == image.id)
                #expect(response.name == "Detail Test Image")
                #expect(response.description == "Image description")
                #expect(response.filename == "detail.qcow2")
            }
        }
    }

    @Test("Get image returns 404 for non-existent image")
    func testGetImageNotFound() async throws {
        try await withImageTestApp { app, _, _, project, authToken, _ in
            let fakeImageId = UUID()

            try await app.test(.GET, "/api/projects/\(project.id!)/images/\(fakeImageId)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: authToken)
            } afterResponse: { res in
                #expect(res.status == .notFound)
            }
        }
    }

    @Test("Get image returns 404 when image belongs to different project")
    func testGetImageWrongProject() async throws {
        try await withImageTestApp { app, user, org, project, authToken, _ in
            // Create another project
            let otherProject = Project(
                name: "Other Project",
                description: "Other project",
                organizationID: org.id,
                path: ""
            )
            try await otherProject.save(on: app.db)

            // Create image in the other project
            let builder = TestDataBuilder(db: app.db)
            let image = try await builder.createImage(
                name: "Other Image",
                project: otherProject,
                uploadedBy: user
            )

            // Try to access from original project
            try await app.test(.GET, "/api/projects/\(project.id!)/images/\(image.id!)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: authToken)
            } afterResponse: { res in
                #expect(res.status == .notFound)
            }
        }
    }

    @Test("Get image returns 401 without auth token")
    func testGetImageUnauthorized() async throws {
        try await withImageTestApp { app, user, _, project, _, _ in
            let builder = TestDataBuilder(db: app.db)
            let image = try await builder.createImage(project: project, uploadedBy: user)

            try await app.test(.GET, "/api/projects/\(project.id!)/images/\(image.id!)") { _ in
                // No auth header
            } afterResponse: { res in
                #expect(res.status == .unauthorized)
            }
        }
    }

    // MARK: - Create Image (URL Fetch) Tests

    @Test("Create image from URL returns pending status")
    func testCreateImageFromURLSuccess() async throws {
        try await withImageTestApp { app, _, _, project, authToken, _ in
            try await app.test(.POST, "/api/projects/\(project.id!)/images") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: authToken)
                req.headers.contentType = .json
                try req.content.encode(
                    CreateImageRequest(
                        name: "URL Image",
                        description: "Image from URL",
                        sourceURL: "https://example.com/image.qcow2",
                        defaultCpu: 2,
                        defaultMemory: 4 * 1024 * 1024 * 1024,
                        defaultDisk: 20 * 1024 * 1024 * 1024,
                        defaultCmdline: nil
                    ))
            } afterResponse: { res in
                #expect(res.status == .ok)

                let response = try res.content.decode(ImageResponse.self)
                #expect(response.name == "URL Image")
                #expect(response.status == .pending)
                #expect(response.sourceURL == "https://example.com/image.qcow2")
            }
        }
    }

    @Test("Create image with no sourceURL creates an empty pending shell")
    func testCreateImageEmptyShell() async throws {
        try await withImageTestApp { app, _, _, project, authToken, _ in
            try await app.test(.POST, "/api/projects/\(project.id!)/images") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: authToken)
                req.headers.contentType = .json
                try req.content.encode(
                    CreateImageRequest(
                        name: "Firecracker Shell",
                        description: "Kernel + rootfs to follow",
                        sourceURL: nil,
                        architecture: .arm64
                    ))
            } afterResponse: { res in
                #expect(res.status == .ok)

                let response = try res.content.decode(ImageResponse.self)
                #expect(response.name == "Firecracker Shell")
                #expect(response.status == .pending)
                #expect(response.architecture == .arm64)
                #expect(response.artifacts.isEmpty)
                #expect(response.compatibleHypervisors.isEmpty)
            }
        }
    }

    @Test("Create image from URL returns 400 for invalid URL")
    func testCreateImageFromURLInvalidURL() async throws {
        try await withImageTestApp { app, _, _, project, authToken, _ in
            try await app.test(.POST, "/api/projects/\(project.id!)/images") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: authToken)
                req.headers.contentType = .json
                try req.content.encode(
                    CreateImageRequest(
                        name: "Invalid URL Image",
                        description: nil,
                        sourceURL: "not-a-valid-url",
                        defaultCpu: nil,
                        defaultMemory: nil,
                        defaultDisk: nil,
                        defaultCmdline: nil
                    ))
            } afterResponse: { res in
                #expect(res.status == .badRequest)
            }
        }
    }

    @Test("Create image from URL returns 400 for non-HTTP scheme")
    func testCreateImageFromURLNonHTTPScheme() async throws {
        try await withImageTestApp { app, _, _, project, authToken, _ in
            try await app.test(.POST, "/api/projects/\(project.id!)/images") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: authToken)
                req.headers.contentType = .json
                try req.content.encode(
                    CreateImageRequest(
                        name: "FTP URL Image",
                        description: nil,
                        sourceURL: "ftp://example.com/image.qcow2",
                        defaultCpu: nil,
                        defaultMemory: nil,
                        defaultDisk: nil,
                        defaultCmdline: nil
                    ))
            } afterResponse: { res in
                #expect(res.status == .badRequest)
            }
        }
    }

    @Test("Create image from URL returns 401 without auth")
    func testCreateImageFromURLUnauthorized() async throws {
        try await withImageTestApp { app, _, _, project, _, _ in
            try await app.test(.POST, "/api/projects/\(project.id!)/images") { req in
                req.headers.contentType = .json
                try req.content.encode(
                    CreateImageRequest(
                        name: "URL Image",
                        description: nil,
                        sourceURL: "https://example.com/image.qcow2",
                        defaultCpu: nil,
                        defaultMemory: nil,
                        defaultDisk: nil,
                        defaultCmdline: nil
                    ))
            } afterResponse: { res in
                #expect(res.status == .unauthorized)
            }
        }
    }

    // MARK: - Create Image (Multipart Upload) Tests

    @Test("Create image via multipart upload succeeds")
    func testCreateImageUploadSuccess() async throws {
        try await withImageTestApp { app, _, _, project, authToken, _ in
            let fileContent = Self.createQCOW2Buffer()
            let (body, boundary) = Self.createMultipartFormData(
                name: "Uploaded Image",
                description: "Test upload",
                filename: "test.qcow2",
                fileContent: fileContent
            )

            try await app.test(.POST, "/api/projects/\(project.id!)/images") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: authToken)
                req.headers.contentType = HTTPMediaType(
                    type: "multipart", subType: "form-data", parameters: ["boundary": boundary])
                req.body = ByteBuffer(data: body)
            } afterResponse: { res in
                #expect(res.status == .ok)

                let response = try res.content.decode(ImageResponse.self)
                #expect(response.name == "Uploaded Image")
                #expect(response.status == .ready)
                #expect(response.format == .qcow2)
                #expect(response.filename == "test.qcow2")
                #expect(response.checksum != nil)
            }
        }
    }

    @Test("Create image detects QCOW2 format")
    func testCreateImageUploadQCOW2Detection() async throws {
        try await withImageTestApp { app, _, _, project, authToken, _ in
            let fileContent = Self.createQCOW2Buffer()
            let (body, boundary) = Self.createMultipartFormData(
                name: "QCOW2 Image",
                description: nil,
                filename: "image.qcow2",
                fileContent: fileContent
            )

            try await app.test(.POST, "/api/projects/\(project.id!)/images") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: authToken)
                req.headers.contentType = HTTPMediaType(
                    type: "multipart", subType: "form-data", parameters: ["boundary": boundary])
                req.body = ByteBuffer(data: body)
            } afterResponse: { res in
                #expect(res.status == .ok)

                let response = try res.content.decode(ImageResponse.self)
                #expect(response.format == .qcow2)
            }
        }
    }

    @Test("Create image detects raw format")
    func testCreateImageUploadRawDetection() async throws {
        try await withImageTestApp { app, _, _, project, authToken, _ in
            let fileContent = Self.createRawBuffer()
            let (body, boundary) = Self.createMultipartFormData(
                name: "Raw Image",
                description: nil,
                filename: "image.raw",
                fileContent: fileContent
            )

            try await app.test(.POST, "/api/projects/\(project.id!)/images") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: authToken)
                req.headers.contentType = HTTPMediaType(
                    type: "multipart", subType: "form-data", parameters: ["boundary": boundary])
                req.body = ByteBuffer(data: body)
            } afterResponse: { res in
                #expect(res.status == .ok)

                let response = try res.content.decode(ImageResponse.self)
                #expect(response.format == .raw)
            }
        }
    }

    @Test("Create image upload returns 401 without auth")
    func testCreateImageUploadUnauthorized() async throws {
        try await withImageTestApp { app, _, _, project, _, _ in
            let fileContent = Self.createQCOW2Buffer()
            let (body, boundary) = Self.createMultipartFormData(
                name: "Uploaded Image",
                description: nil,
                filename: "test.qcow2",
                fileContent: fileContent
            )

            try await app.test(.POST, "/api/projects/\(project.id!)/images") { req in
                req.headers.contentType = HTTPMediaType(
                    type: "multipart", subType: "form-data", parameters: ["boundary": boundary])
                req.body = ByteBuffer(data: body)
            } afterResponse: { res in
                #expect(res.status == .unauthorized)
            }
        }
    }

    // MARK: - Update Image Tests

    @Test("Update image succeeds")
    func testUpdateImageSuccess() async throws {
        try await withImageTestApp { app, user, _, project, authToken, _ in
            let builder = TestDataBuilder(db: app.db)
            let image = try await builder.createImage(
                name: "Original Name",
                description: "Original description",
                project: project,
                uploadedBy: user
            )

            try await app.test(.PUT, "/api/projects/\(project.id!)/images/\(image.id!)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: authToken)
                try req.content.encode(
                    UpdateImageRequest(
                        name: "Updated Name",
                        description: "Updated description",
                        defaultCpu: 4,
                        defaultMemory: 8 * 1024 * 1024 * 1024,
                        defaultDisk: 50 * 1024 * 1024 * 1024,
                        defaultCmdline: "console=ttyS0"
                    ))
            } afterResponse: { res in
                #expect(res.status == .ok)

                let response = try res.content.decode(ImageResponse.self)
                #expect(response.name == "Updated Name")
                #expect(response.description == "Updated description")
                #expect(response.defaultCpu == 4)
            }
        }
    }

    @Test("Update image partial update only changes provided fields")
    func testUpdateImagePartialUpdate() async throws {
        try await withImageTestApp { app, user, _, project, authToken, _ in
            let builder = TestDataBuilder(db: app.db)
            let image = try await builder.createImage(
                name: "Original Name",
                description: "Original description",
                project: project,
                uploadedBy: user
            )

            try await app.test(.PUT, "/api/projects/\(project.id!)/images/\(image.id!)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: authToken)
                try req.content.encode(
                    UpdateImageRequest(
                        name: "New Name Only",
                        description: nil,
                        defaultCpu: nil,
                        defaultMemory: nil,
                        defaultDisk: nil,
                        defaultCmdline: nil
                    ))
            } afterResponse: { res in
                #expect(res.status == .ok)

                let response = try res.content.decode(ImageResponse.self)
                #expect(response.name == "New Name Only")
                #expect(response.description == "Original description")  // Unchanged
            }
        }
    }

    @Test("Update image returns 404 for non-existent image")
    func testUpdateImageNotFound() async throws {
        try await withImageTestApp { app, _, _, project, authToken, _ in
            let fakeImageId = UUID()

            try await app.test(.PUT, "/api/projects/\(project.id!)/images/\(fakeImageId)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: authToken)
                try req.content.encode(
                    UpdateImageRequest(
                        name: "Updated",
                        description: nil,
                        defaultCpu: nil,
                        defaultMemory: nil,
                        defaultDisk: nil,
                        defaultCmdline: nil
                    ))
            } afterResponse: { res in
                #expect(res.status == .notFound)
            }
        }
    }

    @Test("Update image returns 401 without auth")
    func testUpdateImageUnauthorized() async throws {
        try await withImageTestApp { app, user, _, project, _, _ in
            let builder = TestDataBuilder(db: app.db)
            let image = try await builder.createImage(project: project, uploadedBy: user)

            try await app.test(.PUT, "/api/projects/\(project.id!)/images/\(image.id!)") { req in
                try req.content.encode(
                    UpdateImageRequest(
                        name: "Updated",
                        description: nil,
                        defaultCpu: nil,
                        defaultMemory: nil,
                        defaultDisk: nil,
                        defaultCmdline: nil
                    ))
            } afterResponse: { res in
                #expect(res.status == .unauthorized)
            }
        }
    }

    // MARK: - Delete Image Tests

    @Test("Delete image succeeds")
    func testDeleteImageSuccess() async throws {
        try await withImageTestApp { app, user, _, project, authToken, tempStoragePath in
            let builder = TestDataBuilder(db: app.db)
            let image = try await builder.createImage(project: project, uploadedBy: user)
            let imageId = image.id!

            // Create actual file in storage
            let relativePath = ImageObjectKey.image(
                projectId: project.id!, imageId: imageId, filename: "test.qcow2")
            let filePath = "\(tempStoragePath)/\(relativePath)"
            try FileManager.default.createDirectory(
                atPath: (filePath as NSString).deletingLastPathComponent,
                withIntermediateDirectories: true)
            try "test content".data(using: .utf8)!.write(to: URL(fileURLWithPath: filePath))

            try await app.test(.DELETE, "/api/projects/\(project.id!)/images/\(imageId)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: authToken)
            } afterResponse: { res in
                #expect(res.status == .noContent)
            }

            // Verify image is deleted from database
            let deletedImage = try await Image.find(imageId, on: app.db)
            #expect(deletedImage == nil)
        }
    }

    @Test("Delete image returns 404 for non-existent image")
    func testDeleteImageNotFound() async throws {
        try await withImageTestApp { app, _, _, project, authToken, _ in
            let fakeImageId = UUID()

            try await app.test(.DELETE, "/api/projects/\(project.id!)/images/\(fakeImageId)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: authToken)
            } afterResponse: { res in
                #expect(res.status == .notFound)
            }
        }
    }

    @Test("Delete image returns 401 without auth")
    func testDeleteImageUnauthorized() async throws {
        try await withImageTestApp { app, user, _, project, _, _ in
            let builder = TestDataBuilder(db: app.db)
            let image = try await builder.createImage(project: project, uploadedBy: user)

            try await app.test(.DELETE, "/api/projects/\(project.id!)/images/\(image.id!)") { _ in
                // No auth header
            } afterResponse: { res in
                #expect(res.status == .unauthorized)
            }
        }
    }

    // MARK: - Get Image Status Tests

    @Test("Get image status returns status details")
    func testGetImageStatusSuccess() async throws {
        try await withImageTestApp { app, user, _, project, authToken, _ in
            let builder = TestDataBuilder(db: app.db)
            let image = try await builder.createImage(
                project: project,
                status: .ready,
                uploadedBy: user
            )

            try await app.test(.GET, "/api/projects/\(project.id!)/images/\(image.id!)/status") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: authToken)
            } afterResponse: { res in
                #expect(res.status == .ok)

                let response = try res.content.decode(ImageStatusResponse.self)
                #expect(response.id == image.id)
                #expect(response.status == .ready)
            }
        }
    }

    @Test("Get image status for pending image")
    func testGetImageStatusPending() async throws {
        try await withImageTestApp { app, user, _, project, authToken, _ in
            let builder = TestDataBuilder(db: app.db)
            let image = try await builder.createImage(
                project: project,
                status: .pending,
                uploadedBy: user,
                sourceURL: "https://example.com/image.qcow2"
            )

            try await app.test(.GET, "/api/projects/\(project.id!)/images/\(image.id!)/status") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: authToken)
            } afterResponse: { res in
                #expect(res.status == .ok)

                let response = try res.content.decode(ImageStatusResponse.self)
                #expect(response.status == .pending)
            }
        }
    }

    @Test("Get image status returns 404 for non-existent image")
    func testGetImageStatusNotFound() async throws {
        try await withImageTestApp { app, _, _, project, authToken, _ in
            let fakeImageId = UUID()

            try await app.test(.GET, "/api/projects/\(project.id!)/images/\(fakeImageId)/status") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: authToken)
            } afterResponse: { res in
                #expect(res.status == .notFound)
            }
        }
    }

    @Test("Get image status returns 401 without auth")
    func testGetImageStatusUnauthorized() async throws {
        try await withImageTestApp { app, user, _, project, _, _ in
            let builder = TestDataBuilder(db: app.db)
            let image = try await builder.createImage(project: project, uploadedBy: user)

            try await app.test(.GET, "/api/projects/\(project.id!)/images/\(image.id!)/status") { _ in
                // No auth header
            } afterResponse: { res in
                #expect(res.status == .unauthorized)
            }
        }
    }

    // MARK: - Download Image Tests

    @Test("Download image returns 400 for non-ready image")
    func testDownloadImageNotReady() async throws {
        try await withImageTestApp { app, user, _, project, authToken, _ in
            let builder = TestDataBuilder(db: app.db)
            let image = try await builder.createImage(
                project: project,
                status: .pending,
                uploadedBy: user
            )

            try await app.test(.GET, "/api/projects/\(project.id!)/images/\(image.id!)/download") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: authToken)
            } afterResponse: { res in
                #expect(res.status == .badRequest)
            }
        }
    }

    @Test("Download image returns 404 for non-existent image")
    func testDownloadImageNotFound() async throws {
        try await withImageTestApp { app, _, _, project, authToken, _ in
            let fakeImageId = UUID()

            try await app.test(.GET, "/api/projects/\(project.id!)/images/\(fakeImageId)/download") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: authToken)
            } afterResponse: { res in
                #expect(res.status == .notFound)
            }
        }
    }

    @Test("Download image returns 401 without auth")
    func testDownloadImageUnauthorized() async throws {
        try await withImageTestApp { app, user, _, project, _, _ in
            let builder = TestDataBuilder(db: app.db)
            let image = try await builder.createImage(project: project, uploadedBy: user)

            try await app.test(.GET, "/api/projects/\(project.id!)/images/\(image.id!)/download") { _ in
                // No auth header
            } afterResponse: { res in
                #expect(res.status == .unauthorized)
            }
        }
    }

    // MARK: - Artifact Registration Tests

    @Test("Registering kernel + rootfs makes an image Firecracker-ready")
    func testRegisterFirecrackerArtifacts() async throws {
        try await withImageTestApp { app, _, _, project, authToken, _ in
            let imageID = try await Self.createEmptyImage(
                app: app, project: project, authToken: authToken)

            // Kernel alone is not bootable — image stays pending.
            let afterKernel = try await Self.uploadArtifact(
                app: app, project: project, imageID: imageID, authToken: authToken,
                kind: "kernel", filename: "vmlinux", fileContent: Self.createRawBuffer())
            #expect(afterKernel.status == .pending)
            #expect(afterKernel.compatibleHypervisors.isEmpty)
            #expect(afterKernel.artifacts.contains { $0.kind == .kernel })

            // Adding a rootfs completes the pair — image becomes ready.
            let afterRootfs = try await Self.uploadArtifact(
                app: app, project: project, imageID: imageID, authToken: authToken,
                kind: "rootfs", filename: "rootfs.ext4", fileContent: Self.createRawBuffer())
            #expect(afterRootfs.status == .ready)
            #expect(afterRootfs.compatibleHypervisors.contains(.firecracker))
            #expect(afterRootfs.artifacts.count == 2)

            // The kernel artifact carries no disk format; the rootfs is raw.
            let kernel = try #require(afterRootfs.artifacts.first { $0.kind == .kernel })
            #expect(kernel.format == nil)
            let rootfs = try #require(afterRootfs.artifacts.first { $0.kind == .rootfs })
            #expect(rootfs.format == .raw)
        }
    }

    @Test("Deleting the rootfs reverts a Firecracker image to pending")
    func testDeleteArtifactRecomputesStatus() async throws {
        try await withImageTestApp { app, _, _, project, authToken, _ in
            let imageID = try await Self.createEmptyImage(
                app: app, project: project, authToken: authToken)
            _ = try await Self.uploadArtifact(
                app: app, project: project, imageID: imageID, authToken: authToken,
                kind: "kernel", filename: "vmlinux", fileContent: Self.createRawBuffer())
            let ready = try await Self.uploadArtifact(
                app: app, project: project, imageID: imageID, authToken: authToken,
                kind: "rootfs", filename: "rootfs.ext4", fileContent: Self.createRawBuffer())
            #expect(ready.status == .ready)

            try await app.test(
                .DELETE, "/api/projects/\(project.id!)/images/\(imageID)/artifacts/rootfs"
            ) { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: authToken)
            } afterResponse: { res in
                #expect(res.status == .ok)
                let response = try res.content.decode(ImageResponse.self)
                #expect(response.status == .pending)
                #expect(response.compatibleHypervisors.isEmpty)
                #expect(response.artifacts.count == 1)
                #expect(response.artifacts.first?.kind == .kernel)
            }
        }
    }

    @Test("Re-uploading an artifact of the same kind replaces it")
    func testUploadArtifactReplacesExisting() async throws {
        try await withImageTestApp { app, _, _, project, authToken, _ in
            let imageID = try await Self.createEmptyImage(
                app: app, project: project, authToken: authToken)
            _ = try await Self.uploadArtifact(
                app: app, project: project, imageID: imageID, authToken: authToken,
                kind: "rootfs", filename: "old.ext4", fileContent: Self.createRawBuffer(size: 512))
            let replaced = try await Self.uploadArtifact(
                app: app, project: project, imageID: imageID, authToken: authToken,
                kind: "rootfs", filename: "new.ext4", fileContent: Self.createRawBuffer(size: 2048))

            let rootfsArtifacts = replaced.artifacts.filter { $0.kind == .rootfs }
            #expect(rootfsArtifacts.count == 1)
            #expect(rootfsArtifacts.first?.filename == "new.ext4")
            #expect(rootfsArtifacts.first?.size == 2048)
        }
    }

    @Test("Uploading an unknown artifact kind returns 400")
    func testUploadArtifactUnknownKind() async throws {
        try await withImageTestApp { app, _, _, project, authToken, _ in
            let imageID = try await Self.createEmptyImage(
                app: app, project: project, authToken: authToken)

            let (body, boundary) = Self.createArtifactMultipartFormData(
                kind: "bogus", filename: "x.bin", fileContent: Self.createRawBuffer())

            try await app.test(.POST, "/api/projects/\(project.id!)/images/\(imageID)/artifacts") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: authToken)
                req.headers.contentType = HTTPMediaType(
                    type: "multipart", subType: "form-data", parameters: ["boundary": boundary])
                req.body = ByteBuffer(data: body)
            } afterResponse: { res in
                #expect(res.status == .badRequest)
            }
        }
    }

    @Test("Fetching an artifact from a URL creates a pending artifact")
    func testFetchArtifactCreatesPending() async throws {
        try await withImageTestApp { app, _, _, project, authToken, _ in
            let imageID = try await Self.createEmptyImage(
                app: app, project: project, authToken: authToken)

            try await app.test(
                .POST, "/api/projects/\(project.id!)/images/\(imageID)/artifacts/fetch"
            ) { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: authToken)
                req.headers.contentType = .json
                try req.content.encode(
                    ArtifactFetchRequest(
                        kind: "kernel", sourceURL: "https://example.com/vmlinux"))
            } afterResponse: { res in
                #expect(res.status == .ok)
                let response = try res.content.decode(ImageResponse.self)
                // The pending kernel exists but does not make the image bootable.
                #expect(response.status == .pending)
                #expect(response.compatibleHypervisors.isEmpty)
                let kernel = try #require(response.artifacts.first { $0.kind == .kernel })
                #expect(kernel.status == .pending)
                #expect(kernel.sourceURL == "https://example.com/vmlinux")
            }

            // The background fetch was scheduled for exactly one artifact.
            let mock = try #require(app.imageFetchService as? MockImageFetchService)
            let scheduled = await mock.startedArtifactFetches
            #expect(scheduled.count == 1)
        }
    }

    @Test("Fetching an artifact rejects a non-HTTP URL")
    func testFetchArtifactInvalidURL() async throws {
        try await withImageTestApp { app, _, _, project, authToken, _ in
            let imageID = try await Self.createEmptyImage(
                app: app, project: project, authToken: authToken)

            try await app.test(
                .POST, "/api/projects/\(project.id!)/images/\(imageID)/artifacts/fetch"
            ) { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: authToken)
                req.headers.contentType = .json
                try req.content.encode(
                    ArtifactFetchRequest(kind: "rootfs", sourceURL: "ftp://example.com/rootfs"))
            } afterResponse: { res in
                #expect(res.status == .badRequest)
            }
        }
    }

    @Test("Fetch artifact is denied (403) when SpiceDB withholds update")
    func testFetchArtifactForbiddenWhenDenied() async throws {
        try await withImageTestApp { app, _, _, project, authToken, _ in
            let imageID = try await Self.createEmptyImage(
                app: app, project: project, authToken: authToken)
            app.spicedbMockAllows = false

            try await app.test(
                .POST, "/api/projects/\(project.id!)/images/\(imageID)/artifacts/fetch"
            ) { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: authToken)
                req.headers.contentType = .json
                try req.content.encode(
                    ArtifactFetchRequest(kind: "kernel", sourceURL: "https://example.com/vmlinux"))
            } afterResponse: { res in
                #expect(res.status == .forbidden)
            }
        }
    }

    @Test("A pending URL artifact is not sent to agents by buildImageInfo")
    func testPendingArtifactExcludedFromImageInfo() async throws {
        try await withImageTestApp { app, _, _, project, authToken, _ in
            // A ready Firecracker image (kernel + rootfs uploaded)...
            let imageID = try await Self.createEmptyImage(
                app: app, project: project, authToken: authToken)
            _ = try await Self.uploadArtifact(
                app: app, project: project, imageID: imageID, authToken: authToken,
                kind: "kernel", filename: "vmlinux", fileContent: Self.createRawBuffer())
            let ready = try await Self.uploadArtifact(
                app: app, project: project, imageID: imageID, authToken: authToken,
                kind: "rootfs", filename: "rootfs.ext4", fileContent: Self.createRawBuffer())
            #expect(ready.status == .ready)

            // ...gains a still-pending disk-image via URL.
            try await app.test(
                .POST, "/api/projects/\(project.id!)/images/\(imageID)/artifacts/fetch"
            ) { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: authToken)
                req.headers.contentType = .json
                try req.content.encode(
                    ArtifactFetchRequest(
                        kind: "disk-image", sourceURL: "https://example.com/disk.qcow2"))
            } afterResponse: { res in
                #expect(res.status == .ok)
            }

            let image = try #require(try await Image.find(imageID, on: app.db))
            try await image.$artifacts.load(on: app.db)
            let info = try VMSpecBuilder.buildImageInfo(
                from: image,
                controlPlaneURL: "http://localhost:8080",
                agentName: "agent-1",
                signingKey: String(repeating: "a", count: 64)
            )
            // Only the two ready artifacts are offered; the pending disk-image is withheld.
            #expect(info.artifacts.count == 2)
            #expect(!info.artifacts.contains { $0.kind == .diskImage })
        }
    }

    @Test("Upload artifact is denied (403) when SpiceDB withholds update")
    func testUploadArtifactForbiddenWhenDenied() async throws {
        try await withImageTestApp { app, _, _, project, authToken, _ in
            let imageID = try await Self.createEmptyImage(
                app: app, project: project, authToken: authToken)
            app.spicedbMockAllows = false

            let (body, boundary) = Self.createArtifactMultipartFormData(
                kind: "kernel", filename: "vmlinux", fileContent: Self.createRawBuffer())

            try await app.test(.POST, "/api/projects/\(project.id!)/images/\(imageID)/artifacts") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: authToken)
                req.headers.contentType = HTTPMediaType(
                    type: "multipart", subType: "form-data", parameters: ["boundary": boundary])
                req.body = ByteBuffer(data: body)
            } afterResponse: { res in
                #expect(res.status == .forbidden)
            }
        }
    }

    // MARK: - Authorization Tests
    //
    // Every ImageController handler gates on `req.spicedb.checkPermission` after
    // authenticating the caller. These pin the deny path: an authenticated user
    // whom SpiceDB refuses must get 403, not a leaked image or a mutation. They
    // regress the whole class of authz bugs that went uncaught while the auth
    // middleware was disabled under `.testing` (issue #196). `spicedbMockAllows`
    // drives the mock's verdict for the whole request.

    @Test("List images is denied (403) when SpiceDB withholds view_project")
    func testListImagesForbiddenWhenDenied() async throws {
        try await withImageTestApp { app, _, _, project, authToken, _ in
            app.spicedbMockAllows = false

            try await app.test(.GET, "/api/projects/\(project.id!)/images") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: authToken)
            } afterResponse: { res in
                #expect(res.status == .forbidden)
            }
        }
    }

    @Test("Get image is denied (403) when SpiceDB withholds read")
    func testGetImageForbiddenWhenDenied() async throws {
        try await withImageTestApp { app, user, _, project, authToken, _ in
            let builder = TestDataBuilder(db: app.db)
            let image = try await builder.createImage(project: project, uploadedBy: user)
            app.spicedbMockAllows = false

            try await app.test(.GET, "/api/projects/\(project.id!)/images/\(image.id!)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: authToken)
            } afterResponse: { res in
                #expect(res.status == .forbidden)
            }
        }
    }

    @Test("Create image is denied (403) when SpiceDB withholds update_project")
    func testCreateImageForbiddenWhenDenied() async throws {
        try await withImageTestApp { app, _, _, project, authToken, _ in
            app.spicedbMockAllows = false

            try await app.test(.POST, "/api/projects/\(project.id!)/images") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: authToken)
                req.headers.contentType = .json
                try req.content.encode(
                    CreateImageRequest(
                        name: "URL Image",
                        description: nil,
                        sourceURL: "https://example.com/image.qcow2",
                        defaultCpu: nil,
                        defaultMemory: nil,
                        defaultDisk: nil,
                        defaultCmdline: nil
                    ))
            } afterResponse: { res in
                #expect(res.status == .forbidden)
            }
        }
    }

    @Test("Update image is denied (403) when SpiceDB withholds update")
    func testUpdateImageForbiddenWhenDenied() async throws {
        try await withImageTestApp { app, user, _, project, authToken, _ in
            let builder = TestDataBuilder(db: app.db)
            let image = try await builder.createImage(project: project, uploadedBy: user)
            app.spicedbMockAllows = false

            try await app.test(.PUT, "/api/projects/\(project.id!)/images/\(image.id!)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: authToken)
                req.headers.contentType = .json
                try req.content.encode(
                    UpdateImageRequest(
                        name: "Renamed",
                        description: nil,
                        defaultCpu: nil,
                        defaultMemory: nil,
                        defaultDisk: nil,
                        defaultCmdline: nil
                    ))
            } afterResponse: { res in
                #expect(res.status == .forbidden)
            }
        }
    }

    @Test("Delete image is denied (403) when SpiceDB withholds delete")
    func testDeleteImageForbiddenWhenDenied() async throws {
        try await withImageTestApp { app, user, _, project, authToken, _ in
            let builder = TestDataBuilder(db: app.db)
            let image = try await builder.createImage(project: project, uploadedBy: user)
            app.spicedbMockAllows = false

            try await app.test(.DELETE, "/api/projects/\(project.id!)/images/\(image.id!)") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: authToken)
            } afterResponse: { res in
                #expect(res.status == .forbidden)
            }
        }
    }

    @Test("Get image status is denied (403) when SpiceDB withholds read")
    func testGetImageStatusForbiddenWhenDenied() async throws {
        try await withImageTestApp { app, user, _, project, authToken, _ in
            let builder = TestDataBuilder(db: app.db)
            let image = try await builder.createImage(project: project, uploadedBy: user)
            app.spicedbMockAllows = false

            try await app.test(.GET, "/api/projects/\(project.id!)/images/\(image.id!)/status") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: authToken)
            } afterResponse: { res in
                #expect(res.status == .forbidden)
            }
        }
    }

    // MARK: - Streaming upload

    /// The upload path streams the multipart body into the object store instead
    /// of collecting it, so these pin the properties that used to fall out of
    /// buffering the whole body and hashing the finished file.

    @Test("Uploaded bytes land in the store byte-for-byte")
    func testUploadStoresExactBytes() async throws {
        try await withImageTestApp { app, _, _, project, authToken, tempStoragePath in
            // Larger than one parser chunk so the streaming path is exercised
            // across multiple `execute` calls rather than a single buffer.
            let content = String(repeating: "strato-image-payload-", count: 50_000)
            var buffer = ByteBufferAllocator().buffer(capacity: content.utf8.count)
            buffer.writeString(content)

            let (body, boundary) = Self.createMultipartFormData(
                name: "Streamed", description: "d", filename: "disk.img", fileContent: buffer)

            var imageId: UUID?
            try await app.test(.POST, "/api/projects/\(project.id!)/images") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: authToken)
                req.headers.contentType = HTTPMediaType(
                    type: "multipart", subType: "form-data", parameters: ["boundary": boundary])
                req.body = ByteBuffer(data: body)
            } afterResponse: { res in
                #expect(res.status == .ok)
                imageId = try res.content.decode(ImageResponse.self).id
            }

            let stored = try String(
                contentsOfFile: "\(tempStoragePath)/\(project.id!)/\(imageId!)/disk.img",
                encoding: .utf8)
            #expect(stored == content)
        }
    }

    @Test("Recorded size and checksum describe the stored bytes")
    func testUploadRecordsSizeAndChecksumOfStoredBytes() async throws {
        try await withImageTestApp { app, _, _, project, authToken, _ in
            let content = "checksum me"
            var buffer = ByteBufferAllocator().buffer(capacity: content.utf8.count)
            buffer.writeString(content)

            let (body, boundary) = Self.createMultipartFormData(
                name: "Sums", description: nil, filename: "disk.img", fileContent: buffer)

            var image: ImageResponse?
            try await app.test(.POST, "/api/projects/\(project.id!)/images") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: authToken)
                req.headers.contentType = HTTPMediaType(
                    type: "multipart", subType: "form-data", parameters: ["boundary": boundary])
                req.body = ByteBuffer(data: body)
            } afterResponse: { res in
                #expect(res.status == .ok)
                image = try res.content.decode(ImageResponse.self)
            }

            #expect(image?.size == Int64(content.utf8.count))
            // SHA-256 of "checksum me" — computed over the streamed bytes, never
            // taken from the client.
            #expect(image?.checksum == "820eb62b7660a216f711bd0df37ac8a176b662a159959870edc200b857262daf")
        }
    }

    @Test("Form fields sent after the file part are still applied")
    func testFieldsAfterFilePartAreApplied() async throws {
        // The frontend appends `file` first and metadata afterwards
        // (control-plane/web/src/lib/api/images.ts), so a streaming parser that
        // only read fields seen before the file would silently drop the name.
        try await withImageTestApp { app, _, _, project, authToken, _ in
            var buffer = ByteBufferAllocator().buffer(capacity: 16)
            buffer.writeString("payload")

            let boundary = "----TestBoundary\(UUID().uuidString)"
            var body = Data()
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append(
                "Content-Disposition: form-data; name=\"file\"; filename=\"disk.img\"\r\n".data(
                    using: .utf8)!)
            body.append("Content-Type: application/octet-stream\r\n\r\n".data(using: .utf8)!)
            body.append("payload".data(using: .utf8)!)
            body.append("\r\n".data(using: .utf8)!)
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append(
                "Content-Disposition: form-data; name=\"name\"\r\n\r\n".data(using: .utf8)!)
            body.append("Named After File\r\n".data(using: .utf8)!)
            body.append("--\(boundary)--\r\n".data(using: .utf8)!)

            try await app.test(.POST, "/api/projects/\(project.id!)/images") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: authToken)
                req.headers.contentType = HTTPMediaType(
                    type: "multipart", subType: "form-data", parameters: ["boundary": boundary])
                req.body = ByteBuffer(data: body)
            } afterResponse: { res in
                #expect(res.status == .ok)
                let image = try res.content.decode(ImageResponse.self)
                #expect(image.name == "Named After File")
            }
        }
    }

    @Test("A rejected upload leaves neither an image row nor stored bytes")
    func testRejectedUploadCleansUp() async throws {
        try await withImageTestApp { app, _, _, project, authToken, tempStoragePath in
            // A qcow2 header with an explicit `raw` claim is the contradiction
            // case: detection wins and the upload is refused.
            var buffer = ByteBufferAllocator().buffer(capacity: 16)
            buffer.writeBytes(ImageValidationService.qcow2Magic)
            buffer.writeBytes([0x00, 0x00, 0x00, 0x03])

            let (body, boundary) = Self.createMultipartFormData(
                name: "Bad", description: nil, filename: "disk.img", fileContent: buffer,
                format: "raw")

            try await app.test(.POST, "/api/projects/\(project.id!)/images") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: authToken)
                req.headers.contentType = HTTPMediaType(
                    type: "multipart", subType: "form-data", parameters: ["boundary": boundary])
                req.body = ByteBuffer(data: body)
            } afterResponse: { res in
                #expect(res.status == .badRequest)
            }

            let images = try await Image.query(on: app.db).all()
            #expect(images.isEmpty)

            // And no orphaned bytes under the project prefix.
            let projectDir = "\(tempStoragePath)/\(project.id!)"
            if FileManager.default.fileExists(atPath: projectDir) {
                let leftovers = try FileManager.default.subpathsOfDirectory(atPath: projectDir)
                    .filter { !$0.hasSuffix("/") }
                #expect(leftovers.allSatisfy { $0.isEmpty || !$0.contains("disk.img") })
            }
        }
    }

    @Test("Artifact upload rejects a body whose kind follows the file part")
    func testArtifactKindMustPrecedeFile() async throws {
        // The object key embeds the kind, so it has to be known before the first
        // byte is written. Our own client sends `kind` first; this pins the
        // error a client that doesn't will get, rather than a mis-keyed object.
        try await withImageTestApp { app, _, _, project, authToken, _ in
            let imageId = try await Self.createEmptyImage(
                app: app, project: project, authToken: authToken)

            let boundary = "----TestBoundary\(UUID().uuidString)"
            var body = Data()
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append(
                "Content-Disposition: form-data; name=\"file\"; filename=\"vmlinuz\"\r\n".data(
                    using: .utf8)!)
            body.append("Content-Type: application/octet-stream\r\n\r\n".data(using: .utf8)!)
            body.append("kernel bytes".data(using: .utf8)!)
            body.append("\r\n".data(using: .utf8)!)
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append(
                "Content-Disposition: form-data; name=\"kind\"\r\n\r\n".data(using: .utf8)!)
            body.append("kernel\r\n".data(using: .utf8)!)
            body.append("--\(boundary)--\r\n".data(using: .utf8)!)

            try await app.test(
                .POST, "/api/projects/\(project.id!)/images/\(imageId)/artifacts"
            ) { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: authToken)
                req.headers.contentType = HTTPMediaType(
                    type: "multipart", subType: "form-data", parameters: ["boundary": boundary])
                req.body = ByteBuffer(data: body)
            } afterResponse: { res in
                #expect(res.status == .badRequest)
            }
        }
    }

    @Test("A second file part is rejected rather than silently mis-recorded")
    func testSecondFilePartRejected() async throws {
        // The writer is opened under the first part's key, but `filename` would
        // be overwritten by the second — the row would name one file and the
        // bytes would live under another.
        try await withImageTestApp { app, _, _, project, authToken, tempStoragePath in
            let boundary = "----TestBoundary\(UUID().uuidString)"
            var body = Data()
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"name\"\r\n\r\n".data(using: .utf8)!)
            body.append("Two files\r\n".data(using: .utf8)!)
            for filename in ["first.img", "second.img"] {
                body.append("--\(boundary)\r\n".data(using: .utf8)!)
                body.append(
                    "Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n"
                        .data(using: .utf8)!)
                body.append("Content-Type: application/octet-stream\r\n\r\n".data(using: .utf8)!)
                body.append("bytes of \(filename)".data(using: .utf8)!)
                body.append("\r\n".data(using: .utf8)!)
            }
            body.append("--\(boundary)--\r\n".data(using: .utf8)!)

            try await app.test(.POST, "/api/projects/\(project.id!)/images") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: authToken)
                req.headers.contentType = HTTPMediaType(
                    type: "multipart", subType: "form-data", parameters: ["boundary": boundary])
                req.body = ByteBuffer(data: body)
            } afterResponse: { res in
                #expect(res.status == .badRequest)
            }

            // The rejected upload must leave neither a row nor stray bytes.
            let images = try await Image.query(on: app.db).all()
            #expect(images.isEmpty)
            let leftovers =
                FileManager.default.enumerator(atPath: tempStoragePath)?
                .compactMap { $0 as? String }
                .filter { !$0.hasSuffix("/") } ?? []
            #expect(
                leftovers.allSatisfy { path in
                    var isDirectory: ObjCBool = false
                    _ = FileManager.default.fileExists(
                        atPath: "\(tempStoragePath)/\(path)", isDirectory: &isDirectory)
                    return isDirectory.boolValue
                })
        }
    }

    @Test("An upload carrying an absurd number of form fields is rejected")
    func testTooManyFormFieldsRejected() async throws {
        // Each field is individually under maxFieldBytes, so only the count cap
        // stops a client from growing the field dictionary without limit.
        try await withImageTestApp { app, _, _, project, authToken, _ in
            let boundary = "----TestBoundary\(UUID().uuidString)"
            var body = Data()
            for index in 0...StreamingMultipartReceiver.maxFieldCount {
                body.append("--\(boundary)\r\n".data(using: .utf8)!)
                body.append(
                    "Content-Disposition: form-data; name=\"filler\(index)\"\r\n\r\n".data(
                        using: .utf8)!)
                body.append("x\r\n".data(using: .utf8)!)
            }
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append(
                "Content-Disposition: form-data; name=\"file\"; filename=\"disk.img\"\r\n".data(
                    using: .utf8)!)
            body.append("Content-Type: application/octet-stream\r\n\r\n".data(using: .utf8)!)
            body.append("bytes".data(using: .utf8)!)
            body.append("\r\n".data(using: .utf8)!)
            body.append("--\(boundary)--\r\n".data(using: .utf8)!)

            try await app.test(.POST, "/api/projects/\(project.id!)/images") { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: authToken)
                req.headers.contentType = HTTPMediaType(
                    type: "multipart", subType: "form-data", parameters: ["boundary": boundary])
                req.body = ByteBuffer(data: body)
            } afterResponse: { res in
                #expect(res.status == .badRequest)
            }

            let images = try await Image.query(on: app.db).all()
            #expect(images.isEmpty)
        }
    }

    @Test("Artifact upload accepts the kind as a query parameter, order-independently")
    func testArtifactKindFromQueryParameter() async throws {
        try await withImageTestApp { app, _, _, project, authToken, tempStoragePath in
            let imageId = try await Self.createEmptyImage(
                app: app, project: project, authToken: authToken)

            let boundary = "----TestBoundary\(UUID().uuidString)"
            var body = Data()
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append(
                "Content-Disposition: form-data; name=\"file\"; filename=\"vmlinuz\"\r\n".data(
                    using: .utf8)!)
            body.append("Content-Type: application/octet-stream\r\n\r\n".data(using: .utf8)!)
            body.append("kernel bytes".data(using: .utf8)!)
            body.append("\r\n".data(using: .utf8)!)
            body.append("--\(boundary)--\r\n".data(using: .utf8)!)

            try await app.test(
                .POST, "/api/projects/\(project.id!)/images/\(imageId)/artifacts?kind=kernel"
            ) { req in
                req.headers.bearerAuthorization = BearerAuthorization(token: authToken)
                req.headers.contentType = HTTPMediaType(
                    type: "multipart", subType: "form-data", parameters: ["boundary": boundary])
                req.body = ByteBuffer(data: body)
            } afterResponse: { res in
                #expect(res.status == .ok)
            }

            let stored = try String(
                contentsOfFile: "\(tempStoragePath)/\(project.id!)/\(imageId)/kernel/vmlinuz",
                encoding: .utf8)
            #expect(stored == "kernel bytes")
        }
    }

    @Test("Re-uploading an artifact to the same key keeps the new bytes")
    func testArtifactReuploadSameKeyKeepsNewBytes() async throws {
        // Replacing an artifact deletes the old object first. When the new
        // upload lands on the identical key, that delete would remove what was
        // just written — so it has to be skipped.
        try await withImageTestApp { app, _, _, project, authToken, tempStoragePath in
            let imageId = try await Self.createEmptyImage(
                app: app, project: project, authToken: authToken)

            for content in ["first kernel", "second kernel"] {
                var buffer = ByteBufferAllocator().buffer(capacity: content.utf8.count)
                buffer.writeString(content)
                _ = try await Self.uploadArtifact(
                    app: app, project: project, imageID: imageId, authToken: authToken,
                    kind: "kernel", filename: "vmlinuz", fileContent: buffer)
            }

            let stored = try String(
                contentsOfFile: "\(tempStoragePath)/\(project.id!)/\(imageId)/kernel/vmlinuz",
                encoding: .utf8)
            #expect(stored == "second kernel")
        }
    }
}
