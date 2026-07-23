import Fluent
import Foundation
import Vapor

/// Boot-time backfill that populates `iam_guardrails.cedar_text` for rows
/// written before #610 (IAM guardrails onto authored Cedar).
///
/// The stored Cedar forbid is the compiled source of truth since #610, but the
/// migration only adds the column — it leaves `cedar_text` NULL on rows that
/// pre-date it. This regenerates the text from each such row's matchers, the
/// same generation the write path uses (`GuardrailStore.generateCedarText`), so
/// the column becomes dense.
///
/// Idempotent — it only touches NULL rows — and it needs **no** policy-set
/// version bump: regenerating from unchanged matchers is byte-identical to what
/// the cache's null-fallback already compiles, so the compiled output does not
/// change. That equivalence is exactly why the fallback is safe in the window
/// before this runs, and why the fallback must stay: this densifies the column,
/// it does not replace the fallback.
///
/// Only matcher-built rows can be NULL here — an authored row always carries the
/// text it was written with.
enum GuardrailCedarTextBackfill {

    /// Fill any NULL `cedar_text` from the row's matchers, returning how many
    /// rows were populated.
    @discardableResult
    static func backfill(on db: any Database, logger: Logger) async throws -> Int {
        let rows = try await Guardrail.query(on: db).filter(\.$cedarText == nil).all()
        guard !rows.isEmpty else { return 0 }

        var filled = 0
        for row in rows {
            // A row the assembler skips (an unknown node type, or an external
            // ceiling whose attach node resolves to no organization) stays NULL
            // — the same row the compiled set leaves out either way — rather than
            // being written a text the generator refused to produce.
            guard let text = try await GuardrailStore.generateCedarText(for: row, on: db) else { continue }
            row.cedarText = text
            try await row.save(on: db)
            filled += 1
        }
        if filled > 0 {
            logger.info(
                "Backfilled guardrail cedar_text from matchers",
                metadata: ["count": .stringConvertible(filled)])
        }
        return filled
    }
}
