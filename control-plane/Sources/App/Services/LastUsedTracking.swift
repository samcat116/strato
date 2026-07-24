import Fluent
import Foundation
import Vapor

/// A bearer credential that records when, and from where, it was last
/// presented (`last_used_at` / `last_used_ip`).
///
/// The recorded values only feed a "last used" column in the settings UI, so
/// they are written on a coarse schedule instead of once per authenticated
/// request — see ``recordUsage(ip:on:now:)``.
protocol LastUsedTracked: Model where IDValue == UUID {
    var lastUsedAt: Date? { get }

    /// Column keys for the targeted two-column write. Fluent cannot derive
    /// these generically, and naming them keeps the update off the model's
    /// other columns.
    static var lastUsedAtKey: FieldKey { get }
    static var lastUsedIPKey: FieldKey { get }
}

extension LastUsedTracked {
    /// How stale a recorded timestamp may get before the next authenticated
    /// request writes it forward.
    ///
    /// Writing on every request made database write load track request rate
    /// and serialized concurrent requests on a single hot row — a CI pipeline
    /// hammering one API key contends with itself on every call. A "last used"
    /// display doesn't need better than quarter-hour resolution, so one
    /// request per window pays the write and the rest read-and-skip.
    static var lastUsedDebounceWindow: TimeInterval { 15 * 60 }

    /// Whether this credential's recorded timestamp has fallen outside the
    /// debounce window (a credential that has never been used always has).
    ///
    /// A timestamp *ahead* of `now` — clock skew between replicas — reads as
    /// fresh and is left alone rather than being dragged backwards.
    func lastUsedIsStale(now: Date = Date()) -> Bool {
        guard let lastUsedAt else { return true }
        return now.timeIntervalSince(lastUsedAt) >= Self.lastUsedDebounceWindow
    }

    /// Record this credential as used, at most once per debounce window.
    ///
    /// Returns immediately: the write is fire-and-forget so authentication
    /// never waits on it, and it is registered with the background-task
    /// registry so shutdown drains it instead of tearing Fluent out from under
    /// it (the crash class fixed in #584). The row is updated through the query
    /// builder rather than `save`, so the statement carries the two columns
    /// (plus the `updated_at` stamp Fluent adds to any update) instead of
    /// rewriting every column of the credential.
    ///
    /// The debounce is time-only. A key presented from a new IP inside the
    /// window keeps the previously recorded IP until the window elapses;
    /// keying on the IP as well would restore per-request writes for any
    /// client behind rotating egress addresses, which is the load this exists
    /// to remove.
    func recordUsage(ip: String?, on app: Application, now: Date = Date()) {
        guard let id, lastUsedIsStale(now: now) else { return }

        let staleBefore = now.addingTimeInterval(-Self.lastUsedDebounceWindow)

        app.backgroundTasks.spawn {
            // `liveDB`, not `app.db`: shutdown's drain may have cancelled us,
            // after which reading `app.db` force-unwraps nil (see
            // `Application.liveDB`).
            guard let db = app.liveDB else { return }

            do {
                try await Self.query(on: db)
                    .filter(.id, .equal, id)
                    // The staleness check above ran against a row read before
                    // this write, so concurrent requests on one credential can
                    // all decide to write. Repeating the check as a predicate
                    // lets the database settle it: the first writer's value
                    // fails the others' `WHERE`, and one window still costs one
                    // row write no matter how many callers raced.
                    .group(.or) { stale in
                        stale.filter(Self.lastUsedAtKey, .equal, Date?.none)
                        stale.filter(Self.lastUsedAtKey, .lessThan, staleBefore)
                    }
                    .set([
                        Self.lastUsedAtKey: .bind(now),
                        Self.lastUsedIPKey: ip.map { .bind($0) } ?? .null,
                    ])
                    .update()
            } catch {
                app.logger.debug(
                    "Failed to record last-used for \(Self.schema) \(id): \(String(reflecting: error))")
            }
        }
    }
}

extension APIKey: LastUsedTracked {
    static let lastUsedAtKey: FieldKey = "last_used_at"
    static let lastUsedIPKey: FieldKey = "last_used_ip"
}

extension CLISession: LastUsedTracked {
    static let lastUsedAtKey: FieldKey = "last_used_at"
    static let lastUsedIPKey: FieldKey = "last_used_ip"
}

extension SCIMToken: LastUsedTracked {
    static let lastUsedAtKey: FieldKey = "last_used_at"
    static let lastUsedIPKey: FieldKey = "last_used_ip"
}
