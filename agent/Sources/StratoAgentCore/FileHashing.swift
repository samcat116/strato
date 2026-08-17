import Crypto
import Foundation

enum FileHashing {
    enum Error: Swift.Error, Equatable {
        case fileNotFound(String)
        case readFailed(path: String, reason: String)
    }

    static func sha256Hex(ofFileAt path: String) throws -> String {
        guard let fileHandle = FileHandle(forReadingAtPath: path) else {
            throw Error.fileNotFound(path)
        }
        defer { try? fileHandle.close() }

        do {
            var hasher = SHA256()
            while let chunk = try fileHandle.read(upToCount: 1024 * 1024), !chunk.isEmpty {
                hasher.update(data: chunk)
            }
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        } catch {
            throw Error.readFailed(path: path, reason: String(describing: error))
        }
    }
}
