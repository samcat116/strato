/// Version of the host↔guest sandbox control protocol carried over vsock.
/// This is separate from ``WireProtocol``: checkpoints freeze a guest init in
/// memory, so both the control plane and the agent validate their recorded or
/// advertised guest version before using one.
public enum SandboxGuestControlProtocol {
    /// v1 introduced health/status and v2 added exec/log streaming. v3 adds
    /// explicit version advertisement plus checkpoint-fork re-identification.
    /// v4 adds in-place NIC reconfiguration, which is what lets a restored
    /// guest take the target sandbox's address instead of the source's
    /// (STR-104).
    public static let currentVersion = 4
}
