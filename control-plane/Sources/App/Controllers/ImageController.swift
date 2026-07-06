import Foundation
import Vapor
import Fluent
import NIOCore
import StratoShared

struct ImageController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        // Project-scoped image routes
        let projectImages = routes.grouped("api", "projects", ":projectID", "images")

        projectImages.get(use: index)
        projectImages.on(.POST, body: .stream, use: create)

        projectImages.group(":imageID") { image in
            image.get(use: show)
            image.put(use: update)
            image.delete(use: delete)
            image.get("download", use: download)
            image.get("status", use: status)
        }
    }

    // MARK: - List Images

    func index(req: Request) async throws -> [ImageResponse] {
        guard let user = req.auth.get(User.self) else {
            throw Abort(.unauthorized)
        }

        guard let projectID = req.parameters.get("projectID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid project ID")
        }

        // Verify project exists and user has access
        guard try await Project.find(projectID, on: req.db) != nil else {
            throw Abort(.notFound, reason: "Project not found")
        }

        // Check user permission on project (view_project permission allows listing images)
        let hasPermission = try await req.spicedb.checkPermission(
            subject: user.id?.uuidString ?? "",
            permission: "view_project",
            resource: "project",
            resourceId: projectID.uuidString
        )

        guard hasPermission else {
            throw Abort(.forbidden, reason: "Access denied to project")
        }

        // Get all images for the project
        let images = try await Image.query(on: req.db)
            .filter(\.$project.$id == projectID)
            .with(\.$artifacts)
            .sort(\.$createdAt, .descending)
            .all()

        return images.map { ImageResponse(from: $0) }
    }

    // MARK: - Get Image Details

    func show(req: Request) async throws -> ImageResponse {
        guard let user = req.auth.get(User.self) else {
            throw Abort(.unauthorized)
        }

        guard let projectID = req.parameters.get("projectID", as: UUID.self),
            let imageID = req.parameters.get("imageID", as: UUID.self)
        else {
            throw Abort(.badRequest, reason: "Invalid project or image ID")
        }

        guard let image = try await Image.find(imageID, on: req.db) else {
            throw Abort(.notFound, reason: "Image not found")
        }
        // Load artifacts so the response carries compatibility metadata.
        try await image.$artifacts.load(on: req.db)

        // Verify image belongs to the project
        guard image.$project.id == projectID else {
            throw Abort(.notFound, reason: "Image not found in project")
        }

        // Check permission
        let hasPermission = try await req.spicedb.checkPermission(
            subject: user.id?.uuidString ?? "",
            permission: "read",
            resource: "image",
            resourceId: imageID.uuidString
        )

        guard hasPermission else {
            throw Abort(.forbidden, reason: "Access denied to image")
        }

        return ImageResponse(from: image)
    }

    // MARK: - Create Image (Upload or URL Fetch)

    func create(req: Request) async throws -> ImageResponse {
        guard let user = req.auth.get(User.self) else {
            throw Abort(.unauthorized)
        }

        guard let userID = user.id else {
            throw Abort(.unauthorized)
        }

        guard let projectID = req.parameters.get("projectID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid project ID")
        }

        // Verify project exists and user has create permission
        guard try await Project.find(projectID, on: req.db) != nil else {
            throw Abort(.notFound, reason: "Project not found")
        }

        let hasPermission = try await req.spicedb.checkPermission(
            subject: user.id?.uuidString ?? "",
            permission: "update_project",
            resource: "project",
            resourceId: projectID.uuidString
        )

        guard hasPermission else {
            throw Abort(.forbidden, reason: "Access denied to create images in project")
        }

        // Get storage path
        let storagePath = ImageStorageService.storagePath(from: req.application)

        // Check content type to determine if this is a file upload or JSON request
        let contentType = req.headers.contentType

        if contentType?.subType == "json" {
            // JSON request - URL fetch
            return try await createFromURL(req: req, projectID: projectID, userID: userID, storagePath: storagePath)
        } else if contentType?.type == "multipart" {
            // Multipart upload
            return try await createFromUpload(req: req, projectID: projectID, userID: userID, storagePath: storagePath)
        } else {
            throw Abort(.badRequest, reason: "Expected multipart/form-data or application/json")
        }
    }

    // MARK: - Create from URL Fetch

    private func createFromURL(
        req: Request,
        projectID: UUID,
        userID: UUID,
        storagePath: String
    ) async throws -> ImageResponse {
        let createRequest = try req.content.decode(CreateImageRequest.self)

        guard let sourceURL = createRequest.sourceURL else {
            throw Abort(.badRequest, reason: "sourceURL is required for URL fetch")
        }

        // Validate URL
        guard let url = URL(string: sourceURL), url.scheme == "http" || url.scheme == "https" else {
            throw Abort(.badRequest, reason: "Invalid source URL")
        }

        // Extract filename from URL
        let filename = try ImageValidationService.validateFilename(
            url.lastPathComponent.isEmpty ? "image.qcow2" : url.lastPathComponent)

        // Create image record in pending state
        let image = Image(
            name: createRequest.name,
            description: createRequest.description ?? "",
            projectID: projectID,
            filename: filename,
            architecture: createRequest.architecture ?? .x86_64,
            status: .pending,
            uploadedByID: userID,
            sourceURL: sourceURL,
            defaultCpu: createRequest.defaultCpu,
            defaultMemory: createRequest.defaultMemory,
            defaultDisk: createRequest.defaultDisk,
            defaultCmdline: createRequest.defaultCmdline
        )

        try await image.save(on: req.db)

        // Create SpiceDB relationships
        let imageId = image.id?.uuidString ?? ""
        try await req.spicedb.writeRelationship(
            entity: "image",
            entityId: imageId,
            relation: "project",
            subject: "project",
            subjectId: projectID.uuidString
        )

        try await req.spicedb.writeRelationship(
            entity: "image",
            entityId: imageId,
            relation: "owner",
            subject: "user",
            subjectId: userID.uuidString
        )

        // Start background fetch
        req.logger.info(
            "Image created for URL fetch",
            metadata: [
                "image_id": .string(imageId),
                "source_url": .string(sourceURL),
            ])

        // Queue the fetch asynchronously
        Task {
            do {
                try await req.imageFetchService.startFetch(imageId: image.id!)
            } catch {
                req.logger.error(
                    "Failed to start image fetch: \(error)",
                    metadata: [
                        "image_id": .string(imageId)
                    ])
            }
        }

        return ImageResponse(from: image)
    }

    // MARK: - Create from File Upload

    private func createFromUpload(
        req: Request,
        projectID: UUID,
        userID: UUID,
        storagePath: String
    ) async throws -> ImageResponse {
        // Create a temporary image record first to get an ID
        let tempImage = Image(
            name: "Uploading...",
            description: "",
            projectID: projectID,
            filename: "temp",
            status: .uploading,
            uploadedByID: userID
        )
        try await tempImage.save(on: req.db)

        guard let imageID = tempImage.id else {
            throw Abort(.internalServerError, reason: "Failed to create image record")
        }

        var name: String = "Unnamed Image"
        var description: String = ""
        var filename: String = "image.qcow2"
        var architecture: CPUArchitecture = .x86_64
        var defaultCpu: Int?
        var defaultMemory: Int64?
        var defaultDisk: Int64?
        var defaultCmdline: String?
        var fileData: ByteBuffer?

        // Parse multipart form data
        let sequence = req.body.collect(max: nil)

        // For streaming, we need to handle the multipart form differently
        // Collect the body first
        guard let body = try await sequence.get() else {
            try await tempImage.delete(on: req.db)
            throw Abort(.badRequest, reason: "Empty request body")
        }

        // Verify multipart form data is present
        guard req.headers.contentType?.parameters["boundary"] != nil else {
            try await tempImage.delete(on: req.db)
            throw Abort(.badRequest, reason: "Missing boundary in multipart form")
        }

        // Parse the multipart form using Vapor's built-in parser
        let formData = try FormDataDecoder().decode(ImageUploadForm.self, from: body, headers: req.headers)

        name = formData.name ?? "Unnamed Image"
        description = formData.description ?? ""
        if let file = formData.file {
            filename = try ImageValidationService.validateFilename(file.filename)
            fileData = file.data
        }
        if let archString = formData.architecture {
            guard let arch = CPUArchitecture(rawValue: archString) else {
                try await tempImage.delete(on: req.db)
                throw Abort(.badRequest, reason: "Unknown architecture '\(archString)'")
            }
            architecture = arch
        }
        defaultCpu = formData.defaultCpu
        if let memory = formData.defaultMemory {
            defaultMemory = Int64(memory)
        }
        if let disk = formData.defaultDisk {
            defaultDisk = Int64(disk)
        }
        defaultCmdline = formData.defaultCmdline

        guard let data = fileData else {
            try await tempImage.delete(on: req.db)
            throw Abort(.badRequest, reason: "No file uploaded")
        }

        // Detect format from file header
        let format = ImageValidationService.detectFormat(from: data)

        // Save file to storage
        let relativePath = try await ImageStorageService.saveFile(
            data: data,
            storagePath: storagePath,
            projectId: projectID,
            imageId: imageID,
            filename: filename
        )

        // Compute checksum
        let fullPath = ImageStorageService.getFilePath(storagePath: storagePath, relativePath: relativePath)
        let checksum = try ImageValidationService.computeChecksum(filePath: fullPath)

        // Get file size
        let size = try ImageStorageService.getFileSize(storagePath: storagePath, relativePath: relativePath)

        // Update image record
        tempImage.name = name
        tempImage.description = description
        tempImage.filename = filename
        tempImage.size = size
        tempImage.format = format
        tempImage.architecture = architecture
        tempImage.checksum = checksum
        tempImage.storagePath = relativePath
        tempImage.status = .ready
        tempImage.defaultCpu = defaultCpu
        tempImage.defaultMemory = defaultMemory
        tempImage.defaultDisk = defaultDisk
        tempImage.defaultCmdline = defaultCmdline

        try await tempImage.save(on: req.db)

        // Register the uploaded file as this image's disk-image artifact so the
        // typed artifact set is the source of truth for what an agent fetches.
        let diskArtifact = ImageArtifact(
            imageID: imageID,
            kind: .diskImage,
            format: format,
            architecture: architecture,
            filename: filename,
            size: size,
            checksum: checksum,
            storagePath: relativePath
        )
        try await diskArtifact.save(on: req.db)
        // Reflect the new artifact in the response (relation isn't auto-loaded).
        tempImage.$artifacts.value = [diskArtifact]

        // Create SpiceDB relationships
        let imageId = imageID.uuidString
        try await req.spicedb.writeRelationship(
            entity: "image",
            entityId: imageId,
            relation: "project",
            subject: "project",
            subjectId: projectID.uuidString
        )

        try await req.spicedb.writeRelationship(
            entity: "image",
            entityId: imageId,
            relation: "owner",
            subject: "user",
            subjectId: userID.uuidString
        )

        req.logger.info(
            "Image uploaded successfully",
            metadata: [
                "image_id": .string(imageId),
                "filename": .string(filename),
                "size": .stringConvertible(size),
                "format": .string(format.rawValue),
            ])

        return ImageResponse(from: tempImage)
    }

    // MARK: - Update Image

    func update(req: Request) async throws -> ImageResponse {
        guard let user = req.auth.get(User.self) else {
            throw Abort(.unauthorized)
        }

        guard let projectID = req.parameters.get("projectID", as: UUID.self),
            let imageID = req.parameters.get("imageID", as: UUID.self)
        else {
            throw Abort(.badRequest, reason: "Invalid project or image ID")
        }

        guard let image = try await Image.find(imageID, on: req.db) else {
            throw Abort(.notFound, reason: "Image not found")
        }

        // Verify image belongs to the project
        guard image.$project.id == projectID else {
            throw Abort(.notFound, reason: "Image not found in project")
        }

        // Check permission
        let hasPermission = try await req.spicedb.checkPermission(
            subject: user.id?.uuidString ?? "",
            permission: "update",
            resource: "image",
            resourceId: imageID.uuidString
        )

        guard hasPermission else {
            throw Abort(.forbidden, reason: "Access denied to update image")
        }

        let updateRequest = try req.content.decode(UpdateImageRequest.self)

        if let name = updateRequest.name {
            image.name = name
        }
        if let description = updateRequest.description {
            image.description = description
        }
        if let architecture = updateRequest.architecture {
            image.architecture = architecture
        }
        if let cpu = updateRequest.defaultCpu {
            image.defaultCpu = cpu
        }
        if let memory = updateRequest.defaultMemory {
            image.defaultMemory = memory
        }
        if let disk = updateRequest.defaultDisk {
            image.defaultDisk = disk
        }
        if let cmdline = updateRequest.defaultCmdline {
            image.defaultCmdline = cmdline
        }

        try await image.save(on: req.db)

        req.logger.info("Image updated", metadata: ["image_id": .string(imageID.uuidString)])

        return ImageResponse(from: image)
    }

    // MARK: - Delete Image

    func delete(req: Request) async throws -> HTTPStatus {
        guard let user = req.auth.get(User.self) else {
            throw Abort(.unauthorized)
        }

        guard let projectID = req.parameters.get("projectID", as: UUID.self),
            let imageID = req.parameters.get("imageID", as: UUID.self)
        else {
            throw Abort(.badRequest, reason: "Invalid project or image ID")
        }

        guard let image = try await Image.find(imageID, on: req.db) else {
            throw Abort(.notFound, reason: "Image not found")
        }

        // Verify image belongs to the project
        guard image.$project.id == projectID else {
            throw Abort(.notFound, reason: "Image not found in project")
        }

        // Check permission
        let hasPermission = try await req.spicedb.checkPermission(
            subject: user.id?.uuidString ?? "",
            permission: "delete",
            resource: "image",
            resourceId: imageID.uuidString
        )

        guard hasPermission else {
            throw Abort(.forbidden, reason: "Access denied to delete image")
        }

        // Delete file from storage
        let storagePath = ImageStorageService.storagePath(from: req.application)
        do {
            try ImageStorageService.deleteFile(
                storagePath: storagePath,
                projectId: projectID,
                imageId: imageID
            )
        } catch {
            req.logger.warning(
                "Failed to delete image file: \(error)",
                metadata: [
                    "image_id": .string(imageID.uuidString)
                ])
            // Continue with database deletion even if file deletion fails
        }

        // Delete from database
        try await image.delete(on: req.db)

        req.logger.info("Image deleted", metadata: ["image_id": .string(imageID.uuidString)])

        return .noContent
    }

    // MARK: - Download Image

    func download(req: Request) async throws -> Response {
        guard let projectID = req.parameters.get("projectID", as: UUID.self),
            let imageID = req.parameters.get("imageID", as: UUID.self)
        else {
            throw Abort(.badRequest, reason: "Invalid project or image ID")
        }

        // Optional artifact selector (kernel/rootfs/initramfs/disk-image). Absent
        // means the legacy whole-image disk download.
        let artifactKind: ArtifactKind?
        if let artifactParam = req.query[String.self, at: "artifact"] {
            guard let kind = ArtifactKind(rawValue: artifactParam) else {
                throw Abort(.badRequest, reason: "Unknown artifact kind '\(artifactParam)'")
            }
            artifactKind = kind
        } else {
            artifactKind = nil
        }

        // Try signed URL authentication first (for agents)
        if let agentName = req.query[String.self, at: "agent"],
            let expiresStr = req.query[String.self, at: "expires"],
            let expires = Int(expiresStr),
            let signature = req.query[String.self, at: "sig"]
        {

            // Verify the signing key is configured
            let signingKey: String
            do {
                signingKey = try URLSigningService.getSigningKey(from: req.application)
            } catch {
                req.logger.error("Image download signing key not configured")
                throw error
            }

            // Verify the signature
            let path = "/api/projects/\(projectID)/images/\(imageID)/download"
            let isValid = URLSigningService.verifySignature(
                path: path,
                imageId: imageID,
                projectId: projectID,
                agentName: agentName,
                expires: expires,
                signature: signature,
                signingKey: signingKey,
                artifactKind: artifactKind
            )

            guard isValid else {
                req.logger.warning(
                    "Invalid or expired image download signature",
                    metadata: [
                        "imageId": .string(imageID.uuidString),
                        "agent": .string(agentName),
                    ])
                throw Abort(.forbidden, reason: "Invalid or expired download signature")
            }

            req.logger.info(
                "Agent downloading image via signed URL",
                metadata: [
                    "imageId": .string(imageID.uuidString),
                    "agent": .string(agentName),
                    "artifact": .string(artifactKind?.rawValue ?? "disk"),
                ])

            // Signature valid - serve the file
            return try await serveImageFile(
                req: req, imageID: imageID, projectID: projectID, artifactKind: artifactKind)
        }

        // Fall back to user session authentication
        guard let user = req.auth.get(User.self) else {
            throw Abort(.unauthorized)
        }

        // Check permission via SpiceDB
        let hasPermission = try await req.spicedb.checkPermission(
            subject: user.id?.uuidString ?? "",
            permission: "download",
            resource: "image",
            resourceId: imageID.uuidString
        )

        guard hasPermission else {
            throw Abort(.forbidden, reason: "Access denied to download image")
        }

        return try await serveImageFile(req: req, imageID: imageID, projectID: projectID, artifactKind: artifactKind)
    }

    // MARK: - Serve Image File (shared helper)

    private func serveImageFile(
        req: Request, imageID: UUID, projectID: UUID, artifactKind: ArtifactKind?
    ) async throws -> Response {
        guard let image = try await Image.find(imageID, on: req.db) else {
            throw Abort(.notFound, reason: "Image not found")
        }

        // Verify image belongs to the project
        guard image.$project.id == projectID else {
            throw Abort(.notFound, reason: "Image not found in project")
        }

        // Verify image is ready
        guard image.status == .ready else {
            throw Abort(.badRequest, reason: "Image is not ready for download. Status: \(image.status.rawValue)")
        }

        let basePath = ImageStorageService.storagePath(from: req.application)

        // Serve a specific typed artifact when requested.
        if let artifactKind {
            guard
                let artifact = try await image.$artifacts.query(on: req.db)
                    .filter(\.$kind == artifactKind)
                    .first()
            else {
                throw Abort(.notFound, reason: "Image has no \(artifactKind.rawValue) artifact")
            }
            return try await ImageStorageService.streamFile(
                req: req,
                storagePath: basePath,
                relativePath: artifact.storagePath,
                filename: artifact.filename
            )
        }

        // Legacy whole-image disk download.
        guard let storagePath = image.storagePath else {
            throw Abort(.internalServerError, reason: "Image storage path not set")
        }

        return try await ImageStorageService.streamFile(
            req: req,
            storagePath: basePath,
            relativePath: storagePath,
            filename: image.filename
        )
    }

    // MARK: - Get Image Status

    func status(req: Request) async throws -> ImageStatusResponse {
        guard let user = req.auth.get(User.self) else {
            throw Abort(.unauthorized)
        }

        guard let projectID = req.parameters.get("projectID", as: UUID.self),
            let imageID = req.parameters.get("imageID", as: UUID.self)
        else {
            throw Abort(.badRequest, reason: "Invalid project or image ID")
        }

        guard let image = try await Image.find(imageID, on: req.db) else {
            throw Abort(.notFound, reason: "Image not found")
        }

        // Verify image belongs to the project
        guard image.$project.id == projectID else {
            throw Abort(.notFound, reason: "Image not found in project")
        }

        // Check permission
        let hasPermission = try await req.spicedb.checkPermission(
            subject: user.id?.uuidString ?? "",
            permission: "read",
            resource: "image",
            resourceId: imageID.uuidString
        )

        guard hasPermission else {
            throw Abort(.forbidden, reason: "Access denied to image")
        }

        return ImageStatusResponse(from: image)
    }
}

// MARK: - Helper Types

struct ImageUploadForm: Content {
    var name: String?
    var description: String?
    var file: File?
    var architecture: String?
    var defaultCpu: Int?
    var defaultMemory: Int?
    var defaultDisk: Int?
    var defaultCmdline: String?
}
