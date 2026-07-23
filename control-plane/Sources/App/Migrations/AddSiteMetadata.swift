import Fluent
import SQLKit

/// Expands `Site` metadata (issue-driven follow-up to sites, #343): an
/// operational lifecycle `status`, advisory location fields, and a free-form
/// `labels` map.
///
/// All additive and safe on a populated table:
/// * `status` — `.string` column defaulting to `active`, so every existing
///   site reads back as active. Modeled as an `@Enum` (same pattern as
///   `volumes.status`).
/// * location (`latitude`, `longitude`, `location_label`, `region_code`) — all
///   nullable; a logical zone may have no physical coordinates at all.
/// * `labels` — a JSON object defaulting to `{}`, so existing rows read as an
///   empty (never null) map, matching the non-optional model property.
///
/// One field per `.update()` call, matching `CreateSite` and the rest of the
/// migration set (historically for SQLite compatibility).
struct AddSiteMetadata: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("sites")
            .field("status", .string, .required, .sql(.default("active")))
            .update()
        try await database.schema("sites")
            .field("latitude", .double)
            .update()
        try await database.schema("sites")
            .field("longitude", .double)
            .update()
        try await database.schema("sites")
            .field("location_label", .string)
            .update()
        try await database.schema("sites")
            .field("region_code", .string)
            .update()
        try await database.schema("sites")
            .field("labels", .json, .required, .sql(.default("{}")))
            .update()
    }

    func revert(on database: Database) async throws {
        try await database.schema("sites")
            .deleteField("labels")
            .update()
        try await database.schema("sites")
            .deleteField("region_code")
            .update()
        try await database.schema("sites")
            .deleteField("location_label")
            .update()
        try await database.schema("sites")
            .deleteField("longitude")
            .update()
        try await database.schema("sites")
            .deleteField("latitude")
            .update()
        try await database.schema("sites")
            .deleteField("status")
            .update()
    }
}
