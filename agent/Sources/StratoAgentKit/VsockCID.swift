/// Values reserved by the AF_VSOCK address space and therefore unavailable to
/// guests. Kept below the allocator so domain validation does not depend on
/// manifest persistence.
public enum VsockCID {
    public static let firstAssignable: UInt32 = 3
    public static let lastAssignable: UInt32 = UInt32.max - 1

    public static func isAssignable(_ cid: UInt32) -> Bool {
        cid >= firstAssignable && cid <= lastAssignable
    }
}
