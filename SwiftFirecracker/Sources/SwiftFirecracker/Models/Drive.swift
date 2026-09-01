import Foundation

/// Block device (drive) configuration
/// Maps to PUT /drives/{drive_id} API endpoint
public struct Drive: Codable, Sendable {
    let driveId: String

    /// Path to the disk image file (raw or qcow2 via vhost-user-blk)
    let pathOnHost: String

    let isReadOnly: Bool

    let isRootDevice: Bool

    enum CodingKeys: String, CodingKey {
        case driveId = "drive_id"
        case pathOnHost = "path_on_host"
        case isReadOnly = "is_read_only"
        case isRootDevice = "is_root_device"
    }

    private init(
        driveId: String,
        pathOnHost: String,
        isReadOnly: Bool = false,
        isRootDevice: Bool = false
    ) {
        self.driveId = driveId
        self.pathOnHost = pathOnHost
        self.isReadOnly = isReadOnly
        self.isRootDevice = isRootDevice
    }

    public static func rootDrive(
        id: String = "rootfs",
        path: String,
        readOnly: Bool = false
    ) -> Drive {
        Drive(
            driveId: id,
            pathOnHost: path,
            isReadOnly: readOnly,
            isRootDevice: true
        )
    }

    public static func dataDrive(
        id: String,
        path: String,
        readOnly: Bool = false
    ) -> Drive {
        Drive(
            driveId: id,
            pathOnHost: path,
            isReadOnly: readOnly,
            isRootDevice: false
        )
    }
}
