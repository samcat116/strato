import Foundation
import SwiftProtobuf

/// CPU architecture of a hypervisor host or a guest image.
///
/// KVM and HVF acceleration are same-architecture only, so the scheduler must
/// match guest architecture to host architecture; a mismatch would silently
/// degrade to TCG emulation.
public typealias CPUArchitecture = Strato_Agent_V1_CPUArchitecture
extension Strato_Agent_V1_CPUArchitecture: Codable {

    /// The architecture this binary was compiled for (the host architecture,
    /// since agents run natively on their hypervisor node).
    public static var current: CPUArchitecture {
        #if arch(arm64)
        return .arm64
        #elseif arch(x86_64)
        return .x86_64
        #else
        #error("Unsupported CPU architecture: Strato supports x86_64 and arm64 hosts")
        #endif
    }

    /// Human-readable display name
    public var displayName: String {
        switch self {
        case .x8664:
            return "x86_64"
        case .arm64:
            return "ARM64"
        case .unspecified, .UNRECOGNIZED:
            return "Unknown"
        }
    }

    public var protocolValue: String {
        switch self {
        case .x8664: return "x86_64"
        case .arm64: return "arm64"
        case .unspecified, .UNRECOGNIZED: return ""
        }
    }

    public init?(rawValue: String) {
        switch rawValue {
        case "x86_64": self = .x8664
        case "arm64": self = .arm64
        default: return nil
        }
    }

    public static var x86_64: Self { .x8664 }

    public static var knownCases: [Self] { [.x8664, .arm64] }

    public init(from decoder: any Swift.Decoder) throws {
        let container = try decoder.singleValueContainer()
        guard let value = Self(rawValue: try container.decode(String.self)) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unknown enum value")
        }
        self = value
    }

    public func encode(to encoder: any Swift.Encoder) throws {
        guard !protocolValue.isEmpty else {
            throw EncodingError.invalidValue(
                self, .init(codingPath: encoder.codingPath, debugDescription: "Unknown enum value"))
        }
        var container = encoder.singleValueContainer()
        try container.encode(protocolValue)
    }
}
