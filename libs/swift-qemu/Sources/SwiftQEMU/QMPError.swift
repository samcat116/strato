import Foundation

/// Errors that can occur when interacting with QEMU
public enum QMPError: Error, LocalizedError {
    case notConnected
    case connectionLost
    case invalidResponse
    case qmpError(String, String)
    case processNotRunning
    case processAlreadyRunning
    case invalidConfiguration
    case socketCreationFailed
    case timeout
    
    public var errorDescription: String? {
        switch self {
        case .notConnected:
            return "Not connected to QEMU"
        case .connectionLost:
            return "Connection to QEMU was lost"
        case .invalidResponse:
            return "Invalid response from QEMU"
        case .qmpError(let errorClass, let description):
            return "QMP error (\(errorClass)): \(description)"
        case .processNotRunning:
            return "QEMU process is not running"
        case .processAlreadyRunning:
            return "QEMU process is already running"
        case .invalidConfiguration:
            return "Invalid QEMU configuration"
        case .socketCreationFailed:
            return "Failed to create QMP socket"
        case .timeout:
            return "Operation timed out"
        }
    }
}