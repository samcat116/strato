import Foundation

/// Security Event Token (SET) - A JWT that contains security event information
public struct SecurityEventToken: Codable, Sendable {
    /// JWT header
    public let header: JWTHeader
    
    /// JWT payload containing the security event
    public let payload: SecurityEventPayload
    
    /// Raw JWT token string
    public let rawToken: String
    
    public init(header: JWTHeader, payload: SecurityEventPayload, rawToken: String) {
        self.header = header
        self.payload = payload
        self.rawToken = rawToken
    }
}

/// JWT Header for Security Event Tokens
public struct JWTHeader: Codable, Sendable {
    /// Algorithm used for signing
    public let alg: String
    
    /// Token type (always "JWT")
    public let typ: String
    
    /// Key ID used for signing
    public let kid: String?
    
    public init(alg: String, typ: String = "JWT", kid: String? = nil) {
        self.alg = alg
        self.typ = typ
        self.kid = kid
    }
}

/// Security Event Token payload
public struct SecurityEventPayload: Codable, Sendable {
    /// Issuer - who created this token
    public let iss: URL
    
    /// JWT ID - unique identifier for this token
    public let jti: String
    
    /// Issued at timestamp
    public let iat: Int64
    
    /// Audience - who this token is intended for
    public let aud: [String]?
    
    /// Subject identifier
    public let sub_id: SubjectIdentifier?
    
    /// The security events contained in this token
    public let events: [String: [String: AnyCodable]]
    
    /// Time when the event occurred
    public let toe: Int64?
    
    /// Transaction identifier
    public let txn: String?
    
    public init(
        iss: URL,
        jti: String,
        iat: Int64,
        aud: [String]? = nil,
        sub_id: SubjectIdentifier? = nil,
        events: [String: [String: AnyCodable]],
        toe: Int64? = nil,
        txn: String? = nil
    ) {
        self.iss = iss
        self.jti = jti
        self.iat = iat
        self.aud = aud
        self.sub_id = sub_id
        self.events = events
        self.toe = toe
        self.txn = txn
    }
}

/// Subject identifier used in security events
public enum SubjectIdentifier: Codable, Sendable {
    case simple(String)
    case complex(ComplexSubjectIdentifier)
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        
        if let stringValue = try? container.decode(String.self) {
            self = .simple(stringValue)
        } else {
            let complexValue = try container.decode(ComplexSubjectIdentifier.self)
            self = .complex(complexValue)
        }
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        
        switch self {
        case .simple(let value):
            try container.encode(value)
        case .complex(let value):
            try container.encode(value)
        }
    }
}

/// Complex subject identifier for more detailed subject information
public struct ComplexSubjectIdentifier: Codable, Sendable {
    /// Subject format (e.g., "email", "phone_number", "iss_sub")
    public let format: String
    
    /// Subject value
    public let value: String
    
    /// Additional subject claims
    public let additionalClaims: [String: AnyCodable]?
    
    private enum CodingKeys: String, CodingKey {
        case format, value
    }
    
    public init(format: String, value: String, additionalClaims: [String: AnyCodable]? = nil) {
        self.format = format
        self.value = value
        self.additionalClaims = additionalClaims
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        
        guard let formatKey = AnyCodingKey(stringValue: "format"),
              let valueKey = AnyCodingKey(stringValue: "value") else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Failed to create coding keys"))
        }
        
        self.format = try container.decode(String.self, forKey: formatKey)
        self.value = try container.decode(String.self, forKey: valueKey)
        
        // Decode any additional claims
        var additionalClaims: [String: AnyCodable] = [:]
        
        for key in container.allKeys {
            if key.stringValue != "format" && key.stringValue != "value" {
                additionalClaims[key.stringValue] = try container.decode(AnyCodable.self, forKey: key)
            }
        }
        
        self.additionalClaims = additionalClaims.isEmpty ? nil : additionalClaims
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: AnyCodingKey.self)
        try container.encode(format, forKey: AnyCodingKey(stringValue: "format")!)
        try container.encode(value, forKey: AnyCodingKey(stringValue: "value")!)
        
        // Encode additional claims
        if let additionalClaims = additionalClaims {
            for (key, value) in additionalClaims {
                try container.encode(value, forKey: AnyCodingKey(stringValue: key)!)
            }
        }
    }
}

/// A type-erased codable value
public struct AnyCodable: Codable {
    public let value: Any
    
    public init<T: Codable>(_ value: T) {
        self.value = value
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        
        if let bool = try? container.decode(Bool.self) {
            value = bool
        } else if let int = try? container.decode(Int.self) {
            value = int
        } else if let double = try? container.decode(Double.self) {
            value = double
        } else if let string = try? container.decode(String.self) {
            value = string
        } else if let array = try? container.decode([AnyCodable].self) {
            value = array
        } else if let dictionary = try? container.decode([String: AnyCodable].self) {
            value = dictionary
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported type")
        }
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        
        if let bool = value as? Bool {
            try container.encode(bool)
        } else if let int = value as? Int {
            try container.encode(int)
        } else if let double = value as? Double {
            try container.encode(double)
        } else if let string = value as? String {
            try container.encode(string)
        } else if let array = value as? [AnyCodable] {
            try container.encode(array)
        } else if let dictionary = value as? [String: AnyCodable] {
            try container.encode(dictionary)
        } else {
            throw EncodingError.invalidValue(value, EncodingError.Context(codingPath: container.codingPath, debugDescription: "Unsupported type"))
        }
    }
}

/// A coding key that can be created from any string
public struct AnyCodingKey: CodingKey, Sendable {
    public let stringValue: String
    public let intValue: Int?
    
    public init?(stringValue: String) {
        self.stringValue = stringValue
        self.intValue = nil
    }
    
    public init?(intValue: Int) {
        self.stringValue = String(intValue)
        self.intValue = intValue
    }
}