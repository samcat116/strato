import Fluent
import Foundation
import SQLKit

/// A cluster-visible instant sourced from PostgreSQL rather than this
/// process's wall clock. Durable deadlines and maintenance verdicts accept
/// this type so a bare `Date()` cannot silently become shared time.
struct ClusterInstant: Equatable, Sendable {
    let date: Date
    let localClockOffsetSeconds: TimeInterval

    fileprivate init(date: Date, localClockOffsetSeconds: TimeInterval) {
        self.date = date
        self.localClockOffsetSeconds = localClockOffsetSeconds
    }

    /// Whether this replica agrees closely enough with PostgreSQL to perform
    /// belt-and-braces destructive maintenance. The predicates themselves use
    /// `date`, so skew cannot move a deadline; this fence protects future code
    /// and makes a badly drifting replica fail closed.
    var permitsDestructiveSweeps: Bool {
        abs(localClockOffsetSeconds) <= ClusterClock.destructiveSweepOffsetLimitSeconds
    }

    /// Explicit test seam. Production code obtains values through
    /// `ClusterClock.read(on:)`.
    static func testing(_ date: Date) -> Self {
        Self(date: date, localClockOffsetSeconds: 0)
    }

    static func testing(
        _ date: Date,
        localClockOffsetSeconds: TimeInterval
    ) -> Self {
        Self(date: date, localClockOffsetSeconds: localClockOffsetSeconds)
    }
}

enum ClusterClock {
    /// Small enough to catch broken or missing time synchronization before it
    /// becomes operationally significant.
    static let warningOffsetSeconds: TimeInterval = 1

    /// Large enough to tolerate normal scheduling and query latency, but far
    /// below the shortest convergence budget. A replica beyond this offset
    /// declines irreversible maintenance.
    static let destructiveSweepOffsetLimitSeconds: TimeInterval = 30

    private struct DatabaseClockRow: Decodable {
        let databaseTime: Date

        enum CodingKeys: String, CodingKey {
            case databaseTime = "database_time"
        }
    }

    /// Reads PostgreSQL's transaction-stable clock once and estimates this
    /// replica's offset using the midpoint of the local round trip.
    static func read(
        on database: any Database,
        localTime: @Sendable () -> Date = { Date() }
    ) async throws -> ClusterInstant {
        guard let sql = database as? any SQLDatabase else {
            throw ClusterClockError.sqlDatabaseRequired
        }
        let before = localTime()
        let row = try await sql.raw("SELECT now() AS database_time")
            .first(decoding: DatabaseClockRow.self)
        let after = localTime()
        guard let row else { throw ClusterClockError.missingDatabaseTime }

        let midpoint = before.addingTimeInterval(after.timeIntervalSince(before) / 2)
        return ClusterInstant(
            date: row.databaseTime,
            localClockOffsetSeconds: row.databaseTime.timeIntervalSince(midpoint))
    }
}

enum ClusterClockError: Error {
    case sqlDatabaseRequired
    case missingDatabaseTime
}
