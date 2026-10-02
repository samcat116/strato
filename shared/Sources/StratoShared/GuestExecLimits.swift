/// Admission defaults shared by the API and the authoritative node-agent gate.
public enum GuestExecLimits {
    public static let maxSessionsPerVM = 4
    public static let runsPerProjectPerMinute = 60
    public static let idleTimeoutSeconds = 900
}
