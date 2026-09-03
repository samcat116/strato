import Foundation
import StratoShared

extension HostPreflight {
    // MARK: - Filesystem helpers

    /// Free bytes of the filesystem backing `path`, resolved via the nearest
    /// existing ancestor when the path itself does not exist yet.
    public static func freeDiskSpace(atPath path: String) -> Int64? {
        let fileManager = FileManager.default
        var probePath = path.isEmpty ? "/" : path
        while !fileManager.fileExists(atPath: probePath) {
            let parent = (probePath as NSString).deletingLastPathComponent
            if parent.isEmpty || parent == probePath {
                probePath = "/"
                break
            }
            probePath = parent
        }
        guard let attributes = try? fileManager.attributesOfFileSystem(forPath: probePath),
            let free = (attributes[.systemFreeSize] as? NSNumber)?.int64Value
        else {
            return nil
        }
        return free
    }

    static func byteString(_ bytes: Int64) -> String {
        let units = ["B", "KiB", "MiB", "GiB", "TiB"]
        var value = Double(bytes)
        var unitIndex = 0
        while value >= 1024, unitIndex < units.count - 1 {
            value /= 1024
            unitIndex += 1
        }
        return String(format: value < 10 ? "%.1f %@" : "%.0f %@", value, units[unitIndex])
    }
}
