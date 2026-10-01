import Crypto
import Foundation

/// Credential primitives shared without changing each credential's public format.
enum SecureToken {
    enum Encoding {
        case alphanumeric
        case urlSafe
    }

    static func generate(length: Int? = nil, encoding: Encoding = .alphanumeric) -> String {
        let bytes = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        return encode(bytes, length: length, encoding: encoding)
    }

    static func encode(_ bytes: Data, length: Int? = nil, encoding: Encoding = .alphanumeric) -> String {
        let base64 = bytes.base64EncodedString()
        let value: String
        switch encoding {
        case .alphanumeric:
            value = base64.replacingOccurrences(of: "+", with: "")
                .replacingOccurrences(of: "/", with: "")
                .replacingOccurrences(of: "=", with: "")
        case .urlSafe:
            value = base64.replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        return length.map { String(value.prefix($0)) } ?? value
    }

    static func sha256Hex(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
