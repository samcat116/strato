import Foundation

/// Errors that can occur when interacting with Firecracker
public enum FirecrackerError: Error, Sendable {
    case notConnected

    case vmNotFound(String)

    case vmAlreadyRunning(String)

    case vmTeardownInProgress(String)

    case httpError(statusCode: Int, message: String)

    case connectionFailed(String)

    case invalidSocketPath(String)

    case timeout(String)

    case serializationError(String)

    case deserializationError(String)

    case binaryNotFound(String)

    case processSpawnFailed(String)

    case processInspectionFailed(String)

    case processSignalFailed(String)

    case processExitUnconfirmed(String)

    case invalidState(current: String, expected: String)

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
        case .vmTeardownInProgress(let id):
            return "VM teardown is already in progress: \(id)"
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
            return "Firecracker binary not found or not executable at: \(path)"
        case .processSpawnFailed(let message):
            return "Failed to spawn Firecracker process: \(message)"
        case .processInspectionFailed(let message):
            return "Failed to inspect Firecracker processes: \(message)"
        case .processSignalFailed(let message):
            return "Failed to signal Firecracker process: \(message)"
        case .processExitUnconfirmed(let message):
            return "Could not confirm Firecracker process exit: \(message)"
        case .invalidState(let current, let expected):
            return "Invalid VM state: current=\(current), expected=\(expected)"
        }
    }
}
