import Foundation

/// User-facing CLI failures. `description` is what gets printed to stderr.
public enum CLIError: Error, CustomStringConvertible, Sendable {
    /// The server rejected the request (non-2xx). Message is the decoded
    /// `{reason}`/`{error}` body when present.
    case api(status: Int, message: String)
    /// No stored credentials, or refresh failed — the user must `strato login`.
    case notLoggedIn(String)
    case network(String)
    case config(String)
    /// A polled operation reached the `failed` state.
    case operationFailed(kind: String, message: String)
    case timedOut(String)

    public var description: String {
        switch self {
        case .api(let status, let message):
            return message.isEmpty ? "Request failed with status \(status)" : "\(message) (HTTP \(status))"
        case .notLoggedIn(let detail):
            return "\(detail) Run 'strato login' to sign in."
        case .network(let detail):
            return "Network error: \(detail)"
        case .config(let detail):
            return detail
        case .operationFailed(let kind, let message):
            return "Operation '\(kind)' failed: \(message)"
        case .timedOut(let detail):
            return detail
        }
    }
}
