import Foundation

/// A volume's stable device identifier within its VM — `disk0`, `disk1`, `vdb`.
///
/// Its own type rather than a bare `String` because the value is not free-form:
/// it leaves the control plane and becomes a hypervisor object id — the
/// Firecracker drive id, and the key the agent logs and reconciles a hot-plug
/// against. QEMU restricts ids to `[A-Za-z0-9._-]`, so an empty string, a
/// space, or a path taken verbatim from a request body used to surface as an
/// unexplained hot-plug rejection, or as a persisted spec that failed the next
/// boot with an opaque hypervisor error and no pointer back to the attach that
/// caused it (STR-129).
///
/// Validating at the boundary means a `VolumeSpec` can only carry a name every
/// supported hypervisor accepts. `Codable` is transparent — a single `String`
/// on the wire, so the JSON is byte-identical to what the field encoded when it
/// was typed as one — but decoding *validates*, which is what makes the
/// guarantee hold for a spec read back from the agent's manifest as well as one
/// built in process.
public struct VolumeDeviceName: Sendable, Hashable, Comparable, Codable, CustomStringConvertible {
    /// Longest accepted name. Both hypervisors tolerate far more; the bound
    /// exists so a request body cannot push an unbounded string into a QMP
    /// command or a Firecracker URL path.
    public static let maxLength = 32

    public let rawValue: String

    /// Fails rather than sanitizing: a silently rewritten name would still be
    /// the identity the caller believes it attached under.
    public init?(_ rawValue: String) {
        guard Self.isValid(rawValue) else { return nil }
        self.rawValue = rawValue
    }

    /// Throwing form, for call sites that want the reason.
    public init(validating rawValue: String) throws {
        guard let name = Self(rawValue) else { throw InvalidVolumeDeviceName(rawValue: rawValue) }
        self = name
    }

    /// The `disk<index>` name for slot `index`, which is the shape the control
    /// plane generates when a caller names no device. Non-failable: `"disk"`
    /// plus the digits of any `Int` is inside `maxLength`.
    public static func disk(_ index: Int) -> VolumeDeviceName {
        VolumeDeviceName(unchecked: "disk\(max(0, index))")
    }

    private init(unchecked rawValue: String) {
        self.rawValue = rawValue
    }

    /// A leading alphanumeric, then QEMU's id charset. The separators are
    /// excluded from the first position so a name can never be read as a flag
    /// or as an empty leading component.
    public static func isValid(_ rawValue: String) -> Bool {
        guard !rawValue.isEmpty, rawValue.count <= maxLength else { return false }
        for (offset, scalar) in rawValue.unicodeScalars.enumerated() {
            let isAlphanumeric =
                (scalar >= "a" && scalar <= "z") || (scalar >= "A" && scalar <= "Z")
                || (scalar >= "0" && scalar <= "9")
            if offset == 0 {
                guard isAlphanumeric else { return false }
            } else {
                guard isAlphanumeric || scalar == "." || scalar == "_" || scalar == "-" else { return false }
            }
        }
        return true
    }

    /// What the API tells a caller who sent something else.
    public static var requirementDescription: String {
        "must start with a letter or digit and contain only letters, digits, '.', '_' or '-' "
            + "(at most \(maxLength) characters)"
    }

    public var description: String { rawValue }

    public static func < (lhs: VolumeDeviceName, rhs: VolumeDeviceName) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        guard let name = Self(rawValue) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid device name '\(rawValue)': \(Self.requirementDescription)")
        }
        self = name
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// Thrown by `VolumeDeviceName(validating:)`; carries the rejected value so the
/// API can echo it back.
public struct InvalidVolumeDeviceName: Error, CustomStringConvertible, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public var description: String {
        "Invalid device name '\(rawValue)': \(VolumeDeviceName.requirementDescription)"
    }
}
