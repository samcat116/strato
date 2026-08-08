/// Version gates for the host↔guest sandbox control protocol carried over
/// vsock. This is separate from ``WireProtocol``: an upgraded agent can still
/// own a running microVM whose checkpoint contains an older guest init.
public enum SandboxGuestControlProtocol {
    /// v1 introduced health/status and v2 added exec/log streaming. v3 adds
    /// explicit version advertisement plus checkpoint-fork re-identification.
    /// v4 adds in-place NIC reconfiguration, which is what lets a restored
    /// guest take the target sandbox's address instead of the source's
    /// (STR-104).
    public static let currentVersion = 4

    /// The first guest that can rotate a restored checkpoint into a distinct
    /// sandbox identity.
    public static let reidentifyMinimumVersion = 3

    /// The first guest that can re-address its NIC on a `launch`/`reidentify`
    /// request. Only a **networked** snapshot needs it: a network-free guest
    /// has nothing to re-address, so gating every fork on v4 would strand
    /// checkpoints that are perfectly forkable.
    public static let networkReconfigureMinimumVersion = 4

    public static func supportsReidentify(_ version: Int?) -> Bool {
        (version ?? 0) >= reidentifyMinimumVersion
    }

    public static func supportsNetworkReconfigure(_ version: Int?) -> Bool {
        (version ?? 0) >= networkReconfigureMinimumVersion
    }
}
