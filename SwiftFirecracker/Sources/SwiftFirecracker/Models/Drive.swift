import Foundation

/// Block device (drive) configuration
/// Maps to PUT /drives/{drive_id} API endpoint
public struct Drive: Codable, Sendable {
    /// Unique identifier for the drive
    public let driveId: String

    /// Path to the disk image file (raw or qcow2 via vhost-user-blk)
    public let pathOnHost: String

    /// Whether the drive is read-only
    public let isReadOnly: Bool

    /// Whether this is the root device
    public let isRootDevice: Bool

    /// Path to a partuuid (optional, for root device identification)
    public let partuuid: String?

    /// Rate limiter configuration for bandwidth
    public let rateLimiter: RateLimiter?

    /// I/O engine: "Sync" or "Async"
    public let ioEngine: String?

    /// Socket path for vhost-user-blk (optional)
    public let socket: String?

    enum CodingKeys: String, CodingKey {
        case driveId = "drive_id"
        case pathOnHost = "path_on_host"
        case isReadOnly = "is_read_only"
        case isRootDevice = "is_root_device"
        case partuuid
        case rateLimiter = "rate_limiter"
        case ioEngine = "io_engine"
        case socket
    }

    public init(
        driveId: String,
        pathOnHost: String,
        isReadOnly: Bool = false,
        isRootDevice: Bool = false,
        partuuid: String? = nil,
        rateLimiter: RateLimiter? = nil,
        ioEngine: String? = nil,
        socket: String? = nil
    ) {
        self.driveId = driveId
        self.pathOnHost = pathOnHost
        self.isReadOnly = isReadOnly
        self.isRootDevice = isRootDevice
        self.partuuid = partuuid
        self.rateLimiter = rateLimiter
        self.ioEngine = ioEngine
        self.socket = socket
    }

    /// Creates a root drive configuration
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

    /// Creates a data drive configuration
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

/// Rate limiter configuration for I/O or network
public struct RateLimiter: Codable, Sendable {
    /// Bandwidth rate limiter
    public let bandwidth: TokenBucket?

    /// Operations per second rate limiter
    public let ops: TokenBucket?

    public init(bandwidth: TokenBucket? = nil, ops: TokenBucket? = nil) {
        self.bandwidth = bandwidth
        self.ops = ops
    }
}

/// Token bucket configuration for rate limiting
public struct TokenBucket: Codable, Sendable {
    /// Bucket size (burst capacity)
    public let size: Int

    /// One-time burst size (optional)
    public let oneTimeBurst: Int?

    /// Refill time in milliseconds
    public let refillTime: Int

    enum CodingKeys: String, CodingKey {
        case size
        case oneTimeBurst = "one_time_burst"
        case refillTime = "refill_time"
    }

    public init(size: Int, oneTimeBurst: Int? = nil, refillTime: Int) {
        self.size = size
        self.oneTimeBurst = oneTimeBurst
        self.refillTime = refillTime
    }
}
