import Vapor

enum NetworkRuleValidation {
    private static let allowedProtocols: Set<String> = ["tcp", "udp", "icmp"]

    static func validate(protocolName: String?, portRangeMin: Int?, portRangeMax: Int?) throws -> String? {
        let normalizedProtocol: String?
        if let requested = protocolName {
            let normalized = requested.lowercased()
            guard allowedProtocols.contains(normalized) else {
                throw Abort(
                    .badRequest,
                    reason: "Unsupported protocol '\(requested)': expected tcp, udp, or icmp")
            }
            normalizedProtocol = normalized
        } else {
            normalizedProtocol = nil
        }

        switch normalizedProtocol {
        case "tcp", "udp":
            if let min = portRangeMin, let max = portRangeMax {
                guard (0...65_535).contains(min), (0...65_535).contains(max), min <= max else {
                    throw Abort(.badRequest, reason: "Port range must satisfy 0 ≤ min ≤ max ≤ 65535")
                }
            } else if portRangeMin != nil || portRangeMax != nil {
                throw Abort(.badRequest, reason: "Port ranges need both portRangeMin and portRangeMax")
            }
        case "icmp":
            if let type = portRangeMin {
                guard (0...255).contains(type) else {
                    throw Abort(.badRequest, reason: "ICMP type must be 0–255")
                }
                if let code = portRangeMax {
                    guard (0...255).contains(code) else {
                        throw Abort(.badRequest, reason: "ICMP code must be 0–255")
                    }
                }
            } else if portRangeMax != nil {
                throw Abort(.badRequest, reason: "An ICMP code (portRangeMax) needs a type (portRangeMin)")
            }
        default:
            if portRangeMin != nil || portRangeMax != nil {
                throw Abort(.badRequest, reason: "Port ranges require a protocol of tcp, udp, or icmp")
            }
        }

        return normalizedProtocol
    }
}
