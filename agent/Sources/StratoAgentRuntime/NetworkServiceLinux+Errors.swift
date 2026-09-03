import Foundation
import Logging
import StratoShared
import StratoAgentCore

#if os(Linux)
import SwiftOVN
#endif

// MARK: - Network Error Types

enum NetworkError: Error, LocalizedError, Sendable {
    case notConnected(String)
    case invalidConfiguration(String)
    case ovnError(String)
    case ovsError(String)
    case tapError(String)

    var errorDescription: String? {
        switch self {
        case .notConnected(let message):
            return "Network service not connected: \(message)"
        case .invalidConfiguration(let message):
            return "Invalid network configuration: \(message)"
        case .ovnError(let message):
            return "OVN error: \(message)"
        case .ovsError(let message):
            return "OVS error: \(message)"
        case .tapError(let message):
            return "TAP interface error: \(message)"
        }
    }
}

extension NetworkError: ClassifiableError {
    var failureClassification: FailureClassification {
        switch self {
        case .invalidConfiguration:
            return .permanent
        case .tapError(let message):
            // A privilege repair does not mint a new workload generation, so
            // retain the reported reason and re-drive after the operator acts.
            // A plain command failure might be a transient device/OVS hiccup.
            let isPrivilegeProblem =
                message.contains("Operation not permitted") || message.contains("Permission denied")
            return isPrivilegeProblem ? .blocked : .transient
        case .notConnected, .ovnError, .ovsError:
            // OVN/OVS may come back (the agent reconnects in the background),
            // so these stay retryable.
            return .transient
        }
    }
}
