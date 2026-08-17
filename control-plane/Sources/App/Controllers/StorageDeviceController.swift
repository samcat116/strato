import Fluent
import Foundation
import SQLKit
import StratoShared
import Vapor

enum StorageDeviceEligibilityBlockedReason: String, Codable, Sendable {
    case missingIdentity
    case notPresent
    case inUse
    case draining
    case faulted
    case agentOffline
    case staleObservation

    var message: String {
        switch self {
        case .missingIdentity: return "The device has no stable WWN or serial identity."
        case .notPresent: return "The device is no longer present on the agent."
        case .inUse: return "The device is already in use."
        case .draining: return "The device is draining."
        case .faulted: return "The device is faulted."
        case .agentOffline: return "The agent is offline."
        case .staleObservation: return "The device observation is older than 60 seconds."
        }
    }
}

struct StorageDeviceEligibility: Sendable {
    struct Result: Sendable {
        let osdEligible: Bool
        let canMarkOsdEligible: Bool
        let blockedReason: StorageDeviceEligibilityBlockedReason?
    }

    static func evaluate(_ device: StorageDevice, agent: Agent, now: Date = Date()) -> Result {
        let agentOnline = agent.lastHeartbeat.map { now.timeIntervalSince($0) < 60 } ?? false
        return evaluate(device, agentOnline: agentOnline, now: now)
    }

    static func evaluate(
        _ device: StorageDevice,
        agentOnline: Bool,
        now: Date = Date()
    ) -> Result {
        let blocker: StorageDeviceEligibilityBlockedReason?
        if device.identity == nil {
            blocker = .missingIdentity
        } else if !device.present {
            blocker = .notPresent
        } else {
            switch device.state {
            case .inUse: blocker = .inUse
            case .draining: blocker = .draining
            case .faulted: blocker = .faulted
            case .available:
                if !agentOnline {
                    blocker = .agentOffline
                } else if device.lastSeenAt.map({ now.timeIntervalSince($0) > 60 }) ?? true {
                    blocker = .staleObservation
                } else {
                    blocker = nil
                }
            }
        }
        return Result(
            osdEligible: device.role == .osd,
            canMarkOsdEligible: blocker == nil,
            blockedReason: blocker)
    }
}

struct StorageDeviceResponse: Content, Sendable {
    let id: UUID
    let agentId: UUID
    let siteId: UUID
    let identityKind: String?
    let identityValue: String?
    let devicePath: String
    let sizeBytes: Int64
    let model: String?
    let serial: String?
    let wwn: String?
    let rotational: Bool
    let uses: [StorageDeviceUse]
    let role: StorageDeviceRole
    let state: StorageDeviceState
    let osdId: Int?
    let present: Bool
    let lastSeenAt: Date?
    let createdAt: Date?
    let updatedAt: Date?
    let osdEligible: Bool
    let canMarkOsdEligible: Bool
    let osdEligibilityBlockedReason: StorageDeviceEligibilityBlockedReason?

    init(device: StorageDevice, agent: Agent, now: Date = Date()) throws {
        let eligibility = StorageDeviceEligibility.evaluate(device, agent: agent, now: now)
        id = try device.requireID()
        agentId = try agent.requireID()
        siteId = agent.$site.id
        identityKind = device.identityKind
        identityValue = device.identityValue
        devicePath = device.devicePath
        sizeBytes = device.sizeBytes
        model = device.model
        serial = device.serial
        wwn = device.wwn
        rotational = device.rotational
        uses = device.uses
        role = device.role
        state = device.state
        osdId = device.osdId
        present = device.present
        lastSeenAt = device.lastSeenAt
        createdAt = device.createdAt
        updatedAt = device.updatedAt
        osdEligible = eligibility.osdEligible
        canMarkOsdEligible = eligibility.canMarkOsdEligible
        osdEligibilityBlockedReason = eligibility.blockedReason
    }
}

struct UpdateStorageDeviceRequest: Content, ValidatedRequestBody, Sendable {
    let osdEligible: Bool

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: AnyKey.self)
        let expected = AnyKey(stringValue: "osdEligible")
        guard Set(container.allKeys) == [expected] else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Expected exactly osdEligible"))
        }
        osdEligible = try container.decode(Bool.self, forKey: expected)
    }

    mutating func validate() throws {}

    private struct AnyKey: CodingKey, Hashable {
        let stringValue: String
        let intValue: Int? = nil

        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }
}

struct StorageDeviceController: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        let devices = routes.grouped("api", "storage-devices")
        devices.get(use: list)
        devices.patch(":deviceId", use: update)
    }

    func list(req: Request) async throws -> PagedResponse<StorageDeviceResponse> {
        let paging = try ListPaging.decode(from: req)
        let siteFilter = try optionalUUIDQuery("site_id", from: req)
        let agentFilter = try optionalUUIDQuery("agent_id", from: req)
        let visible = try await AgentController().visibleAgents(req: req)
            .filter { siteFilter == nil || $0.siteId == siteFilter }
            .filter { agentFilter == nil || $0.id == agentFilter }
        let visibleIDs = Set(visible.map(\.id))
        guard !visibleIDs.isEmpty else { return paging.page([]) }

        let agents = try await Agent.query(on: req.db)
            .filter(\.$id ~~ Array(visibleIDs))
            .all()
        let agentByID = Dictionary(
            uniqueKeysWithValues: agents.compactMap { agent in
                agent.id.map { ($0, agent) }
            })
        let siteIDs = Set(visible.map(\.siteId))
        let sites = try await Site.query(on: req.db)
            .filter(\.$id ~~ Array(siteIDs))
            .all()
        let siteNameByID = Dictionary(
            uniqueKeysWithValues: sites.compactMap { site in
                site.id.map { ($0, site.name) }
            })
        let agentNameByID = Dictionary(uniqueKeysWithValues: visible.map { ($0.id, $0.name) })
        let now = Date()
        let devices = try await StorageDevice.query(on: req.db)
            .filter(\.$agent.$id ~~ Array(visibleIDs))
            .all()
        let sorted = devices.sorted { lhs, rhs in
            let lhsAgentID = lhs.$agent.id
            let rhsAgentID = rhs.$agent.id
            let lhsSite = agentByID[lhsAgentID].map { siteNameByID[$0.$site.id] ?? "" } ?? ""
            let rhsSite = agentByID[rhsAgentID].map { siteNameByID[$0.$site.id] ?? "" } ?? ""
            if lhsSite != rhsSite { return lhsSite.localizedStandardCompare(rhsSite) == .orderedAscending }
            let lhsAgent = agentNameByID[lhsAgentID] ?? ""
            let rhsAgent = agentNameByID[rhsAgentID] ?? ""
            if lhsAgent != rhsAgent { return lhsAgent.localizedStandardCompare(rhsAgent) == .orderedAscending }
            if lhs.present != rhs.present { return lhs.present && !rhs.present }
            if lhs.devicePath != rhs.devicePath { return lhs.devicePath < rhs.devicePath }
            return (lhs.id?.uuidString ?? "") < (rhs.id?.uuidString ?? "")
        }
        let responses = try sorted.compactMap { device -> StorageDeviceResponse? in
            guard let agent = agentByID[device.$agent.id] else { return nil }
            return try StorageDeviceResponse(device: device, agent: agent, now: now)
        }
        return paging.page(responses)
    }

    func update(req: Request) async throws -> StorageDeviceResponse {
        guard let deviceID = req.parameters.get("deviceId", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid storage device ID")
        }
        let update = try req.content.decodeValidated(UpdateStorageDeviceRequest.self)
        return try await req.db.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase else {
                throw Abort(.internalServerError, reason: "Storage device updates require SQL")
            }
            _ = try await sql.raw(
                "SELECT id FROM storage_devices WHERE id = \(bind: deviceID) FOR UPDATE"
            ).all()
            guard let device = try await StorageDevice.find(deviceID, on: transaction) else {
                throw Abort(.notFound, reason: "Storage device not found")
            }
            guard let agent = try await Agent.find(device.$agent.id, on: transaction) else {
                throw Abort(.notFound, reason: "Storage device agent not found")
            }
            try await req.requireAgentAction("agent:manage", on: agent)

            if !update.osdEligible {
                device.role = .unassigned
            } else if device.role != .osd {
                let eligibility = StorageDeviceEligibility.evaluate(device, agent: agent)
                if let blocker = eligibility.blockedReason {
                    throw Abort(.conflict, reason: blocker.message)
                }
                device.role = .osd
            }
            try await device.save(on: transaction)
            return try StorageDeviceResponse(device: device, agent: agent)
        }
    }

    private func optionalUUIDQuery(_ name: String, from req: Request) throws -> UUID? {
        guard let raw = req.query[String.self, at: name] else { return nil }
        guard let value = UUID(uuidString: raw) else {
            throw Abort(.badRequest, reason: "Invalid \(name)")
        }
        return value
    }
}
