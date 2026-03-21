import Foundation

public struct OVSDBCondition: Codable {
    public let column: String
    public let function: String
    public let value: JSONValue
    
    public init(column: String, function: String, value: JSONValue) {
        self.column = column
        self.function = function
        self.value = value
    }
}