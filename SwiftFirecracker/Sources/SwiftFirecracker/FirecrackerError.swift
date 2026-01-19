import Foundation

/// Errors that can occur when interacting with Firecracker
public enum FirecrackerError: Error, Sendable {
    /// The Firecracker socket is not connected
    case notConnected

    /// The VM was not found
    case vmNotFound(String)

    /// The VM is already running
    case vmAlreadyRunning(String)

    /// The VM is not running
    case vmNotRunning(String)

    /// Invalid configuration provided
    case invalidConfiguration(String)

    /// HTTP request failed
    case httpError(statusCode: Int, message: String)

    /// Failed to connect to the Firecracker socket
    case connectionFailed(String)

    /// Socket path is invalid or inaccessible
    case invalidSocketPath(String)

    /// Timeout waiting for operation
    case timeout(String)

    /// Failed to serialize request body
    case serializationError(String)

    /// Failed to deserialize response body
    case deserializationError(String)

    /// Firecracker binary not found
    case binaryNotFound(String)

    /// Failed to spawn Firecracker process
    case processSpawnFailed(String)

    /// VM is in an invalid state for the requested operation
    case invalidState(current: String, expected: String)

    /// Generic API error from Firecracker
    case apiError(String)
}

extension FirecrackerError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .notConnected:
            return "Not connected to Firecracker socket"
        case .vmNotFound(let id):
            return "VM not found: \(id)"
        case .vmAlreadyRunning(let id):
            return "VM is already running: \(id)"
        case .vmNotRunning(let id):
            return "VM is not running: \(id)"
        case .invalidConfiguration(let message):
            return "Invalid configuration: \(message)"
        case .httpError(let statusCode, let message):
            return "HTTP error \(statusCode): \(message)"
        case .connectionFailed(let message):
            return "Connection failed: \(message)"
        case .invalidSocketPath(let path):
            return "Invalid socket path: \(path)"
        case .timeout(let operation):
            return "Timeout during: \(operation)"
        case .serializationError(let message):
            return "Serialization error: \(message)"
        case .deserializationError(let message):
            return "Deserialization error: \(message)"
        case .binaryNotFound(let path):
            return "Firecracker binary not found at: \(path)"
        case .processSpawnFailed(let message):
            return "Failed to spawn Firecracker process: \(message)"
        case .invalidState(let current, let expected):
            return "Invalid VM state: current=\(current), expected=\(expected)"
        case .apiError(let message):
            return "Firecracker API error: \(message)"
        }
    }
}
