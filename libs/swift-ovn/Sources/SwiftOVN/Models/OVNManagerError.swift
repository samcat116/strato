import Foundation

public enum OVNManagerError: Error {
    case connectionFailed(String)
    case invalidResponse(String)
    case timeoutError
    case encodingError(Error)
    case decodingError(Error)
    case rpcError(JSONRPCError)
    case invalidSocket(String)
    case operationFailed(String)
}