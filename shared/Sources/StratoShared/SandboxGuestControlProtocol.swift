/// Version gates for the host↔guest sandbox control protocol carried over
/// vsock. This is separate from ``WireProtocol``: an upgraded agent can still
/// own a running microVM whose checkpoint contains an older guest init.
public enum SandboxGuestControlProtocol {
    /// v1 introduced health/status and v2 added exec/log streaming. v3 adds
    /// explicit version advertisement plus checkpoint-fork re-identification.
    public static let currentVersion = 3

    /// The first guest that can rotate a restored checkpoint into a distinct
    /// sandbox identity.
    public static let reidentifyMinimumVersion = 3

    public static func supportsReidentify(_ version: Int?) -> Bool {
        (version ?? 0) >= reidentifyMinimumVersion
    }
}
