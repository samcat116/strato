import Foundation
import Testing
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif
@testable import StratoAgentCore

@Suite(.serialized)
struct CloudInitStagingTests {
    private func fixture(_ body: (String) throws -> Void) throws {
        let root = "/tmp/strato-stage-recovery-" + UUID().uuidString
        try ManagedStatePermissions.prepareVMDirectory(at: root)
        defer { try? FileManager.default.removeItem(atPath: root) }
        try body(root)
    }

    private func abandon(_ root: String, building: Bool = false, finished: Bool = false) throws {
        let stage = try CloudInitStaging(vmDirectory: root, vmID: "fixture")
        let documents = stage.path + "/documents"
        try ManagedStatePermissions.createFreshDirectory(at: documents)
        try DurableFileWriter().write(Data("seed secret".utf8), to: documents + "/user-data")
        if building { try stage.generatorWillStart() }
        if finished { try stage.generatorDidFinish() }
        // Releasing the lease without cleanup models an interrupted agent.
    }

    @Test func recoversVerifiedPreBuildAndCompletedCrashStages() throws {
        for completed in [false, true] {
            try fixture { root in
                try abandon(root, building: completed, finished: completed)
                let previous = root + "/cloud-init.iso"
                try DurableFileWriter().write(Data("published seed".utf8), to: previous)
                let recovered = try CloudInitStaging(vmDirectory: root, vmID: "fixture")
                #expect(!FileManager.default.fileExists(atPath: recovered.path + "/documents"))
                #expect(try String(contentsOfFile: previous, encoding: .utf8) == "published seed")
                try recovered.cleanup()
                #expect(!FileManager.default.fileExists(atPath: recovered.path))
            }
        }
    }

    @Test func refusesConcurrentLeaseAndPotentiallyOrphanedGenerator() throws {
        try fixture { root in
            let active = try CloudInitStaging(vmDirectory: root, vmID: "fixture")
            #expect(throws: (any Error).self) { try CloudInitStaging(vmDirectory: root, vmID: "fixture") }
            try active.cleanup()
        }
        try fixture { root in
            try abandon(root, building: true)
            #expect(throws: (any Error).self) { try CloudInitStaging(vmDirectory: root, vmID: "fixture") }
            #expect(
                try String(contentsOfFile: root + "/.cloud-init-staging/documents/user-data", encoding: .utf8)
                    == "seed secret")
        }
    }

    @Test func refusesForeignVMAndForeignOwnerWithoutMutation() throws {
        try fixture { root in
            try abandon(root)
            #expect(throws: (any Error).self) { try CloudInitStaging(vmDirectory: root, vmID: "other VM") }
            #expect(throws: (any Error).self) {
                try CloudInitStaging(vmDirectory: root, vmID: "fixture", effectiveUID: geteuid() ^ 1)
            }
            #expect(
                try String(contentsOfFile: root + "/.cloud-init-staging/documents/user-data", encoding: .utf8)
                    == "seed secret")
        }
    }

    @Test func refusesUnknownEntriesBeforeRemovingAnySeedDocuments() throws {
        try fixture { root in
            try abandon(root)
            let stage = root + "/.cloud-init-staging"
            try Data("operator bytes".utf8).write(to: URL(fileURLWithPath: stage + "/operator.txt"))
            #expect(throws: (any Error).self) { try CloudInitStaging(vmDirectory: root, vmID: "fixture") }
            #expect(try String(contentsOfFile: stage + "/documents/user-data", encoding: .utf8) == "seed secret")
            #expect(try String(contentsOfFile: stage + "/operator.txt", encoding: .utf8) == "operator bytes")
        }
    }

    @Test func refusesLinkedDocumentsAndMarkerWithoutMutation() throws {
        for marker in [false, true] {
            try fixture { root in
                try abandon(root)
                let stage = root + "/.cloud-init-staging"
                let target = root + "/operator.txt"
                try Data("operator bytes".utf8).write(to: URL(fileURLWithPath: target))
                let entry = marker ? stage + "/.strato-owner.json" : stage + "/documents/meta-data"
                if marker { try FileManager.default.removeItem(atPath: entry) }
                try FileManager.default.createSymbolicLink(atPath: entry, withDestinationPath: target)
                #expect(throws: (any Error).self) { try CloudInitStaging(vmDirectory: root, vmID: "fixture") }
                #expect(try String(contentsOfFile: target, encoding: .utf8) == "operator bytes")
                #expect(try String(contentsOfFile: stage + "/documents/user-data", encoding: .utf8) == "seed secret")
            }
        }
        try fixture { root in
            try abandon(root)
            let stage = root + "/.cloud-init-staging"
            #expect(link(stage + "/documents/user-data", root + "/operator-copy") == 0)
            #expect(throws: (any Error).self) { try CloudInitStaging(vmDirectory: root, vmID: "fixture") }
            #expect(try String(contentsOfFile: root + "/operator-copy", encoding: .utf8) == "seed secret")
        }
    }

    @Test func refusesReplacedStageAndCopiedIdentity() throws {
        try fixture { root in
            let active = try CloudInitStaging(vmDirectory: root, vmID: "fixture")
            let displaced = root + "/displaced"
            try FileManager.default.moveItem(atPath: active.path, toPath: displaced)
            try ManagedStatePermissions.createFreshDirectory(at: active.path)
            try FileManager.default.copyItem(
                atPath: displaced + "/.strato-owner.json", toPath: active.path + "/.strato-owner.json")
            try Data("operator bytes".utf8).write(to: URL(fileURLWithPath: active.path + "/cloud-init.iso"))
            #expect(throws: (any Error).self) { try active.cleanup() }
            #expect(throws: (any Error).self) { try CloudInitStaging(vmDirectory: root, vmID: "fixture") }
            #expect(try String(contentsOfFile: active.path + "/cloud-init.iso", encoding: .utf8) == "operator bytes")
            #expect(FileManager.default.fileExists(atPath: displaced + "/.strato-owner.json"))
        }
    }

    @Test func refusesInterruptedOrMalformedIdentityPublication() throws {
        for marker in [nil, "{partial"] as [String?] {
            try fixture { root in
                let path = root + "/.cloud-init-staging"
                try ManagedStatePermissions.createFreshDirectory(at: path)
                if let marker {
                    try DurableFileWriter().write(Data(marker.utf8), to: path + "/.strato-owner.json")
                }
                #expect(throws: (any Error).self) { try CloudInitStaging(vmDirectory: root, vmID: "fixture") }
                #expect(FileManager.default.fileExists(atPath: path))
            }
        }
    }
}
