import Foundation
import Logging
import Testing

@testable import StratoAgentCore

@Suite("OCI Image Flattener")
struct OCIImageFlattenerTests {

    private func makeTempDir() throws -> String {
        let dir = NSTemporaryDirectory() + "flattener-tests-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    private func writeLayer(_ builder: TarTestBuilder, in dir: String, name: String) throws -> String {
        let path = dir + "/" + name
        try builder.finish().write(to: URL(fileURLWithPath: path))
        return path
    }

    /// Applies layers to a fresh root (ownership never applied: tests run
    /// unprivileged) and returns the root path.
    private func flatten(_ layers: [TarTestBuilder], in dir: String) throws -> String {
        let root = dir + "/root"
        let flattener = try OCIImageFlattener(
            rootPath: root, logger: Logger(label: "test"), applyOwnership: false)
        for (index, layer) in layers.enumerated() {
            let path = try writeLayer(layer, in: dir, name: "layer-\(index).tar")
            try flattener.apply(layerTarPath: path)
        }
        try flattener.finalize()
        return root
    }

    private func contents(_ path: String) -> String? {
        FileManager.default.contents(atPath: path).map { String(decoding: $0, as: UTF8.self) }
    }

    @Test("layers stack, later layers replace earlier files")
    func layerStacking() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }

        var base = TarTestBuilder()
        base.addDirectory("etc")
        base.addFile("etc/motd", content: Data("hello v1".utf8))
        base.addFile("etc/keep", content: Data("kept".utf8))

        var top = TarTestBuilder()
        top.addFile("etc/motd", content: Data("hello v2".utf8))

        let root = try flatten([base, top], in: dir)
        #expect(contents(root + "/etc/motd") == "hello v2")
        #expect(contents(root + "/etc/keep") == "kept")
    }

    @Test("whiteouts remove lower-layer entries")
    func whiteouts() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }

        var base = TarTestBuilder()
        base.addDirectory("app")
        base.addFile("app/stale.txt", content: Data("old".utf8))
        base.addDirectory("app/cache")
        base.addFile("app/cache/entry", content: Data("cached".utf8))

        var top = TarTestBuilder()
        top.addFile("app/.wh.stale.txt", content: Data())
        top.addFile("app/.wh.cache", content: Data())

        let root = try flatten([base, top], in: dir)
        #expect(!FileManager.default.fileExists(atPath: root + "/app/stale.txt"))
        #expect(!FileManager.default.fileExists(atPath: root + "/app/cache"))
    }

    @Test("opaque whiteouts clear a directory but keep the layer's own entries")
    func opaqueWhiteout() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }

        var base = TarTestBuilder()
        base.addDirectory("data")
        base.addFile("data/lower-a", content: Data("a".utf8))
        base.addFile("data/lower-b", content: Data("b".utf8))

        var top = TarTestBuilder()
        top.addDirectory("data")
        top.addFile("data/.wh..wh..opq", content: Data())
        top.addFile("data/fresh", content: Data("new".utf8))

        let root = try flatten([base, top], in: dir)
        #expect(!FileManager.default.fileExists(atPath: root + "/data/lower-a"))
        #expect(!FileManager.default.fileExists(atPath: root + "/data/lower-b"))
        #expect(contents(root + "/data/fresh") == "new")
    }

    @Test("path traversal entries are rejected")
    func pathTraversal() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }

        var evil = TarTestBuilder()
        evil.addFile("../escape.txt", content: Data("evil".utf8))

        let root = dir + "/root"
        let flattener = try OCIImageFlattener(
            rootPath: root, logger: Logger(label: "test"), applyOwnership: false)
        let layerPath = try writeLayer(evil, in: dir, name: "evil.tar")

        #expect(throws: OCIError.self) {
            try flattener.apply(layerTarPath: layerPath)
        }
        #expect(!FileManager.default.fileExists(atPath: dir + "/escape.txt"))
    }

    @Test("a symlinked parent cannot redirect writes outside the root")
    func symlinkEscape() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }

        // Layer 1 plants a symlink pointing at an absolute path; layer 2
        // writes "through" it. The write must land inside the root (the
        // absolute target re-anchors at the rootfs root), never on the host.
        var base = TarTestBuilder()
        base.addSymlink("leak", target: "/outside")

        var top = TarTestBuilder()
        top.addFile("leak/pwned.txt", content: Data("contained".utf8))

        let root = try flatten([base, top], in: dir)
        #expect(!FileManager.default.fileExists(atPath: "/outside/pwned.txt"))
        #expect(contents(root + "/outside/pwned.txt") == "contained")
    }

    @Test("hardlinks materialize within the root and reject unsafe targets")
    func hardlinks() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }

        var layer = TarTestBuilder()
        layer.addFile("bin/tool", content: Data("#!bin".utf8))
        layer.addHardlink("bin/alias", target: "bin/tool")
        let root = try flatten([layer], in: dir)
        #expect(contents(root + "/bin/alias") == "#!bin")

        var evil = TarTestBuilder()
        evil.addHardlink("stolen", target: "../../etc/passwd")
        let flattener = try OCIImageFlattener(
            rootPath: dir + "/root2", logger: Logger(label: "test"), applyOwnership: false)
        let evilPath = try writeLayer(evil, in: dir, name: "evil-link.tar")
        #expect(throws: OCIError.self) {
            try flattener.apply(layerTarPath: evilPath)
        }
    }

    @Test("read-only directory modes are deferred so children can still land")
    func deferredDirectoryModes() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }

        var layer = TarTestBuilder()
        layer.addDirectory("sealed", mode: 0o555)
        layer.addFile("sealed/inside.txt", content: Data("in".utf8), mode: 0o444)

        let root = try flatten([layer], in: dir)
        // Restore permissions before cleanup can fail on the read-only dir.
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: root + "/sealed")
        }

        #expect(contents(root + "/sealed/inside.txt") == "in")
        let attributes = try FileManager.default.attributesOfItem(atPath: root + "/sealed")
        let mode = (attributes[.posixPermissions] as? NSNumber)?.uint16Value
        #expect(mode == 0o555)
    }

    @Test("a later layer can replace a directory with a file")
    func directoryReplacedByFile() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }

        var base = TarTestBuilder()
        base.addDirectory("thing")
        base.addFile("thing/child", content: Data("c".utf8))

        var top = TarTestBuilder()
        top.addFile("thing", content: Data("now-a-file".utf8))

        let root = try flatten([base, top], in: dir)
        #expect(contents(root + "/thing") == "now-a-file")
    }

    @Test("device nodes are skipped, not fatal")
    func deviceNodesSkipped() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }

        var layer = TarTestBuilder()
        layer.addSpecial("dev/null", typeFlag: UInt8(ascii: "3"))
        layer.addFile("after", content: Data("still-here".utf8))

        let root = try flatten([layer], in: dir)
        #expect(!FileManager.default.fileExists(atPath: root + "/dev/null"))
        #expect(contents(root + "/after") == "still-here")
    }
}
