import Fluent

/// IAM #610: guardrails join roles and authored policies on the
/// "`cedar_text` is the compiled source of truth" model.
///
/// - `cedar_text` holds the Cedar `forbid` the guardrail compiles to. It is the
///   text the policy-set cache compiles verbatim (like `iam_policies`), rather
///   than regenerating from the structured matchers on every rebuild. Nullable
///   because rows created before this migration have none until they are next
///   written or the boot backfill runs; the cache falls back to matcher
///   generation for a null.
/// - `authored` records which input produced the row: `false` for a guardrail
///   assembled from the fixed matcher vocabulary (the builder — the matcher
///   columns stay canonical), `true` for one an admin wrote as free-form forbid
///   Cedar (the matcher columns are inert placeholders and `cedar_text` is the
///   whole story).
struct AddCedarTextToGuardrail: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema("iam_guardrails")
            .field("cedar_text", .string)
            .update()
        try await database.schema("iam_guardrails")
            .field("authored", .bool, .required, .custom("DEFAULT FALSE"))
            .update()
    }

    func revert(on database: Database) async throws {
        try await database.schema("iam_guardrails")
            .deleteField("cedar_text")
            .update()
        try await database.schema("iam_guardrails")
            .deleteField("authored")
            .update()
    }
}
