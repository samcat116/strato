import StratoShared

/// Filesystem-backend tests deliberately require a file attachment. Keeping
/// this extraction test-only lets those assertions stay compact without
/// reintroducing a path-shaped production API on the sum type.
extension DiskAttachment {
    var filePath: String {
        guard case .file(let file) = value else {
            preconditionFailure("expected a file attachment, got \(self)")
        }
        return file.path
    }

    var fileFormat: DiskFormat {
        guard case .file(let file) = value else {
            preconditionFailure("expected a file attachment, got \(self)")
        }
        return file.format
    }
}
