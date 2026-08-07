import Fluent
import SQLKit

/// The columns that turn reboot and restore into edge-nonces on desired state
/// (ADR 0001 stage 9, STR-151).
///
/// These three verbs — VM reboot, VM restore, sandbox restore — were the last
/// interactions with a durable resource still dispatched as imperative agent
/// RPCs, and they resisted every earlier stage for one reason: they are *edges*.
/// A reboot starts and ends `.running`, so `desired_status` cannot express it,
/// and "the VM should be at checkpoint C" is not re-convergeable, because the
/// guest starts writing the moment it resumes.
///
/// Counting them is what makes them states. `reboot_generation` is a monotonic
/// tally of how many times each verb was asked for; the agent records the last
/// nonce it applied in its own durable manifest and acts only when the desired
/// one outranks it. Everything else — the `202`, the conditions, the
/// stuck-convergence sweep, the webhook — comes free from the ordinary
/// `generation` bump that rides alongside.
///
/// All four columns are counters and pointers rather than intents, so the
/// backfill is trivial and total: `0` means "never asked for", and every
/// workload that existed before this migration had indeed never been asked
/// through this path. A `restore_snapshot_id` is meaningless without a nonce
/// above zero, and is deliberately **not** a foreign key: the artifact it names
/// may be deleted long after the restore it drove, and a `RESTRICT` there would
/// make an ordinary checkpoint cleanup fail on a VM that was once restored.
struct AddEdgeNoncesToWorkloads: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(VM.schema)
            .field("reboot_generation", .int64, .required, .custom("DEFAULT 0"))
            .field("restore_generation", .int64, .required, .custom("DEFAULT 0"))
            .field("restore_snapshot_id", .uuid)
            .update()

        // Sandboxes get restore only. `POST /api/sandboxes/:id/restart` is
        // already expressed as a fresh desired-running generation rather than an
        // edge, so there is no reboot nonce for one to carry.
        try await database.schema(Sandbox.schema)
            .field("restore_generation", .int64, .required, .custom("DEFAULT 0"))
            .field("restore_snapshot_id", .uuid)
            .update()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(VM.schema)
            .deleteField("reboot_generation")
            .deleteField("restore_generation")
            .deleteField("restore_snapshot_id")
            .update()
        try await database.schema(Sandbox.schema)
            .deleteField("restore_generation")
            .deleteField("restore_snapshot_id")
            .update()
    }
}
