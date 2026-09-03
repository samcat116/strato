import Foundation

/// Creates a unique test directory. Callers retain control of teardown timing
/// so tests that inspect files after an operation can defer cleanup locally.
package func makeTempDir(prefix: String = "strato-agent-tests") throws -> String {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true)
    return directory.path
}
