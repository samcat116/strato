import Fluent
import Foundation
import SQLKit
import StratoShared
import Vapor

/// Fixed-shape image access used while VM and volume writes still own Fluent
/// transactions. Image snapshots themselves are immutable.
package enum LegacyImageStore {
    package static func image(id: UUID?, on db: any Database) async throws -> Image? {
        guard let id else { return nil }
        let matches = try await images(ids: [id], on: db)
        guard matches.count <= 1 else {
            throw Abort(.internalServerError, reason: "Image lookup returned duplicate rows")
        }
        return matches.first
    }

    package static func images(
        ids: [UUID]? = nil,
        projectIDs: [UUID]? = nil,
        newestFirst: Bool = false,
        on db: any Database
    ) async throws -> [Image] {
        if let ids, ids.isEmpty { return [] }
        if let projectIDs, projectIDs.isEmpty { return [] }
        var query: SQLQueryString =
            "SELECT \(unsafeRaw: columns) FROM images AS i WHERE TRUE"
        if let ids { query += " AND i.id = ANY(\(bind: ids))" }
        if let projectIDs { query += " AND i.project_id = ANY(\(bind: projectIDs))" }
        query += newestFirst
            ? " ORDER BY i.created_at DESC, i.id DESC"
            : " ORDER BY i.created_at, i.id"
        return try await requireSQL(db).raw(query).all(decoding: Record.self).map { try $0.image }
    }

    package static func count(on db: any Database) async throws -> Int {
        struct Count: Decodable { let count: Int }
        return try await requireSQL(db).raw(
            "SELECT count(*)::bigint AS count FROM images"
        ).first(decoding: Count.self)?.count ?? 0
    }

    static func loadingSourceImages(_ vms: [VM], on db: any Database) async throws -> [VM] {
        let ids = Array(Set(vms.compactMap(\.sourceImageID)))
        let loaded = try await LegacyImageArtifactStore.loading(
            images(ids: ids, on: db),
            on: db)
        let byID = Dictionary(uniqueKeysWithValues: loaded.compactMap { image in
            image.id.map { ($0, image) }
        })
        return vms.map { vm in
            vm.loadingSourceImage(vm.sourceImageID.flatMap { byID[$0] })
        }
    }

    static func loadingSourceImages(_ volumes: [Volume], on db: any Database) async throws -> [Volume] {
        let ids = Array(Set(volumes.compactMap(\.sourceImageID)))
        let loaded = try await LegacyImageArtifactStore.loading(
            images(ids: ids, on: db),
            on: db)
        let byID = Dictionary(uniqueKeysWithValues: loaded.compactMap { image in
            image.id.map { ($0, image) }
        })
        return volumes.map { volume in
            volume.replacing(
                loadedSourceImage: .some(volume.sourceImageID.flatMap { byID[$0] }))
        }
    }

    @discardableResult
    package static func insert(_ image: Image, on db: any Database) async throws -> Image {
        let id = try image.requireID()
        guard let row = try await requireSQL(db).raw(
            """
            INSERT INTO images (
                id, name, description, project_id, architecture, status,
                default_cpu, default_memory, default_disk, default_cmdline,
                uploaded_by_id, created_at, updated_at
            ) VALUES (
                \(bind: id), \(bind: image.name), \(bind: image.description),
                \(bind: image.projectID), \(bind: image.architecture.rawValue),
                \(bind: image.status.rawValue), \(bind: image.defaultCpu),
                \(bind: image.defaultMemory), \(bind: image.defaultDisk),
                \(bind: image.defaultCmdline), \(bind: image.uploadedByID),
                CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
            )
            RETURNING \(unsafeRaw: returningColumns)
            """
        ).first(decoding: Record.self) else {
            throw Abort(.internalServerError, reason: "Could not create image")
        }
        return try row.image
    }

    @discardableResult
    package static func update(
        id: UUID,
        name: String,
        description: String,
        architecture: CPUArchitecture,
        defaultCpu: Int?,
        defaultMemory: Int64?,
        defaultDisk: Int64?,
        defaultCmdline: String?,
        on db: any Database
    ) async throws -> Image? {
        try await requireSQL(db).raw(
            """
            UPDATE images
            SET name = \(bind: name),
                description = \(bind: description),
                architecture = \(bind: architecture.rawValue),
                default_cpu = \(bind: defaultCpu),
                default_memory = \(bind: defaultMemory),
                default_disk = \(bind: defaultDisk),
                default_cmdline = \(bind: defaultCmdline),
                updated_at = CURRENT_TIMESTAMP
            WHERE id = \(bind: id)
            RETURNING \(unsafeRaw: returningColumns)
            """
        ).first(decoding: Record.self).map { try $0.image }
    }

    @discardableResult
    package static func updateStatus(
        id: UUID,
        status: ImageStatus,
        on db: any Database
    ) async throws -> Image? {
        try await requireSQL(db).raw(
            """
            UPDATE images
            SET status = \(bind: status.rawValue), updated_at = CURRENT_TIMESTAMP
            WHERE id = \(bind: id)
            RETURNING \(unsafeRaw: returningColumns)
            """
        ).first(decoding: Record.self).map { try $0.image }
    }

    @discardableResult
    package static func delete(id: UUID, on db: any Database) async throws -> UUID? {
        struct Deleted: Decodable { let id: UUID }
        return try await requireSQL(db).raw(
            "DELETE FROM images WHERE id = \(bind: id) RETURNING id"
        ).first(decoding: Deleted.self)?.id
    }

    private struct Record: Decodable, Sendable {
        let id: UUID
        let name: String
        let description: String
        let projectID: UUID
        let architecture: String
        let status: String
        let defaultCpu: Int?
        let defaultMemory: Int64?
        let defaultDisk: Int64?
        let defaultCmdline: String?
        let uploadedByID: UUID
        let createdAt: Date?
        let updatedAt: Date?

        var image: Image {
            get throws {
                guard let architecture = CPUArchitecture(rawValue: architecture),
                    let status = ImageStatus(rawValue: status)
                else {
                    throw Abort(.internalServerError, reason: "Image row has invalid stored values")
                }
                return Image(
                    id: id,
                    name: name,
                    description: description,
                    projectID: projectID,
                    architecture: architecture,
                    status: status,
                    uploadedByID: uploadedByID,
                    defaultCpu: defaultCpu,
                    defaultMemory: defaultMemory,
                    defaultDisk: defaultDisk,
                    defaultCmdline: defaultCmdline,
                    createdAt: createdAt,
                    updatedAt: updatedAt)
            }
        }
    }

    private static let columns = """
        i.id,
        i.name,
        i.description,
        i.project_id AS "projectID",
        i.architecture,
        i.status,
        i.default_cpu AS "defaultCpu",
        i.default_memory AS "defaultMemory",
        i.default_disk AS "defaultDisk",
        i.default_cmdline AS "defaultCmdline",
        i.uploaded_by_id AS "uploadedByID",
        i.created_at AS "createdAt",
        i.updated_at AS "updatedAt"
        """

    private static let returningColumns = """
        id,
        name,
        description,
        project_id AS "projectID",
        architecture,
        status,
        default_cpu AS "defaultCpu",
        default_memory AS "defaultMemory",
        default_disk AS "defaultDisk",
        default_cmdline AS "defaultCmdline",
        uploaded_by_id AS "uploadedByID",
        created_at AS "createdAt",
        updated_at AS "updatedAt"
        """

    private static func requireSQL(_ db: any Database) throws -> any SQLDatabase {
        guard let sql = db as? any SQLDatabase else {
            throw Abort(.internalServerError, reason: "Image compatibility access requires PostgreSQL")
        }
        return sql
    }
}
