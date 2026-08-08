import Foundation

/// Firecracker capabilities that a snapshot restore depends on, keyed by the
/// VMM's own version string.
///
/// Separate from the agent's `HypervisorProbe`, which only answers "is
/// Firecracker usable here": these are finer-grained facts about what a *load*
/// can be asked to do, and the agent reads them on paths where guessing wrong
/// means an API call Firecracker rejects outright rather than a capability it
/// quietly lacks.
///
/// Shared rather than agent-local because the control plane needs the same
/// answer: an agent's probed Firecracker version rides its registration
/// (`HypervisorSupport.version`), so placement can refuse a fork the target
/// could only fail at, instead of leaving the caller a degraded sandbox.
public enum FirecrackerSnapshotFeatures {
    /// The first Firecracker release whose `PUT /snapshot/load` accepts
    /// `network_overrides` (STR-104).
    ///
    /// Older builds do not ignore the field — they reject the body — so this is
    /// a hard gate rather than a best-effort one: without it, a checkpoint's
    /// network device can only ever be opened under the host TAP name the
    /// snapshot recorded, which is why forking or warm-starting a networked
    /// sandbox needs it and restoring one in place (same sandbox, same
    /// deterministic TAP name) does not.
    public static let networkOverridesMinimumVersion = "1.12.0"

    /// Whether `version` — as reported by `firecracker --version`, normalized
    /// without the cosmetic `v` — can remap a restored network device.
    ///
    /// An unknown or unparseable version is **not** capable. Assuming the
    /// feature and being wrong fails the load; assuming its absence only costs
    /// a fork the ability to run on a host nobody could identify.
    public static func supportsNetworkOverrides(_ version: String?) -> Bool {
        guard let version else { return false }
        return compare(version, networkOverridesMinimumVersion) != .orderedAscending
    }

    /// Numeric dotted-component comparison, ignoring any pre-release/build
    /// suffix on the last component it reads (`1.12.0-dev` compares as
    /// `1.12.0`, which is deliberate: a `-dev` build of 1.12.0 has the field).
    /// A component that is not a number stops the comparison — everything from
    /// there on is treated as equal, so a version string this cannot read
    /// never *gains* capability from garbage.
    static func compare(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let left = numericComponents(lhs)
        let right = numericComponents(rhs)
        for index in 0..<max(left.count, right.count) {
            let a = index < left.count ? left[index] : 0
            let b = index < right.count ? right[index] : 0
            if a != b { return a < b ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }

    private static func numericComponents(_ version: String) -> [Int] {
        var components: [Int] = []
        for part in version.split(separator: ".") {
            let digits = part.prefix { $0.isNumber }
            guard !digits.isEmpty, let value = Int(digits) else { break }
            components.append(value)
            // `1.12.0-dev` keeps 0 and stops; `1.12` simply runs out.
            if digits.count != part.count { break }
        }
        return components
    }
}
