import Foundation

public struct OVSDBMutation: Codable {
    public let column: String
    public let mutator: String
    public let value: JSONValue
    
    public init(column: String, mutator: String, value: JSONValue) {
        self.column = column
        self.mutator = mutator
        self.value = value
    }
}