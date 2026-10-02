import Crypto
import Foundation

/// Local-only preparatory STR-273 types. No wire capability is advertised.
public enum SandboxRestoreMemoryPreparation {
    public struct FilePlan: Sendable, Equatable {
        public let path: String
        public let fallbackReason: String
    }

    /// The sole production selection until a supervised handler, complete
    /// lifecycle integration and an actual compatible restore proof exist.
    /// Kernel versions and isolated model/probe results cannot enable UFFD.
    public static func prepare(filePath: String) throws -> FilePlan {
        try Task.checkCancellation()
        return FilePlan(
            path: filePath,
            fallbackReason: "uffd-disabled: supervised-handler-and-end-to-end-lifecycle-proof-missing")
    }
}

/// Immutable digest-verified source plus a bounded private delta. This is a
/// page source contract, not guest memory, dirty tracking or a UFFD handler.
public struct SandboxLazyMemoryPages: Sendable {
    public enum PageError: Error, Equatable {
        case incompatibleTrustClass, invalidLayout, digestMismatch
        case invalidPage, deltaFull, cancelled
    }

    public struct Base: Sendable {
        public let digest: String
        public let trustClass: String
        public let pageSize: Int
        fileprivate let data: Data

        public init(data: Data, digest: String, trustClass: String, pageSize: Int = 4096) throws {
            guard !trustClass.isEmpty else { throw PageError.incompatibleTrustClass }
            guard pageSize > 0, !data.isEmpty, data.count % pageSize == 0 else {
                throw PageError.invalidLayout
            }
            // Copy foreign/no-copy buffers before hashing so subsequent caller
            // mutation cannot change the verified source behind this value.
            let owned = data.withUnsafeBytes { Data($0) }
            let actual = SHA256.hash(data: owned).map { String(format: "%02x", $0) }.joined()
            guard actual == digest else { throw PageError.digestMismatch }
            self.data = owned
            self.digest = digest
            self.trustClass = trustClass
            self.pageSize = pageSize
        }
    }

    private let base: Base
    private let maximumDirtyPages: Int
    private var dirty: [Int: Data] = [:]
    private var cancelled = false

    public init(base: Base, trustClass: String, maximumDirtyPages: Int) throws {
        guard base.trustClass == trustClass else { throw PageError.incompatibleTrustClass }
        guard maximumDirtyPages > 0 else { throw PageError.invalidLayout }
        self.base = base
        self.maximumDirtyPages = maximumDirtyPages
    }

    private func check(_ page: Int) throws {
        guard !cancelled else { throw PageError.cancelled }
        guard page >= 0, page < base.data.count / base.pageSize else { throw PageError.invalidPage }
    }

    public func read(page: Int) throws -> Data {
        try check(page)
        if let privatePage = dirty[page] { return privatePage }
        let start = page * base.pageSize
        return base.data.subdata(in: start..<(start + base.pageSize))
    }

    public mutating func write(page: Int, data: Data) throws {
        try check(page)
        guard data.count == base.pageSize else { throw PageError.invalidPage }
        guard dirty[page] != nil || dirty.count < maximumDirtyPages else { throw PageError.deltaFull }
        dirty[page] = data.withUnsafeBytes { Data($0) }
    }

    public mutating func cancel() {
        cancelled = true
        dirty.removeAll(keepingCapacity: false)
    }
}
