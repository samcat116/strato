import Foundation

// MARK: - Codable Extensions for OVSDB Types

extension Array where Element == String {
    func toJSONValue() -> JSONValue {
        return .array(self.map { .string($0) })
    }
}

extension Array where Element == Int {
    func toJSONValue() -> JSONValue {
        return .array(self.map { .number(Double($0)) })
    }
}

extension Dictionary where Key == String, Value == String {
    func toJSONValue() -> JSONValue {
        let mapped = self.mapValues { JSONValue.string($0) }
        return .object(mapped)
    }
}

extension Dictionary where Key == String, Value == Int {
    func toJSONValue() -> JSONValue {
        let mapped = self.mapValues { JSONValue.number(Double($0)) }
        return .object(mapped)
    }
}

extension Dictionary where Key == Int, Value == String {
    func toJSONValue() -> JSONValue {
        let mapped = Dictionary<String, JSONValue>(
            uniqueKeysWithValues: self.map { (String($0.key), JSONValue.string($0.value)) }
        )
        return .object(mapped)
    }
}

// MARK: - JSON Value Extraction Helpers

extension JSONValue {
    var stringValue: String? {
        if case .string(let value) = self {
            return value
        }
        return nil
    }
    
    var numberValue: Double? {
        if case .number(let value) = self {
            return value
        }
        return nil
    }
    
    var intValue: Int? {
        if case .number(let value) = self {
            return Int(value)
        }
        return nil
    }
    
    var boolValue: Bool? {
        if case .boolean(let value) = self {
            return value
        }
        return nil
    }
    
    var arrayValue: [JSONValue]? {
        if case .array(let value) = self {
            return value
        }
        return nil
    }
    
    var objectValue: [String: JSONValue]? {
        if case .object(let value) = self {
            return value
        }
        return nil
    }
    
    var isNull: Bool {
        if case .null = self {
            return true
        }
        return false
    }
    
    func asStringArray() -> [String]? {
        guard let array = arrayValue else { return nil }
        return array.compactMap { $0.stringValue }
    }
    
    func asIntArray() -> [Int]? {
        guard let array = arrayValue else { return nil }
        return array.compactMap { $0.intValue }
    }
    
    func asStringDictionary() -> [String: String]? {
        guard let object = objectValue else { return nil }
        var result: [String: String] = [:]
        for (key, value) in object {
            if let stringValue = value.stringValue {
                result[key] = stringValue
            }
        }
        return result.isEmpty ? nil : result
    }
    
    func asIntDictionary() -> [String: Int]? {
        guard let object = objectValue else { return nil }
        var result: [String: Int] = [:]
        for (key, value) in object {
            if let intValue = value.intValue {
                result[key] = intValue
            }
        }
        return result.isEmpty ? nil : result
    }
}

// MARK: - UUID Handling

extension JSONValue {
    static func uuid(_ uuidString: String) -> JSONValue {
        return .array([.string("uuid"), .string(uuidString)])
    }
    
    var uuidValue: String? {
        if case .array(let array) = self,
           array.count == 2,
           case .string("uuid") = array[0],
           case .string(let uuid) = array[1] {
            return uuid
        }
        return nil
    }
}

// MARK: - OVSDB Set Handling

extension JSONValue {
    static func set<T>(_ values: [T]) -> JSONValue where T: Equatable {
        if values.isEmpty {
            return .array([.string("set"), .array([])])
        } else if values.count == 1 {
            // Single value sets are represented as just the value
            if let stringValue = values.first as? String {
                return .string(stringValue)
            } else if let intValue = values.first as? Int {
                return .number(Double(intValue))
            } else if let doubleValue = values.first as? Double {
                return .number(doubleValue)
            }
        }
        
        // Multiple values as a set
        var jsonArray: [JSONValue] = []
        for value in values {
            if let stringValue = value as? String {
                jsonArray.append(.string(stringValue))
            } else if let intValue = value as? Int {
                jsonArray.append(.number(Double(intValue)))
            } else if let doubleValue = value as? Double {
                jsonArray.append(.number(doubleValue))
            }
        }
        
        return .array([.string("set"), .array(jsonArray)])
    }
    
    var setValue: [JSONValue]? {
        // Handle single value (not wrapped in set)
        if case .string(_) = self, case .number(_) = self, case .boolean(_) = self {
            return [self]
        }
        
        // Handle set array format
        if case .array(let array) = self,
           array.count == 2,
           case .string("set") = array[0],
           case .array(let values) = array[1] {
            return values
        }
        
        return nil
    }
    
    var setStringValues: [String]? {
        return setValue?.compactMap { $0.stringValue }
    }
    
    var setIntValues: [Int]? {
        return setValue?.compactMap { $0.intValue }
    }
}

// MARK: - OVSDB Map Handling

extension JSONValue {
    static func map<K, V>(_ dictionary: [K: V]) -> JSONValue where K: Hashable {
        if dictionary.isEmpty {
            return .array([.string("map"), .array([])])
        }
        
        var pairs: [JSONValue] = []
        for (key, value) in dictionary {
            var keyValue: JSONValue
            var valueValue: JSONValue
            
            if let stringKey = key as? String {
                keyValue = .string(stringKey)
            } else if let intKey = key as? Int {
                keyValue = .number(Double(intKey))
            } else {
                continue
            }
            
            if let stringValue = value as? String {
                valueValue = .string(stringValue)
            } else if let intValue = value as? Int {
                valueValue = .number(Double(intValue))
            } else if let doubleValue = value as? Double {
                valueValue = .number(doubleValue)
            } else {
                continue
            }
            
            pairs.append(.array([keyValue, valueValue]))
        }
        
        return .array([.string("map"), .array(pairs)])
    }
    
    var mapValue: [(JSONValue, JSONValue)]? {
        if case .array(let array) = self,
           array.count == 2,
           case .string("map") = array[0],
           case .array(let pairs) = array[1] {
            
            return pairs.compactMap { pair in
                if case .array(let pairArray) = pair,
                   pairArray.count == 2 {
                    return (pairArray[0], pairArray[1])
                }
                return nil
            }
        }
        
        return nil
    }
    
    var mapStringValues: [String: String]? {
        guard let pairs = mapValue else { return nil }
        
        var result: [String: String] = [:]
        for (key, value) in pairs {
            if let keyString = key.stringValue,
               let valueString = value.stringValue {
                result[keyString] = valueString
            }
        }
        
        return result.isEmpty ? nil : result
    }
    
    var mapIntValues: [String: Int]? {
        guard let pairs = mapValue else { return nil }
        
        var result: [String: Int] = [:]
        for (key, value) in pairs {
            if let keyString = key.stringValue,
               let valueInt = value.intValue {
                result[keyString] = valueInt
            }
        }
        
        return result.isEmpty ? nil : result
    }
}

// MARK: - Convenience Initializers

extension OVSDBCondition {
    static func equal(column: String, to value: String) -> OVSDBCondition {
        return OVSDBCondition(column: column, function: "==", value: .string(value))
    }
    
    static func equal(column: String, to value: Int) -> OVSDBCondition {
        return OVSDBCondition(column: column, function: "==", value: .number(Double(value)))
    }
    
    static func equal(column: String, to value: Bool) -> OVSDBCondition {
        return OVSDBCondition(column: column, function: "==", value: .boolean(value))
    }
    
    static func notEqual(column: String, to value: String) -> OVSDBCondition {
        return OVSDBCondition(column: column, function: "!=", value: .string(value))
    }
    
    static func includes(column: String, value: String) -> OVSDBCondition {
        return OVSDBCondition(column: column, function: "includes", value: .string(value))
    }
    
    static func excludes(column: String, value: String) -> OVSDBCondition {
        return OVSDBCondition(column: column, function: "excludes", value: .string(value))
    }
}

extension OVSDBMutation {
    static func insert(column: String, value: String) -> OVSDBMutation {
        return OVSDBMutation(column: column, mutator: "insert", value: .string(value))
    }
    
    static func delete(column: String, value: String) -> OVSDBMutation {
        return OVSDBMutation(column: column, mutator: "delete", value: .string(value))
    }
    
    static func add(column: String, value: Int) -> OVSDBMutation {
        return OVSDBMutation(column: column, mutator: "+=", value: .number(Double(value)))
    }
    
    static func subtract(column: String, value: Int) -> OVSDBMutation {
        return OVSDBMutation(column: column, mutator: "-=", value: .number(Double(value)))
    }
    
    static func multiply(column: String, value: Int) -> OVSDBMutation {
        return OVSDBMutation(column: column, mutator: "*=", value: .number(Double(value)))
    }
    
    static func divide(column: String, value: Int) -> OVSDBMutation {
        return OVSDBMutation(column: column, mutator: "/=", value: .number(Double(value)))
    }
    
    static func modulo(column: String, value: Int) -> OVSDBMutation {
        return OVSDBMutation(column: column, mutator: "%=", value: .number(Double(value)))
    }
}