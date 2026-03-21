import Foundation

/// SCIM filter expression
public struct SCIMFilter: Sendable {
    public let expression: String
    
    public init(_ expression: String) {
        self.expression = expression
    }
}

/// SCIM filter operators
public enum SCIMFilterOperator: String, CaseIterable, Sendable {
    case equal = "eq"
    case notEqual = "ne"
    case contains = "co"
    case startsWith = "sw"
    case endsWith = "ew"
    case present = "pr"
    case greaterThan = "gt"
    case greaterThanOrEqual = "ge"
    case lessThan = "lt"
    case lessThanOrEqual = "le"
}

/// SCIM logical operators
public enum SCIMLogicalOperator: String, Sendable {
    case and
    case or
    case not
}

/// Result builder for constructing SCIM filters
@resultBuilder
public struct SCIMFilterBuilder {
    public static func buildBlock(_ components: SCIMFilterExpression...) -> SCIMFilterExpression {
        switch components.count {
        case 0:
            return SCIMFilterExpression.empty
        case 1:
            return components[0]
        default:
            return components.dropFirst().reduce(components[0]) { result, expression in
                SCIMFilterExpression.logical(.and, result, expression)
            }
        }
    }
    
    public static func buildOptional(_ component: SCIMFilterExpression?) -> SCIMFilterExpression {
        component ?? .empty
    }
    
    public static func buildEither(first component: SCIMFilterExpression) -> SCIMFilterExpression {
        component
    }
    
    public static func buildEither(second component: SCIMFilterExpression) -> SCIMFilterExpression {
        component
    }
    
    public static func buildArray(_ components: [SCIMFilterExpression]) -> SCIMFilterExpression {
        guard !components.isEmpty else { return .empty }
        return components.dropFirst().reduce(components[0]) { result, expression in
            SCIMFilterExpression.logical(.and, result, expression)
        }
    }
}

/// SCIM filter expression
public indirect enum SCIMFilterExpression: Sendable {
    case empty
    case attribute(String, SCIMFilterOperator, String)
    case present(String)
    case logical(SCIMLogicalOperator, SCIMFilterExpression, SCIMFilterExpression)
    case not(SCIMFilterExpression)
    case group(SCIMFilterExpression)
    
    public var stringValue: String {
        switch self {
        case .empty:
            return ""
        case .attribute(let attribute, let op, let value):
            return "\(attribute) \(op.rawValue) \"\(value)\""
        case .present(let attribute):
            return "\(attribute) pr"
        case .logical(let op, let left, let right):
            let leftStr = left.stringValue
            let rightStr = right.stringValue
            guard !leftStr.isEmpty && !rightStr.isEmpty else {
                return leftStr.isEmpty ? rightStr : leftStr
            }
            return "(\(leftStr) \(op.rawValue) \(rightStr))"
        case .not(let expression):
            return "not (\(expression.stringValue))"
        case .group(let expression):
            return "(\(expression.stringValue))"
        }
    }
}

/// DSL for building SCIM filters
public struct SCIMFilterDSL {
    public static func filter(@SCIMFilterBuilder _ content: () -> SCIMFilterExpression) -> SCIMFilter {
        SCIMFilter(content().stringValue)
    }
    
    /// Attribute equals value
    public static func eq(_ attribute: String, _ value: String) -> SCIMFilterExpression {
        .attribute(attribute, .equal, value)
    }
    
    /// Attribute not equals value
    public static func ne(_ attribute: String, _ value: String) -> SCIMFilterExpression {
        .attribute(attribute, .notEqual, value)
    }
    
    /// Attribute contains value
    public static func co(_ attribute: String, _ value: String) -> SCIMFilterExpression {
        .attribute(attribute, .contains, value)
    }
    
    /// Attribute starts with value
    public static func sw(_ attribute: String, _ value: String) -> SCIMFilterExpression {
        .attribute(attribute, .startsWith, value)
    }
    
    /// Attribute ends with value
    public static func ew(_ attribute: String, _ value: String) -> SCIMFilterExpression {
        .attribute(attribute, .endsWith, value)
    }
    
    /// Attribute is present
    public static func pr(_ attribute: String) -> SCIMFilterExpression {
        .present(attribute)
    }
    
    /// Attribute greater than value
    public static func gt(_ attribute: String, _ value: String) -> SCIMFilterExpression {
        .attribute(attribute, .greaterThan, value)
    }
    
    /// Attribute greater than or equal to value
    public static func ge(_ attribute: String, _ value: String) -> SCIMFilterExpression {
        .attribute(attribute, .greaterThanOrEqual, value)
    }
    
    /// Attribute less than value
    public static func lt(_ attribute: String, _ value: String) -> SCIMFilterExpression {
        .attribute(attribute, .lessThan, value)
    }
    
    /// Attribute less than or equal to value
    public static func le(_ attribute: String, _ value: String) -> SCIMFilterExpression {
        .attribute(attribute, .lessThanOrEqual, value)
    }
    
    /// Logical AND
    public static func and(_ left: SCIMFilterExpression, _ right: SCIMFilterExpression) -> SCIMFilterExpression {
        .logical(.and, left, right)
    }
    
    /// Logical OR
    public static func or(_ left: SCIMFilterExpression, _ right: SCIMFilterExpression) -> SCIMFilterExpression {
        .logical(.or, left, right)
    }
    
    /// Logical NOT
    public static func not(_ expression: SCIMFilterExpression) -> SCIMFilterExpression {
        .not(expression)
    }
    
    /// Group expression
    public static func group(_ expression: SCIMFilterExpression) -> SCIMFilterExpression {
        .group(expression)
    }
}

/// Query parameters for SCIM requests
public struct SCIMQueryParameters: Sendable {
    public let filter: SCIMFilter?
    public let attributes: [String]?
    public let excludedAttributes: [String]?
    public let sortBy: String?
    public let sortOrder: SortOrder?
    public let startIndex: Int?
    public let count: Int?
    
    public enum SortOrder: String, Sendable {
        case ascending
        case descending
    }
    
    public init(
        filter: SCIMFilter? = nil,
        attributes: [String]? = nil,
        excludedAttributes: [String]? = nil,
        sortBy: String? = nil,
        sortOrder: SortOrder? = nil,
        startIndex: Int? = nil,
        count: Int? = nil
    ) {
        self.filter = filter
        self.attributes = attributes
        self.excludedAttributes = excludedAttributes
        self.sortBy = sortBy
        self.sortOrder = sortOrder
        self.startIndex = startIndex
        self.count = count
    }
    
    /// Convert to URL query items
    public var queryItems: [URLQueryItem] {
        var items: [URLQueryItem] = []
        
        if let filter = filter {
            items.append(URLQueryItem(name: "filter", value: filter.expression))
        }
        
        if let attributes = attributes {
            items.append(URLQueryItem(name: "attributes", value: attributes.joined(separator: ",")))
        }
        
        if let excludedAttributes = excludedAttributes {
            items.append(URLQueryItem(name: "excludedAttributes", value: excludedAttributes.joined(separator: ",")))
        }
        
        if let sortBy = sortBy {
            items.append(URLQueryItem(name: "sortBy", value: sortBy))
        }
        
        if let sortOrder = sortOrder {
            items.append(URLQueryItem(name: "sortOrder", value: sortOrder.rawValue))
        }
        
        if let startIndex = startIndex {
            items.append(URLQueryItem(name: "startIndex", value: String(startIndex)))
        }
        
        if let count = count {
            items.append(URLQueryItem(name: "count", value: String(count)))
        }
        
        return items
    }
}