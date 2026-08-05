import Foundation
import OpenAPIRuntime

/// User-facing CLI failures. `description` is what gets printed to stderr.
public enum CLIError: Error, CustomStringConvertible, Sendable {
    /// The server rejected the request (non-2xx). Message is the decoded
    /// `{reason}`/`{error}` body when present.
    case api(status: Int, message: String)
    /// No stored credentials, or refresh failed — the user must `strato login`.
    case notLoggedIn(String)
    case network(String)
    case config(String)
    /// The server answered with something the CLI's compiled-in copy of the
    /// API contract does not describe — the control plane is newer or older
    /// than this binary.
    case unexpectedResponse(String)
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
        case .unexpectedResponse(let detail):
            return "\(detail) Check that the CLI and the control plane are the same version."
        case .operationFailed(let kind, let message):
            return "Operation '\(kind)' failed: \(message)"
        case .timedOut(let detail):
            return detail
        }
    }
}

extension CLIError {
    /// Recovers the CLI error behind whatever a generated operation threw.
    ///
    /// `swift-openapi-runtime` wraps everything a middleware, transport, or
    /// decoder throws in a `ClientError`, so the errors our middlewares raise
    /// arrive buried. Anything that is not one of ours means the response did
    /// not match the spec this binary was generated from — the drift signal
    /// the generated client exists to produce.
    public static func from(_ error: any Error) -> CLIError? {
        switch error {
        case let cliError as CLIError:
            return cliError
        case let clientError as ClientError:
            if let underlying = from(clientError.underlyingError) { return underlying }
            return .unexpectedResponse(
                "The server's response to '\(clientError.operationID)' did not match the API contract "
                    + "(\(clientError.causeDescription)).")
        default:
            return nil
        }
    }
}
