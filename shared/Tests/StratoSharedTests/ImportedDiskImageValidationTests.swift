import Foundation
import Testing
@testable import StratoShared

@Suite("Imported disk metadata")
struct ImportedDiskImageValidationTests {
    static func image(version: UInt32 = 3, clusterBits: UInt32 = 9) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 1 << Int(clusterBits))
        bytes.replaceSubrange(0..<4, with: [0x51, 0x46, 0x49, 0xFB])
        set(&bytes, offset: 4, value: UInt64(version), count: 4)
        set(&bytes, offset: 20, value: UInt64(clusterBits), count: 4)
        if version == 3 { set(&bytes, offset: 100, value: 104, count: 4) }
        return bytes
    }
    static func set(_ bytes: inout [UInt8], offset: Int, value: UInt64, count: Int) {
        for index in 0..<count { bytes[offset + index] = UInt8(truncatingIfNeeded: value >> ((count - index - 1) * 8)) }
    }
    @Test(arguments: [UInt32(2), 3]) func selfContainedVersions(version: UInt32) throws {
        try ImportedDiskImageValidation.validate(prefix: Self.image(version: version))
    }
    @Test func nonQcowFormatsRemainOpaque() throws {
        for signature in ["raw bytes", "KDMV", "conectix", "vhdxfile"] {
            try ImportedDiskImageValidation.validate(prefix: Array(signature.utf8))
        }
    }
    @Test func absentBackingFileIgnoresUndefinedNameSize() throws {
        var bytes = Self.image()
        Self.set(&bytes, offset: 16, value: UInt64(UInt32.max), count: 4)
        try ImportedDiskImageValidation.validate(prefix: bytes)
    }
    @Test func preparedImportSurvivesCacheReplacement() throws {
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("cache-\(UUID()).qcow2")
        defer { try? FileManager.default.removeItem(at: source) }
        let original = Data(Self.image())
        try original.write(to: source)
        let prepared = try ImportedDiskImageValidation.prepare(filePath: source.path)
        defer { prepared.remove() }
        var unsafe = Self.image(); Self.set(&unsafe, offset: 72, value: 1 << 2, count: 8)
        try Data(unsafe).write(to: source, options: .atomic)
        #expect(try Data(contentsOf: URL(fileURLWithPath: prepared.path)) == original)
        try ImportedDiskImageValidation.validate(filePath: prepared.path)
        #expect(throws: ImportedDiskImageValidation.InvalidImage.self) {
            try ImportedDiskImageValidation.validate(filePath: source.path)
        }
    }
    @Test func symlinkImportsCannotEscapePrivateScratch() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("link-import-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source")
        let link = directory.appendingPathComponent("link")
        try Data(Self.image()).write(to: source)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
        #expect(throws: ImportedDiskImageValidation.InvalidImage.self) {
            try ImportedDiskImageValidation.prepare(filePath: link.path)
        }
    }
    @Test func rejectsReferencesAndMalformedStructure() {
        var cases: [[UInt8]] = []
        for (offset, value, count) in [
            (8, UInt64(128), 8), (72, 1 << 2, 8),
            (88, 1 << 1, 8), (4, 4, 4), (20, 22, 4), (100, 96, 4), (100, 105, 4),
            (72, 1 << 63, 8), (104, 0x44415441, 4),
        ] {
            var bytes = Self.image(); Self.set(&bytes, offset: offset, value: value, count: count); cases.append(bytes)
        }
        var extensionOverflow = Self.image()
        Self.set(&extensionOverflow, offset: 104, value: 0x6803f857, count: 4)
        Self.set(&extensionOverflow, offset: 108, value: UInt64(UInt32.max), count: 4)
        cases.append(extensionOverflow)
        for length in [4, 71, 72, 103, 104, 511] { cases.append(Array(Self.image().prefix(length))) }
        for bytes in cases {
            #expect(throws: ImportedDiskImageValidation.InvalidImage.self) {
                try ImportedDiskImageValidation.validate(prefix: bytes)
            }
        }
    }
    @Test func corruptBitIsNotExternalDataBitAndExtensionsAreWalked() throws {
        var bytes = Self.image()
        Self.set(&bytes, offset: 72, value: 1 << 1, count: 8)
        Self.set(&bytes, offset: 104, value: 0x6803f857, count: 4)
        Self.set(&bytes, offset: 108, value: 1, count: 4)
        try ImportedDiskImageValidation.validate(prefix: bytes)
        Self.set(&bytes, offset: 120, value: 0x44415441, count: 4)
        #expect(throws: ImportedDiskImageValidation.InvalidImage.self) {
            try ImportedDiskImageValidation.validate(prefix: bytes)
        }
    }
}
