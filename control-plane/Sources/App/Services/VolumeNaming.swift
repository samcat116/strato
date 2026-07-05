import Foundation
import Vapor

/// Pure helpers for volume request parsing and device naming, extracted from
/// `VolumeController` so they can be unit-tested without a database or SpiceDB.
struct VolumeNaming {
    /// Parses the optional format string, defaulting to `.qcow2`.
    static func parseFormat(_ raw: String?) throws -> VolumeFormat {
        guard let raw else { return .qcow2 }
        guard let format = VolumeFormat(rawValue: raw) else {
            throw Abort(.badRequest, reason: "Invalid format '\(raw)'. Must be 'qcow2' or 'raw'")
        }
        return format
    }

    /// Parses the optional volume-type string, defaulting to `.data`.
    static func parseVolumeType(_ raw: String?) throws -> VolumeType {
        guard let raw else { return .data }
        guard let type = VolumeType(rawValue: raw) else {
            throw Abort(.badRequest, reason: "Invalid volume type '\(raw)'. Must be 'boot' or 'data'")
        }
        return type
    }

    /// Computes the next `disk<N>` device name given the device names already in use.
    /// Names that don't match the `disk<number>` shape are ignored; numbering starts
    /// at `disk0`.
    static func nextDeviceName(existingDeviceNames: [String?]) -> String {
        var maxDiskNum = -1
        for name in existingDeviceNames {
            if let deviceName = name,
                deviceName.hasPrefix("disk"),
                let numStr = deviceName.dropFirst(4).description.components(
                    separatedBy: CharacterSet.decimalDigits.inverted
                ).first,
                let num = Int(numStr)
            {
                maxDiskNum = max(maxDiskNum, num)
            }
        }
        return "disk\(maxDiskNum + 1)"
    }
}
