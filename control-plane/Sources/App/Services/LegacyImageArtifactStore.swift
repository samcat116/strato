import Fluent
import Foundation
import SQLKit
import StratoShared
import Vapor

public enum ArtifactStatus: String, Codable, CaseIterable, Sendable {
    case pending
    case downloading
    case ready
    case error
}

package struct ImageArtifactSnapshot: Equatable, Sendable {
    let id: UUID
    let imageID: UUID
    let kind: ArtifactKind
    let format: ImageFormat?
    let architecture: CPUArchitecture
    let filename: String
    let size: Int64
    let checksum: String
    let expectedChecksum: String?
    let storagePath: String
    let status: ArtifactStatus
    let sourceURL: String?
    let downloadProgress: Int?
    let errorMessage: String?
    let createdAt: Date?
    let updatedAt: Date?

    init(
        id: UUID = UUID(),
        imageID: UUID,
        kind: ArtifactKind,
        format: ImageFormat?,
        architecture: CPUArchitecture,
        filename: String,
        size: Int64,
        checksum: String,
        expectedChecksum: String? = nil,
        storagePath: String,
        status: ArtifactStatus = .ready,
        sourceURL: String? = nil,
        downloadProgress: Int? = nil,
        errorMessage: String? = nil,
        createdAt: Date? = nil,
        updatedAt: Date? = nil
    ) {
        self.id = id
        self.imageID = imageID
        self.kind = kind
        self.format = format
        self.architecture = architecture
        self.filename = filename
        self.size = size
        self.checksum = checksum
        self.expectedChecksum = expectedChecksum
        self.storagePath = storagePath
        self.status = status
        self.sourceURL = sourceURL
        self.downloadProgress = downloadProgress
        self.errorMessage = errorMessage
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    var isUsable: Bool {
        guard status == .ready, !filename.isEmpty, !storagePath.isEmpty,
            size >= 0, checksum.count == 64, checksum.allSatisfy(\.isHexDigit)
        else { return false }
        switch kind {
        case .diskImage, .rootfs: return format != nil
        case .kernel, .initramfs: return true
        }
    }

    struct Public: Content, Sendable {
        let id: UUID
        let kind: ArtifactKind
        let format: ImageFormat?
        let architecture: CPUArchitecture
        let filename: String
        let size: Int64
        let checksum: String
        let status: ArtifactStatus
        let sourceURL: String?
        let downloadProgress: Int?
        let errorMessage: String?
    }

    func asPublic() -> Public {
        Public(
            id: id, kind: kind, format: format, architecture: architecture,
            filename: filename, size: size, checksum: checksum, status: status,
            sourceURL: sourceURL, downloadProgress: downloadProgress,
            errorMessage: errorMessage)
    }
}

package enum LegacyImageArtifactStore {
    static func artifacts(
        imageIDs: [UUID],
        on db: any Database
    ) async throws -> [ImageArtifactSnapshot] {
        guard !imageIDs.isEmpty else { return [] }
        return try await snapshots(from: requireSQL(db).raw(
            """
            SELECT \(unsafeRaw: columns)
            FROM image_artifacts
            WHERE image_id = ANY(\(bind: imageIDs))
            ORDER BY created_at, id
            """
        ).all(decoding: Record.self))
    }

    static func artifacts(
        imageID: UUID,
        on db: any Database
    ) async throws -> [ImageArtifactSnapshot] {
        try await artifacts(imageIDs: [imageID], on: db)
    }

    static func artifact(
        id: UUID,
        on db: any Database
    ) async throws -> ImageArtifactSnapshot? {
        guard let row = try await requireSQL(db).raw(
            "SELECT \(unsafeRaw: columns) FROM image_artifacts WHERE id = \(bind: id) LIMIT 1"
        ).first(decoding: Record.self) else { return nil }
        return try row.snapshot()
    }

    static func artifact(
        imageID: UUID,
        kind: ArtifactKind,
        status: ArtifactStatus? = nil,
        on db: any Database
    ) async throws -> ImageArtifactSnapshot? {
        let sql = try requireSQL(db)
        var query: SQLQueryString =
            "SELECT \(unsafeRaw: columns) FROM image_artifacts WHERE image_id = \(bind: imageID) AND kind = \(bind: kind.rawValue)"
        if let status { query += " AND status = \(bind: status.rawValue)" }
        query += " LIMIT 1"
        guard let row = try await sql.raw(query).first(decoding: Record.self) else { return nil }
        return try row.snapshot()
    }

    @discardableResult
    package static func insert(
        id: UUID = UUID(),
        imageID: UUID,
        kind: ArtifactKind,
        format: ImageFormat?,
        architecture: CPUArchitecture,
        filename: String,
        size: Int64,
        checksum: String,
        storagePath: String,
        status: ArtifactStatus = .ready,
        sourceURL: String? = nil,
        expectedChecksum: String? = nil,
        on db: any Database
    ) async throws -> ImageArtifactSnapshot {
        guard let row = try await requireSQL(db).raw(
            """
            INSERT INTO image_artifacts (
                id, image_id, kind, format, architecture, filename, size,
                checksum, expected_checksum, storage_path, status, source_url,
                download_progress, error_message, created_at, updated_at
            ) VALUES (
                \(bind: id), \(bind: imageID), \(bind: kind.rawValue),
                \(bind: format?.rawValue), \(bind: architecture.rawValue),
                \(bind: filename), \(bind: size), \(bind: checksum),
                \(bind: expectedChecksum), \(bind: storagePath), \(bind: status.rawValue),
                \(bind: sourceURL), NULL, NULL, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
            )
            RETURNING \(unsafeRaw: columns)
            """
        ).first(decoding: Record.self) else {
            throw Abort(.internalServerError, reason: "Could not create image artifact")
        }
        return try row.snapshot()
    }

    @discardableResult
    static func markDownloading(
        id: UUID,
        on db: any Database
    ) async throws -> ImageArtifactSnapshot? {
        try await update(
            id: id,
            assignments: "status = \(bind: ArtifactStatus.downloading.rawValue), download_progress = 0",
            on: db)
    }

    @discardableResult
    static func updateProgress(
        id: UUID,
        progress: Int,
        on db: any Database
    ) async throws -> ImageArtifactSnapshot? {
        try await update(id: id, assignments: "download_progress = \(bind: progress)", on: db)
    }

    @discardableResult
    static func markReady(
        id: UUID,
        size: Int64,
        checksum: String,
        format: ImageFormat?,
        on db: any Database
    ) async throws -> ImageArtifactSnapshot? {
        try await update(
            id: id,
            assignments: """
                size = \(bind: size), checksum = \(bind: checksum),
                format = COALESCE(\(bind: format?.rawValue), format),
                status = \(bind: ArtifactStatus.ready.rawValue),
                download_progress = 100, error_message = NULL
                """,
            on: db)
    }

    @discardableResult
    static func markError(
        id: UUID,
        error: String,
        on db: any Database
    ) async throws -> ImageArtifactSnapshot? {
        try await update(
            id: id,
            assignments: "status = \(bind: ArtifactStatus.error.rawValue), error_message = \(bind: error)",
            on: db)
    }

    @discardableResult
    static func delete(id: UUID, on db: any Database) async throws -> UUID? {
        struct Deleted: Decodable { let id: UUID }
        return try await requireSQL(db).raw(
            "DELETE FROM image_artifacts WHERE id = \(bind: id) RETURNING id"
        ).first(decoding: Deleted.self)?.id
    }

    static func count(on db: any Database) async throws -> Int {
        struct Count: Decodable { let count: Int }
        return try await requireSQL(db).raw(
            "SELECT count(*)::bigint AS count FROM image_artifacts"
        ).first(decoding: Count.self)?.count ?? 0
    }

    static func loading(_ images: [Image], on db: any Database) async throws -> [Image] {
        let byImage = Dictionary(grouping: try await artifacts(
            imageIDs: images.compactMap(\.id), on: db), by: \.imageID)
        return images.map { image in
            image.loading(artifacts: image.id.flatMap { byImage[$0] } ?? [])
        }
    }

    static func loading(_ image: Image, on db: any Database) async throws -> Image {
        try await loading([image], on: db).first ?? image.loading(artifacts: [])
    }

    private static func update(
        id: UUID,
        assignments: SQLQueryString,
        on db: any Database
    ) async throws -> ImageArtifactSnapshot? {
        guard let row = try await requireSQL(db).raw(
            "UPDATE image_artifacts SET \(assignments), updated_at = CURRENT_TIMESTAMP WHERE id = \(bind: id) RETURNING \(unsafeRaw: columns)"
        ).first(decoding: Record.self) else { return nil }
        return try row.snapshot()
    }

    private struct Record: Decodable, Sendable {
        let id: UUID
        let imageID: UUID
        let kind: String
        let format: String?
        let architecture: String
        let filename: String
        let size: Int64
        let checksum: String
        let expectedChecksum: String?
        let storagePath: String
        let status: String
        let sourceURL: String?
        let downloadProgress: Int?
        let errorMessage: String?
        let createdAt: Date?
        let updatedAt: Date?

        func snapshot() throws -> ImageArtifactSnapshot {
            guard let kind = ArtifactKind(rawValue: kind),
                let architecture = CPUArchitecture(rawValue: architecture),
                let status = ArtifactStatus(rawValue: status)
            else { throw Abort(.internalServerError, reason: "Image artifact has invalid persisted values") }
            let format = try format.map { raw in
                guard let value = ImageFormat(rawValue: raw) else {
                    throw Abort(.internalServerError, reason: "Image artifact has invalid format")
                }
                return value
            }
            return ImageArtifactSnapshot(
                id: id, imageID: imageID, kind: kind, format: format,
                architecture: architecture, filename: filename, size: size,
                checksum: checksum, expectedChecksum: expectedChecksum,
                storagePath: storagePath, status: status, sourceURL: sourceURL,
                downloadProgress: downloadProgress, errorMessage: errorMessage,
                createdAt: createdAt, updatedAt: updatedAt)
        }
    }

    private static let columns = """
        id, image_id AS "imageID", kind, format, architecture, filename, size,
        checksum, expected_checksum AS "expectedChecksum", storage_path AS "storagePath",
        status, source_url AS "sourceURL", download_progress AS "downloadProgress",
        error_message AS "errorMessage", created_at AS "createdAt", updated_at AS "updatedAt"
        """

    private static func snapshots(from rows: [Record]) throws -> [ImageArtifactSnapshot] {
        try rows.map { try $0.snapshot() }
    }

    private static func requireSQL(_ db: any Database) throws -> any SQLDatabase {
        guard let sql = db as? any SQLDatabase else {
            throw Abort(.internalServerError, reason: "Image artifacts require PostgreSQL")
        }
        return sql
    }
}
