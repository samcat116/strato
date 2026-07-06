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

            // Point image storage at the temp directory via the app-local
            // override; mutating the process environment would race other
            // parallel test suites reading it.
            app.imageStoragePath = tempStoragePath

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

            try await app.autoRevert()
        } catch {
            try? await app.autoRevert()
            try await app.asyncShutdown()
            app.cleanupTestDatabase()
            Self.cleanupTempStorageDirectory(tempStoragePath)
            throw error
        }

        try await app.asyncShutdown()
        app.cleanupTestDatabase()
        Self.cleanupTempStorageDirectory(tempStoragePath)
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
            try ImageStorageService.createDirectoryStructure(
                storagePath: tempStoragePath,
                projectId: project.id!,
                imageId: imageId
            )
            let filePath = ImageStorageService.buildFilePath(
                storagePath: tempStoragePath,
                projectId: project.id!,
                imageId: imageId,
                filename: "test.qcow2"
            )
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
}
