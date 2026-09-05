import StratoAPIClient

/// Maps the readable CLI spelling onto the API's stable wire value.
public func parseVolumeBlockMode(
    _ value: String?
) throws -> Components.Schemas.VolumeBlockMode? {
    guard let value else { return nil }
    let rawValue: String
    switch value.lowercased() {
    case "conservative": rawValue = "conservative"
    case "direct": rawValue = "direct"
    case "cachedshared", "cached-shared": rawValue = "cachedShared"
    default:
        throw CLIError.config(
            "Invalid --block-mode value '\(value)'. Accepted values: conservative, direct, cached-shared.")
    }
    return Components.Schemas.VolumeBlockMode(rawValue: rawValue)
}
