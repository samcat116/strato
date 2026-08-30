import AppTestSupport
import Fluent
import Foundation
import SQLKit
import StratoShared
import Testing
import Vapor

@testable import App

@Suite("MAC allocator")
struct MACAllocatorTests {
    @Test("Concurrent VM and sandbox NIC allocations remain fleet-wide unique")
    func concurrentCrossTableAllocationsAreUnique() async throws {
        try await withTestApp { app in
            let builder = TestDataBuilder(db: app.db)
            let organization = try await builder.createOrganization()
            let project = try await builder.createProject(
                name: "mac-contention", description: "MAC contention", organization: organization)
            let network = try await builder.createNetwork(project: project)
            let networkID = try network.requireID()

            var owners: [Owner] = []
            for index in 0..<6 {
                let vm = try await builder.createVM(name: "mac-vm-\(index)", project: project)
                owners.append(.vm(try vm.requireID()))
                let sandbox = try await builder.createSandbox(name: "mac-sandbox-\(index)", project: project)
                owners.append(.sandbox(try sandbox.requireID()))
            }

            // Make every contender draw the same address first. The ledger,
            // not the 40 random bits, must be what makes the result unique.
            let candidates = CandidateSequence(repeatedCollisionCount: owners.count)
            let addresses = try await withThrowingTaskGroup(of: String.self) { group in
                for owner in owners {
                    group.addTask {
                        try await app.db.transaction { db in
                            let interfaceID = UUID()
                            let kind: MACAllocator.OwnerKind =
                                switch owner {
                                case .vm: .vmInterface
                                case .sandbox: .sandboxInterface
                                }
                            let address = try await MACAllocator.allocate(
                                for: kind,
                                ownerID: interfaceID,
                                on: db,
                                candidate: { await candidates.next() })
                            switch owner {
                            case .vm(let vmID):
                                try await VMNetworkInterface(
                                    id: interfaceID,
                                    vmID: vmID,
                                    logicalNetworkID: networkID,
                                    macAddress: address.description,
                                    deviceName: "net0",
                                    orderIndex: 0
                                ).save(on: db)
                            case .sandbox(let sandboxID):
                                try await SandboxNetworkInterface(
                                    id: interfaceID,
                                    sandboxID: sandboxID,
                                    logicalNetworkID: networkID,
                                    macAddress: address.description,
                                    deviceName: "net0"
                                ).save(on: db)
                            }
                            return address.description
                        }
                    }
                }

                var allocated: [String] = []
                for try await address in group { allocated.append(address) }
                return allocated
            }

            #expect(addresses.count == owners.count)
            #expect(Set(addresses).count == owners.count)
            #expect(addresses.allSatisfy { MACAddress(allocated: $0) != nil })

            let sql = try #require(app.db as? any SQLDatabase)
            let ledgerCount = try await sql.raw(
                "SELECT count(*)::int AS count FROM mac_address_allocations"
            ).first(decodingColumn: "count", as: Int.self)
            #expect(ledgerCount == owners.count)
        }
    }

    @Test("Deleting an interface returns its address to the ledger pool")
    func interfaceDeletionReleasesAddress() async throws {
        try await withTestApp { app in
            let builder = TestDataBuilder(db: app.db)
            let organization = try await builder.createOrganization()
            let project = try await builder.createProject(
                name: "mac-release", description: "MAC release", organization: organization)
            let network = try await builder.createNetwork(project: project)
            let vm = try await builder.createVM(name: "mac-release-vm", project: project)
            let interfaceID = UUID()
            let address = try await MACAllocator.allocate(
                for: .vmInterface, ownerID: interfaceID, on: app.db)
            let interface = VMNetworkInterface(
                id: interfaceID,
                vmID: try vm.requireID(),
                logicalNetworkID: try network.requireID(),
                macAddress: address.description)
            try await interface.save(on: app.db)

            try await interface.delete(on: app.db)

            let sql = try #require(app.db as? any SQLDatabase)
            let retained = try await sql.raw(
                "SELECT count(*)::int AS count FROM mac_address_allocations WHERE mac_address = \(bind: address.description)"
            ).first(decodingColumn: "count", as: Int.self)
            #expect(retained == 0)
        }
    }

    @Test("A permanently colliding candidate exhausts a bounded retry")
    func collisionRetryIsBounded() async throws {
        try await withTestApp { app in
            let address = try #require(MACAddress(allocated: "02:00:00:00:00:01"))
            _ = try await MACAllocator.allocate(
                for: .vmInterface, ownerID: UUID(), on: app.db,
                candidate: { address })

            await #expect(throws: MACAllocator.AllocationError.attemptsExhausted(3)) {
                try await MACAllocator.allocate(
                    for: .sandboxInterface, ownerID: UUID(), on: app.db,
                    maximumAttempts: 3, candidate: { address })
            }
        }
    }
}

private enum Owner: Sendable {
    case vm(UUID)
    case sandbox(UUID)
}

private actor CandidateSequence {
    private var repeatedCollisionCount: Int
    private var nextUnique: UInt64 = 2

    init(repeatedCollisionCount: Int) {
        self.repeatedCollisionCount = repeatedCollisionCount
    }

    func next() -> MACAddress {
        if repeatedCollisionCount > 0 {
            repeatedCollisionCount -= 1
            return MACAddress(allocated: "02:00:00:00:00:01")!
        }
        defer { nextUnique += 1 }
        let suffix = String(format: "%010llx", nextUnique)
        let octets = stride(from: 0, to: suffix.count, by: 2).map { index -> String in
            let start = suffix.index(suffix.startIndex, offsetBy: index)
            let end = suffix.index(start, offsetBy: 2)
            return String(suffix[start..<end])
        }
        return MACAddress(allocated: "02:\(octets.joined(separator: ":"))")!
    }
}
