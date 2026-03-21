import Foundation

// MARK: - QMP Message Types

/// QMP greeting message sent by QEMU when connection is established
public struct QMPGreeting: Codable, Sendable {
    public struct QMP: Codable, Sendable {
        public struct Version: Codable, Sendable {
            public struct QEMU: Codable, Sendable {
                public let micro: Int
                public let minor: Int
                public let major: Int
            }
            public let qemu: QEMU
            public let package: String
        }
        public let version: Version
        public let capabilities: [String]
    }
    public let QMP: QMP
}

/// QMP request structure
public struct QMPRequest: Codable, Sendable {
    public let execute: String
    public let arguments: [String: AnyCodable]?
    public let id: AnyCodable?
    
    public init(execute: String, arguments: [String: AnyCodable]? = nil, id: AnyCodable? = nil) {
        self.execute = execute
        self.arguments = arguments
        self.id = id
    }
}

/// QMP response structure
public struct QMPResponse: Codable, Sendable {
    public let `return`: AnyCodable?
    public let error: QMPErrorResponse?
    public let id: AnyCodable?
}

/// QMP error response
public struct QMPErrorResponse: Codable, Sendable {
    public let `class`: String
    public let desc: String
}

/// QMP event structure
public struct QMPEvent: Codable, Sendable {
    public let event: String
    public let data: AnyCodable?
    public let timestamp: QMPTimestamp
}

/// QMP timestamp
public struct QMPTimestamp: Codable, Sendable {
    public let seconds: Int
    public let microseconds: Int
}

// MARK: - QMP Commands

public enum QMPCommand {
    case capabilities
    case queryStatus
    case cont
    case stop
    case systemPowerdown
    case systemReset
    case quit
    case queryVersion
    case queryMachines
    case queryKVM
    
    public var name: String {
        switch self {
        case .capabilities: return "qmp_capabilities"
        case .queryStatus: return "query-status"
        case .cont: return "cont"
        case .stop: return "stop"
        case .systemPowerdown: return "system_powerdown"
        case .systemReset: return "system_reset"
        case .quit: return "quit"
        case .queryVersion: return "query-version"
        case .queryMachines: return "query-machines"
        case .queryKVM: return "query-kvm"
        }
    }
}

// MARK: - QMP Status Response

public struct QMPStatusResponse: Codable, Sendable {
    public let status: String
    public let singlestep: Bool
    public let running: Bool
}

// MARK: - Type-erased Codable wrapper

public struct AnyCodable: Codable, @unchecked Sendable {
    public let value: Any
    
    public init(_ value: Any) {
        self.value = value
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        
        if container.decodeNil() {
            self.value = NSNull()
        } else if let bool = try? container.decode(Bool.self) {
            self.value = bool
        } else if let int = try? container.decode(Int.self) {
            self.value = int
        } else if let double = try? container.decode(Double.self) {
            self.value = double
        } else if let string = try? container.decode(String.self) {
            self.value = string
        } else if let array = try? container.decode([AnyCodable].self) {
            self.value = array.map { $0.value }
        } else if let dictionary = try? container.decode([String: AnyCodable].self) {
            self.value = dictionary.mapValues { $0.value }
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Could not decode AnyCodable"
            )
        }
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        
        switch value {
        case is NSNull:
            try container.encodeNil()
        case let bool as Bool:
            try container.encode(bool)
        case let int as Int:
            try container.encode(int)
        case let double as Double:
            try container.encode(double)
        case let string as String:
            try container.encode(string)
        case let array as [Any]:
            try container.encode(array.map { AnyCodable($0) })
        case let dictionary as [String: Any]:
            try container.encode(dictionary.mapValues { AnyCodable($0) })
        default:
            throw EncodingError.invalidValue(
                value,
                EncodingError.Context(
                    codingPath: encoder.codingPath,
                    debugDescription: "Could not encode AnyCodable"
                )
            )
        }
    }
}