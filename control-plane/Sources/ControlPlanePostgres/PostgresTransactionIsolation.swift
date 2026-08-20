public enum PostgresTransactionIsolation: Sendable {
    case readCommitted
    case repeatableRead
    case serializable

    var beginSQL: String {
        switch self {
        case .readCommitted:
            "BEGIN ISOLATION LEVEL READ COMMITTED"
        case .repeatableRead:
            "BEGIN ISOLATION LEVEL REPEATABLE READ"
        case .serializable:
            "BEGIN ISOLATION LEVEL SERIALIZABLE"
        }
    }
}
