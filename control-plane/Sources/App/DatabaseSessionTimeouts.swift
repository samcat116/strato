import Fluent
import NIOCore
import SQLKit

/// Serving budgets are session settings, applied after authentication so they
/// work with PgBouncer. Migrations temporarily disable these two budgets on
/// their pinned connection; their separate statement deadline remains active.
struct DatabaseSessionTimeouts: Sendable, Equatable {
    static let defaults = Self(lockMilliseconds: 5_000, idleInTransactionMilliseconds: 60_000, validated: ())
    let lockMilliseconds: Int
    let idleInTransactionMilliseconds: Int

    private init(lockMilliseconds: Int, idleInTransactionMilliseconds: Int, validated: Void) {
        self.lockMilliseconds = lockMilliseconds
        self.idleInTransactionMilliseconds = idleInTransactionMilliseconds
    }

    init(lockMilliseconds: Int, idleInTransactionMilliseconds: Int) throws {
        for (key, value) in [
            ("DATABASE_LOCK_TIMEOUT_MS", lockMilliseconds),
            ("DATABASE_IDLE_IN_TRANSACTION_TIMEOUT_MS", idleInTransactionMilliseconds),
        ] {
            guard (1...DatabaseStatementTimeout.maximumMilliseconds).contains(value) else {
                throw DatabaseStatementTimeoutConfigurationError.invalidValue(environmentKey: key, raw: String(value))
            }
        }
        self.init(
            lockMilliseconds: lockMilliseconds, idleInTransactionMilliseconds: idleInTransactionMilliseconds,
            validated: ())
    }

    func apply(on database: any Database, migration: Bool = false) -> EventLoopFuture<Void> {
        guard let sql = database as? any SQLDatabase else {
            return database.eventLoop.makeFailedFuture(DatabaseStatementTimeoutConfigurationError.postgresRequired)
        }
        return apply(on: sql, migration: migration)
    }

    func apply(on database: any SQLDatabase, migration: Bool = false) -> EventLoopFuture<Void> {
        database.raw(
            """
            SELECT set_config('lock_timeout', \(bind: String(migration ? 0 : lockMilliseconds)), false),
                   set_config('idle_in_transaction_session_timeout', \(bind: String(migration ? 0 : idleInTransactionMilliseconds)), false)
            """
        ).run()
    }
}
