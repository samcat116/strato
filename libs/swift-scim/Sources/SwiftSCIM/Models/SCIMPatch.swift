import Foundation

/// SCIM PATCH request
public struct SCIMPatchRequest: Codable, Sendable {
    public let schemas: [String]
    public let Operations: [SCIMPatchOperation]
    
    public init(operations: [SCIMPatchOperation]) {
        self.schemas = ["urn:ietf:params:scim:api:messages:2.0:PatchOp"]
        self.Operations = operations
    }
}

/// SCIM PATCH operation
public struct SCIMPatchOperation: Codable, Sendable {
    public let op: SCIMPatchOperationType
    public let path: String?
    public let value: SCIMPatchValue?
    
    public init(
        op: SCIMPatchOperationType,
        path: String? = nil,
        value: SCIMPatchValue? = nil
    ) {
        self.op = op
        self.path = path
        self.value = value
    }
}

/// SCIM PATCH operation types
public enum SCIMPatchOperationType: String, Codable, Sendable {
    case add
    case remove
    case replace
}

/// SCIM PATCH value - can be any JSON value
public enum SCIMPatchValue: Codable, Sendable {
    case string(String)
    case number(Double)
    case boolean(Bool)
    case array([SCIMPatchValue])
    case object([String: SCIMPatchValue])
    case null
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        
        if container.decodeNil() {
            self = .null
        } else if let bool = try? container.decode(Bool.self) {
            self = .boolean(bool)
        } else if let number = try? container.decode(Double.self) {
            self = .number(number)
        } else if let string = try? container.decode(String.self) {
            self = .string(string)
        } else if let array = try? container.decode([SCIMPatchValue].self) {
            self = .array(array)
        } else if let object = try? container.decode([String: SCIMPatchValue].self) {
            self = .object(object)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Cannot decode SCIM patch value"
            )
        }
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        
        switch self {
        case .null:
            try container.encodeNil()
        case .boolean(let bool):
            try container.encode(bool)
        case .number(let number):
            try container.encode(number)
        case .string(let string):
            try container.encode(string)
        case .array(let array):
            try container.encode(array)
        case .object(let object):
            try container.encode(object)
        }
    }
}

// MARK: - Convenience initializers for common patch operations
extension SCIMPatchOperation {
    
    /// Create an add operation
    public static func add(path: String? = nil, value: SCIMPatchValue) -> SCIMPatchOperation {
        SCIMPatchOperation(op: .add, path: path, value: value)
    }
    
    /// Create a remove operation
    public static func remove(path: String) -> SCIMPatchOperation {
        SCIMPatchOperation(op: .remove, path: path, value: nil)
    }
    
    /// Create a replace operation
    public static func replace(path: String? = nil, value: SCIMPatchValue) -> SCIMPatchOperation {
        SCIMPatchOperation(op: .replace, path: path, value: value)
    }
    
    /// Replace a string value
    public static func replace(path: String, stringValue: String) -> SCIMPatchOperation {
        SCIMPatchOperation(op: .replace, path: path, value: .string(stringValue))
    }
    
    /// Replace a boolean value
    public static func replace(path: String, boolValue: Bool) -> SCIMPatchOperation {
        SCIMPatchOperation(op: .replace, path: path, value: .boolean(boolValue))
    }
    
    /// Replace a number value
    public static func replace(path: String, numberValue: Double) -> SCIMPatchOperation {
        SCIMPatchOperation(op: .replace, path: path, value: .number(numberValue))
    }
    
    /// Add a string value
    public static func add(path: String, stringValue: String) -> SCIMPatchOperation {
        SCIMPatchOperation(op: .add, path: path, value: .string(stringValue))
    }
    
    /// Add a boolean value
    public static func add(path: String, boolValue: Bool) -> SCIMPatchOperation {
        SCIMPatchOperation(op: .add, path: path, value: .boolean(boolValue))
    }
    
    /// Add a number value
    public static func add(path: String, numberValue: Double) -> SCIMPatchOperation {
        SCIMPatchOperation(op: .add, path: path, value: .number(numberValue))
    }
}

// MARK: - Convenience initializers for SCIMPatchRequest
extension SCIMPatchRequest {
    
    /// Create a patch request with a single operation
    public init(operation: SCIMPatchOperation) {
        self.init(operations: [operation])
    }
    
    /// Create a patch request to replace user active status
    public static func setUserActive(_ active: Bool) -> SCIMPatchRequest {
        SCIMPatchRequest(operation: .replace(path: "active", boolValue: active))
    }
    
    /// Create a patch request to replace user display name
    public static func setUserDisplayName(_ displayName: String) -> SCIMPatchRequest {
        SCIMPatchRequest(operation: .replace(path: "displayName", stringValue: displayName))
    }
    
    /// Create a patch request to replace user email
    public static func setUserEmail(_ email: String) -> SCIMPatchRequest {
        let emailValue = SCIMPatchValue.array([
            .object([
                "value": .string(email),
                "primary": .boolean(true)
            ])
        ])
        return SCIMPatchRequest(operation: .replace(path: "emails", value: emailValue))
    }
}