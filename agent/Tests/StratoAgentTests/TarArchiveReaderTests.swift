import Foundation
import Testing

@testable import StratoAgentCore

@Suite("Tar Archive Reader")
struct TarArchiveReaderTests {

    private func writeArchive(_ data: Data) throws -> String {
        let path = NSTemporaryDirectory() + "tar-reader-test-" + UUID().uuidString + ".tar"
        try data.write(to: URL(fileURLWithPath: path))
        return path
    }

    private func readAll(_ path: String) throws -> [(entry: TarEntry, content: Data)] {
        let reader = try TarArchiveReader(path: path)
        var results: [(TarEntry, Data)] = []
        while let entry = try reader.nextEntry() {
            var content = Data()
            if entry.type == .file {
                try reader.readContent { content.append($0) }
            }
            results.append((entry, content))
        }
        return results
    }

    @Test("plain ustar entries round-trip")
    func plainEntries() throws {
        var builder = TarTestBuilder()
        builder.addDirectory("etc", mode: 0o755, uid: 0, gid: 0)
        builder.addFile("etc/hostname", content: Data("sandbox\n".utf8), mode: 0o644, uid: 10, gid: 20)
        builder.addSymlink("etc/alias", target: "hostname")
        builder.addHardlink("etc/hardcopy", target: "etc/hostname")
        let path = try writeArchive(builder.finish())
        defer { try? FileManager.default.removeItem(atPath: path) }

        let entries = try readAll(path)
        #expect(entries.count == 4)
        #expect(entries[0].entry.type == .directory)
        #expect(entries[0].entry.name == "etc")
        #expect(entries[0].entry.mode == 0o755)
        #expect(entries[1].entry.type == .file)
        #expect(entries[1].content == Data("sandbox\n".utf8))
        #expect(entries[1].entry.uid == 10)
        #expect(entries[1].entry.gid == 20)
        #expect(entries[2].entry.type == .symbolicLink)
        #expect(entries[2].entry.linkName == "hostname")
        #expect(entries[3].entry.type == .hardLink)
        #expect(entries[3].entry.linkName == "etc/hostname")
    }

    @Test("skipping content is implicit when the caller doesn't read it")
    func contentSkipping() throws {
        var builder = TarTestBuilder()
        builder.addFile("big", content: Data(repeating: 7, count: 2000))
        builder.addFile("after", content: Data("next".utf8))
        let path = try writeArchive(builder.finish())
        defer { try? FileManager.default.removeItem(atPath: path) }

        let reader = try TarArchiveReader(path: path)
        let first = try reader.nextEntry()
        #expect(first?.name == "big")
        // Don't read "big"'s content; the reader must land on the next header.
        let second = try reader.nextEntry()
        #expect(second?.name == "after")
        var content = Data()
        try reader.readContent { content.append($0) }
        #expect(content == Data("next".utf8))
        let end = try reader.nextEntry()
        #expect(end == nil)
    }

    @Test("PAX records override path and the next entry only")
    func paxPathOverride() throws {
        let longName = "very/long/" + String(repeating: "component/", count: 15) + "leaf.txt"
        var builder = TarTestBuilder()
        builder.addPax(["path": longName])
        builder.addFile("short-placeholder", content: Data("payload".utf8))
        builder.addFile("unaffected", content: Data())
        let path = try writeArchive(builder.finish())
        defer { try? FileManager.default.removeItem(atPath: path) }

        let entries = try readAll(path)
        #expect(entries.count == 2)
        #expect(entries[0].entry.name == longName)
        #expect(entries[0].content == Data("payload".utf8))
        #expect(entries[1].entry.name == "unaffected")
    }

    @Test("GNU long-name entries override the next header's name")
    func gnuLongName() throws {
        let longName = String(repeating: "d/", count: 80) + "leaf"
        var builder = TarTestBuilder()
        builder.addGNULongName(longName)
        builder.addFile("placeholder", content: Data("x".utf8))
        let path = try writeArchive(builder.finish())
        defer { try? FileManager.default.removeItem(atPath: path) }

        let entries = try readAll(path)
        #expect(entries.count == 1)
        #expect(entries[0].entry.name == longName)
    }

    @Test("a corrupted header checksum is rejected")
    func checksumRejection() throws {
        var builder = TarTestBuilder()
        builder.addFile("ok", content: Data("fine".utf8))
        var archive = builder.finish()
        archive[0] = archive[0] &+ 1  // corrupt the first name byte
        let path = try writeArchive(archive)
        defer { try? FileManager.default.removeItem(atPath: path) }

        let reader = try TarArchiveReader(path: path)
        #expect(throws: TarArchiveReader.TarError.self) {
            _ = try reader.nextEntry()
        }
    }

    @Test("truncated archives are detected, not silently accepted")
    func truncation() throws {
        var builder = TarTestBuilder()
        builder.addFile("cut", content: Data(repeating: 1, count: 600))
        let archive = builder.finish().prefix(512 + 512)  // header + first content block only
        let path = try writeArchive(Data(archive))
        defer { try? FileManager.default.removeItem(atPath: path) }

        let reader = try TarArchiveReader(path: path)
        let entry = try reader.nextEntry()
        #expect(entry?.size == 600)
        #expect(throws: TarArchiveReader.TarError.self) {
            try reader.readContent { _ in }
        }
    }

    @Test("trailing-slash names are directories even with a file type flag")
    func trailingSlashDirectory() throws {
        var builder = TarTestBuilder()
        builder.addFile("legacy-dir/", content: Data())
        let path = try writeArchive(builder.finish())
        defer { try? FileManager.default.removeItem(atPath: path) }

        let entries = try readAll(path)
        #expect(entries[0].entry.type == .directory)
        #expect(entries[0].entry.name == "legacy-dir")
    }
}
