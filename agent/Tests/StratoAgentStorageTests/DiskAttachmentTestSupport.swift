import StratoShared

/// Filesystem-backend tests deliberately require a file attachment. Keeping
/// this extraction test-only lets those assertions stay compact without
/// reintroducing a path-shaped production API on the sum type.
extension DiskAttachment {
    var filePath: String {
        guard case .file(let path, _) = self else {
            preconditionFailure("expected a file attachment, got \(self)")
        }
        return path
    }

    var fileFormat: DiskFormat {
        guard case .file(_, let format) = self else {
            preconditionFailure("expected a file attachment, got \(self)")
        }
        return format
    }
}
