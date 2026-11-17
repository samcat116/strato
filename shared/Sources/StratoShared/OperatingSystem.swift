import Foundation
import SwiftProtobuf

/// Operating system of a hypervisor host.
///
/// Reported at agent registration (alongside `CPUArchitecture`) so the control
/// plane can resolve the right release artifact for an agent self-update —
/// release tarballs are published per OS/arch pair (`strato-<os>-<arch>.tar.gz`).
/// The raw values match the asset-name components `deploy/agent/install.sh`
/// derives from `uname -s`.
public typealias OperatingSystem = Strato_Agent_V1_OperatingSystem
extension Strato_Agent_V1_OperatingSystem: Codable {

    /// The OS this binary was compiled for (the host OS, since agents run
    /// natively on their hypervisor node).
    public static var current: OperatingSystem {
        #if os(Linux)
        return .linux
        #elseif os(macOS)
        return .macos
        #else
        #error("Unsupported OS: Strato agents support Linux and macOS hosts")
        #endif
    }

    public var protocolValue: String {
        switch self {
        case .linux: return "linux"
        case .macos: return "macos"
        case .unspecified, .UNRECOGNIZED: return ""
        }
    }

    public init?(rawValue: String) {
        switch rawValue {
        case "linux": self = .linux
        case "macos": self = .macos
        default: return nil
        }
    }

    public static var knownCases: [Self] { [.linux, .macos] }

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
