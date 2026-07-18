import Foundation
import Vapor
import Fluent
import NIOCore
import StratoShared

struct ImageController: RouteCollection {
    /// Upper bound on a single multipart upload. Both upload handlers buffer
    /// the whole body in memory (`FormDataDecoder` needs it contiguous), so
    /// this caps peak memory per request and returns 413 rather than letting a
    /// huge image OOM the control plane. Keep it in sync with the compose
    /// proxy's `client_max_body_size`. (A future streaming path could lift it.)
    static let maxUploadBytes = 4 * 1024 * 1024 * 1024  // 4 GiB

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

            // Typed-artifact management (kernel/rootfs/initramfs for Firecracker,
            // or replacing an image's disk-image).
            image.on(.POST, "artifacts", body: .stream, use: uploadArtifact)
            image.post("artifacts", "fetch", use: fetchArtifact)
            image.delete("artifacts", ":kind", use: deleteArtifact)
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

        // No source URL means "create an empty image shell" — a metadata-only
        // image whose artifacts (kernel/rootfs/initramfs or a disk-image) are
        // registered afterwards via the artifacts endpoint. This is how a
        // Firecracker image, which has no single downloadable disk, is created.
        guard let sourceURL = createRequest.sourceURL else {
            return try await createEmpty(
                req: req, projectID: projectID, userID: userID, createRequest: createRequest)
        }

        // Validate URL. The scheme check is a fast client-error; the SSRF guard
        // rejects hosts that resolve to non-public addresses (metadata endpoint,
        // loopback, internal services) before any DB rows are created. The fetch
        // path re-validates at connection time, covering redirects and rebinds.
        guard let url = URL(string: sourceURL) else {
            throw Abort(.badRequest, reason: "Invalid source URL")
        }
        do {
            try await SSRFGuard.validate(
                url: url, environment: req.application.environment, on: req.application.threadPool)
        } catch let error as SSRFGuard.BlockedHostError {
            throw Abort(.badRequest, reason: error.reason)
        }

        // Reject a malformed checksum now rather than after downloading gigabytes
        // only to fail a comparison it could never have passed. Normalised to
        // lowercase so the post-download compare is a plain equality check.
        let expectedChecksum = try createRequest.checksum
            .map(normalizedExpectedChecksum(_:))

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
        image.expectedChecksum = expectedChecksum

        try await image.save(on: req.db)

        // Create SpiceDB relationships and the creator's IAM binding.
        let imageId = try image.requireID().uuidString
        try await writeImageRelationships(
            req: req, imageID: try image.requireID(), projectID: projectID, userID: userID)

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

    // MARK: - Create Empty Image Shell

    /// Creates a metadata-only image with no artifacts yet (status `.pending`).
    /// Artifacts are attached afterwards via `uploadArtifact`; the image becomes
    /// `.ready` once its artifact set is bootable by some hypervisor.
    /// Validates a caller-supplied SHA-256 and returns it lowercased.
    ///
    /// Anything that isn't exactly 64 hex characters could never match a real
    /// digest, so it's a client error rather than a download that's doomed to
    /// fail verification later.
    private func normalizedExpectedChecksum(_ raw: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let isHex = trimmed.count == 64 && trimmed.allSatisfy(\.isHexDigit)
        guard isHex else {
            throw Abort(.badRequest, reason: "Checksum must be a 64-character hex SHA-256 digest")
        }
        return trimmed
    }

    private func createEmpty(
        req: Request,
        projectID: UUID,
        userID: UUID,
        createRequest: CreateImageRequest
    ) async throws -> ImageResponse {
        let image = Image(
            name: createRequest.name,
            description: createRequest.description ?? "",
            projectID: projectID,
            filename: "",
            architecture: createRequest.architecture ?? .x86_64,
            status: .pending,
            uploadedByID: userID,
            defaultCpu: createRequest.defaultCpu,
            defaultMemory: createRequest.defaultMemory,
            defaultDisk: createRequest.defaultDisk,
            defaultCmdline: createRequest.defaultCmdline
        )
        try await image.save(on: req.db)

        try await writeImageRelationships(
            req: req, imageID: image.id!, projectID: projectID, userID: userID)

        req.logger.info(
            "Empty image shell created",
            metadata: ["image_id": .string(image.id!.uuidString)])

        // Relation isn't loaded yet, but an empty shell has no artifacts anyway.
        image.$artifacts.value = []
        return ImageResponse(from: image)
    }

    /// Writes the standard SpiceDB ownership relationships for a new image,
    /// plus the creator's role binding (IAM dual-write, issue #477 — SpiceDB
    /// stays authoritative).
    private func writeImageRelationships(
        req: Request, imageID: UUID, projectID: UUID, userID: UUID
    ) async throws {
        try await RoleBindingService.grant(
            principalType: .user,
            principalID: userID,
            role: .admin,
            nodeType: .image,
            nodeID: imageID,
            createdBy: userID,
            on: req.db
        )
        try await req.spicedb.writeRelationship(
            entity: "image",
            entityId: imageID.uuidString,
            relation: "project",
            subject: "project",
            subjectId: projectID.uuidString
        )
        try await req.spicedb.writeRelationship(
            entity: "image",
            entityId: imageID.uuidString,
            relation: "owner",
            subject: "user",
            subjectId: userID.uuidString
        )
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
        let sequence = req.body.collect(max: Self.maxUploadBytes)

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

        // Detect the format from the file header; an explicit claim overrides it,
        // but only where detection can't contradict it. Two ways it can:
        // another format's signature is present, or the claimed format is one
        // that must carry a signature and doesn't. `.raw` on its own means "no
        // signature matched", which disproves nothing by itself — a raw image
        // and a flat VMDK are equally headerless.
        let detectedFormat = ImageValidationService.detectFormat(from: data)
        var format = detectedFormat
        if let formatString = formData.format {
            guard let claimed = ImageFormat(rawValue: formatString) else {
                try await tempImage.delete(on: req.db)
                throw Abort(.badRequest, reason: "Unknown disk format '\(formatString)'")
            }
            if detectedFormat != claimed {
                let contradicted =
                    detectedFormat != .raw
                    || ImageValidationService.mustHaveHeaderSignature(claimed)
                if contradicted {
                    try await tempImage.delete(on: req.db)
                    throw Abort(
                        .badRequest,
                        reason:
                            "Disk format mismatch: file header is \(detectedFormat.rawValue), but '\(claimed.rawValue)' was specified"
                    )
                }
            }
            format = claimed
        }

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

        // Create SpiceDB relationships and the creator's IAM binding.
        try await writeImageRelationships(
            req: req, imageID: imageID, projectID: projectID, userID: userID)

        req.logger.info(
            "Image uploaded successfully",
            metadata: [
                "image_id": .string(imageID.uuidString),
                "filename": .string(filename),
                "size": .stringConvertible(size),
                "format": .string(format.rawValue),
            ])

        return ImageResponse(from: tempImage)
    }

    // MARK: - Upload Artifact

    /// Registers (or replaces) a single typed artifact on an existing image.
    ///
    /// This is what makes an image usable by direct-kernel-boot hypervisors:
    /// upload a `kernel` and a `rootfs` (and optionally an `initramfs`) to make
    /// the image Firecracker-compatible. Uploading a `disk-image` replaces the
    /// QEMU boot disk. The image transitions to `.ready` once its artifact set
    /// satisfies at least one hypervisor.
    func uploadArtifact(req: Request) async throws -> ImageResponse {
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
        guard image.$project.id == projectID else {
            throw Abort(.notFound, reason: "Image not found in project")
        }

        let hasPermission = try await req.spicedb.checkPermission(
            subject: user.id?.uuidString ?? "",
            permission: "update",
            resource: "image",
            resourceId: imageID.uuidString
        )
        guard hasPermission else {
            throw Abort(.forbidden, reason: "Access denied to update image")
        }

        // Collect and parse the multipart body (mirrors the create-upload path).
        guard let body = try await req.body.collect(max: Self.maxUploadBytes).get() else {
            throw Abort(.badRequest, reason: "Empty request body")
        }
        guard req.headers.contentType?.parameters["boundary"] != nil else {
            throw Abort(.badRequest, reason: "Missing boundary in multipart form")
        }
        let form = try FormDataDecoder().decode(ArtifactUploadForm.self, from: body, headers: req.headers)

        guard let kindString = form.kind, let kind = ArtifactKind(rawValue: kindString) else {
            throw Abort(.badRequest, reason: "Missing or unknown artifact kind '\(form.kind ?? "")'")
        }
        guard let file = form.file else {
            throw Abort(.badRequest, reason: "No file uploaded")
        }
        let filename = try ImageValidationService.validateArtifactFilename(file.filename)

        // Disk-like artifacts carry a format (qcow2/raw); kernel/initramfs are opaque.
        let format: ImageFormat?
        switch kind {
        case .diskImage, .rootfs:
            format = ImageValidationService.detectFormat(from: file.data)
        case .kernel, .initramfs:
            format = nil
        }

        let storagePath = ImageStorageService.storagePath(from: req.application)
        let relativePath = try await ImageStorageService.saveArtifactFile(
            data: file.data,
            storagePath: storagePath,
            projectId: projectID,
            imageId: imageID,
            kind: kind.rawValue,
            filename: filename
        )
        let fullPath = ImageStorageService.getFilePath(storagePath: storagePath, relativePath: relativePath)
        let checksum = try ImageValidationService.computeChecksum(filePath: fullPath)
        let size = try ImageStorageService.getFileSize(storagePath: storagePath, relativePath: relativePath)

        // Replace any existing artifact of this kind (unique on image_id, kind),
        // removing its stored file first.
        if let existing = try await image.$artifacts.query(on: req.db).filter(\.$kind == kind).first() {
            try? ImageStorageService.deleteFileAt(storagePath: storagePath, relativePath: existing.storagePath)
            try await existing.delete(on: req.db)
        }

        let artifact = ImageArtifact(
            imageID: imageID,
            kind: kind,
            format: format,
            architecture: image.architecture,
            filename: filename,
            size: size,
            checksum: checksum,
            storagePath: relativePath
        )
        try await artifact.save(on: req.db)

        // Keep the image's legacy single-file columns pointed at the disk-image so
        // the QEMU disk path and pre-artifact agents stay coherent.
        if kind == .diskImage {
            image.filename = filename
            image.size = size
            image.format = format ?? .raw
            image.checksum = checksum
            image.storagePath = relativePath
            try await image.save(on: req.db)
        }

        try await recomputeStatus(image: image, on: req.db)

        req.logger.info(
            "Image artifact uploaded",
            metadata: [
                "image_id": .string(imageID.uuidString),
                "kind": .string(kind.rawValue),
                "filename": .string(filename),
                "size": .stringConvertible(size),
            ])

        try await image.$artifacts.load(on: req.db)
        return ImageResponse(from: image)
    }

    // MARK: - Fetch Artifact from URL

    /// Registers a typed artifact to be fetched from a URL in the background.
    /// Creates a `pending` artifact immediately and returns 200 with the image;
    /// the artifact becomes `ready` (and the image bootable) once the download
    /// completes. Replaces any existing artifact of the same kind.
    func fetchArtifact(req: Request) async throws -> ImageResponse {
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
        guard image.$project.id == projectID else {
            throw Abort(.notFound, reason: "Image not found in project")
        }

        let hasPermission = try await req.spicedb.checkPermission(
            subject: user.id?.uuidString ?? "",
            permission: "update",
            resource: "image",
            resourceId: imageID.uuidString
        )
        guard hasPermission else {
            throw Abort(.forbidden, reason: "Access denied to update image")
        }

        let fetchRequest = try req.content.decode(ArtifactFetchRequest.self)
        guard let kind = ArtifactKind(rawValue: fetchRequest.kind) else {
            throw Abort(.badRequest, reason: "Unknown artifact kind '\(fetchRequest.kind)'")
        }
        guard let url = URL(string: fetchRequest.sourceURL) else {
            throw Abort(.badRequest, reason: "Invalid source URL")
        }
        // Reject SSRF targets up front; the fetch path re-checks each redirect hop.
        do {
            try await SSRFGuard.validate(
                url: url, environment: req.application.environment, on: req.application.threadPool)
        } catch let error as SSRFGuard.BlockedHostError {
            throw Abort(.badRequest, reason: error.reason)
        }
        let filename = try ImageValidationService.validateArtifactFilename(
            url.lastPathComponent.isEmpty ? kind.rawValue : url.lastPathComponent)

        // The storage layout mirrors uploaded artifacts: {project}/{image}/{kind}/{filename}.
        let relativePath = "\(projectID)/\(imageID)/\(kind.rawValue)/\(filename)"
        let storagePath = ImageStorageService.storagePath(from: req.application)

        // Replace any existing artifact of this kind (unique on image_id, kind).
        if let existing = try await image.$artifacts.query(on: req.db).filter(\.$kind == kind).first() {
            try? ImageStorageService.deleteFileAt(storagePath: storagePath, relativePath: existing.storagePath)
            try await existing.delete(on: req.db)
        }

        // Create the artifact in a pending state; the background fetch fills in
        // size/checksum/format and flips it to ready.
        let artifact = ImageArtifact(
            imageID: imageID,
            kind: kind,
            format: nil,
            architecture: image.architecture,
            filename: filename,
            size: 0,
            checksum: "",
            storagePath: relativePath,
            status: .pending,
            sourceURL: fetchRequest.sourceURL
        )
        try await artifact.save(on: req.db)

        // Removing a prior ready artifact may drop the image below bootable.
        try await recomputeStatus(image: image, on: req.db)

        let artifactId = artifact.id!
        Task {
            do {
                try await req.imageFetchService.startArtifactFetch(artifactId: artifactId)
            } catch {
                req.logger.error(
                    "Failed to start artifact fetch: \(error)",
                    metadata: ["artifact_id": .string(artifactId.uuidString)])
            }
        }

        req.logger.info(
            "Artifact fetch queued",
            metadata: [
                "image_id": .string(imageID.uuidString),
                "kind": .string(kind.rawValue),
                "source_url": .string(fetchRequest.sourceURL),
            ])

        try await image.$artifacts.load(on: req.db)
        return ImageResponse(from: image)
    }

    // MARK: - Delete Artifact

    /// Removes a single typed artifact from an image, deleting its stored file
    /// and recomputing whether the image is still bootable.
    func deleteArtifact(req: Request) async throws -> ImageResponse {
        guard let user = req.auth.get(User.self) else {
            throw Abort(.unauthorized)
        }
        guard let projectID = req.parameters.get("projectID", as: UUID.self),
            let imageID = req.parameters.get("imageID", as: UUID.self),
            let kindString = req.parameters.get("kind")
        else {
            throw Abort(.badRequest, reason: "Invalid project, image, or artifact kind")
        }
        guard let kind = ArtifactKind(rawValue: kindString) else {
            throw Abort(.badRequest, reason: "Unknown artifact kind '\(kindString)'")
        }

        guard let image = try await Image.find(imageID, on: req.db) else {
            throw Abort(.notFound, reason: "Image not found")
        }
        guard image.$project.id == projectID else {
            throw Abort(.notFound, reason: "Image not found in project")
        }

        let hasPermission = try await req.spicedb.checkPermission(
            subject: user.id?.uuidString ?? "",
            permission: "update",
            resource: "image",
            resourceId: imageID.uuidString
        )
        guard hasPermission else {
            throw Abort(.forbidden, reason: "Access denied to update image")
        }

        guard let artifact = try await image.$artifacts.query(on: req.db).filter(\.$kind == kind).first() else {
            throw Abort(.notFound, reason: "Image has no \(kind.rawValue) artifact")
        }

        let storagePath = ImageStorageService.storagePath(from: req.application)
        try? ImageStorageService.deleteFileAt(storagePath: storagePath, relativePath: artifact.storagePath)
        try await artifact.delete(on: req.db)

        try await recomputeStatus(image: image, on: req.db)

        req.logger.info(
            "Image artifact deleted",
            metadata: ["image_id": .string(imageID.uuidString), "kind": .string(kind.rawValue)])

        try await image.$artifacts.load(on: req.db)
        return ImageResponse(from: image)
    }

    /// Recomputes an image's status from its current artifact set: `.ready` when
    /// some hypervisor can boot it, otherwise `.pending`. Persists only on change.
    /// Never overrides an `.error` state or an in-progress download/upload.
    private func recomputeStatus(image: Image, on db: any Database) async throws {
        try await image.$artifacts.load(on: db)

        guard image.status == .ready || image.status == .pending else {
            return  // don't clobber error/downloading/uploading/validating states
        }

        let newStatus: ImageStatus = image.compatibleHypervisors().isEmpty ? .pending : .ready
        if image.status != newStatus {
            image.status = newStatus
            try await image.save(on: db)
        }
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
    /// Raw value of `ImageFormat`. Optional: omitted means "detect from the
    /// file header", which is all callers could do before this field existed.
    var format: String?
    var defaultCpu: Int?
    var defaultMemory: Int?
    var defaultDisk: Int?
    var defaultCmdline: String?
}

/// Multipart form for registering a single typed artifact on an image.
struct ArtifactUploadForm: Content {
    /// Raw value of `ArtifactKind` (disk-image/kernel/rootfs/initramfs).
    var kind: String?
    var file: File?
}

/// JSON body for registering a single typed artifact fetched from a URL.
struct ArtifactFetchRequest: Content {
    /// Raw value of `ArtifactKind` (disk-image/kernel/rootfs/initramfs).
    let kind: String
    let sourceURL: String
}
