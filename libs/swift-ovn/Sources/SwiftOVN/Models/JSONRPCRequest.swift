import Foundation

public struct JSONRPCRequest: Codable {
    public let jsonrpc: String
    public let method: String
    public let params: JSONRPCParams?
    public let id: JSONRPCIdentifier?
    
    public init(method: String, params: JSONRPCParams? = nil, id: JSONRPCIdentifier? = nil) {
        self.jsonrpc = "2.0"
        self.method = method
        self.params = params
        self.id = id
    }
}