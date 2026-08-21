import ControlPlanePostgres
import Foundation
import StratoShared
import Vapor

typealias StorageDeviceEligibilityBlockedReason = StorageDeviceEligibilityBlocker

extension StorageDeviceEligibilityBlocker {
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

    init(
        device: StorageDeviceSnapshot,
        siteID: UUID,
        agentLastHeartbeat: Date?,
        now: Date = Date()
    ) {
        let eligibility = StorageDevicesPersistence.eligibility(
            for: device,
            agentLastHeartbeat: agentLastHeartbeat,
            now: now
        )
        id = device.id
        agentId = device.agentID
        siteId = siteID
        identityKind = device.identityKind?.rawValue
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
        osdId = device.osdID
        present = device.present
        lastSeenAt = device.lastSeenAt
        createdAt = device.createdAt
        updatedAt = device.updatedAt
        osdEligible = eligibility.osdEligible
        canMarkOsdEligible = eligibility.canMarkOSDEligible
        osdEligibilityBlockedReason = eligibility.blocker
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
    private let storageDevices: StorageDevicesPersistence
    private let agents: AgentsPersistence
    private let sites: SitesPersistence
    private let hierarchy: HierarchyPersistence

    init(
        storageDevices: StorageDevicesPersistence,
        agents: AgentsPersistence,
        sites: SitesPersistence,
        hierarchy: HierarchyPersistence
    ) {
        self.storageDevices = storageDevices
        self.agents = agents
        self.sites = sites
        self.hierarchy = hierarchy
    }

    func boot(routes: RoutesBuilder) throws {
        let devices = routes.grouped("api", "storage-devices")
        devices.get(use: list)
        devices.patch(":deviceId", use: update)
    }

    func list(req: Request) async throws -> PagedResponse<StorageDeviceResponse> {
        let paging = try ListPaging.decode(from: req)
        let siteFilter = try optionalUUIDQuery("site_id", from: req)
        let agentFilter = try optionalUUIDQuery("agent_id", from: req)
        let visible = try await AgentController(
            agents: agents,
            hierarchy: hierarchy
        ).visibleAgents(req: req)
            .filter { siteFilter == nil || $0.siteId == siteFilter }
            .filter { agentFilter == nil || $0.id == agentFilter }
        let visibleIDs = Set(visible.map(\.id))
        guard !visibleIDs.isEmpty else { return paging.page([]) }

        let agentByID = Dictionary(uniqueKeysWithValues: visible.map { ($0.id, $0) })
        let siteIDs = Set(visible.map(\.siteId))
        let siteRows = try await sites.allSites().filter { siteIDs.contains($0.id) }
        let siteNameByID = Dictionary(
            uniqueKeysWithValues: siteRows.map { ($0.id, $0.name) })
        let agentNameByID = Dictionary(uniqueKeysWithValues: visible.map { ($0.id, $0.name) })
        let now = Date()
        let devices = try await storageDevices.devices(forAgentIDs: Array(visibleIDs))
        let sorted = devices.sorted { lhs, rhs in
            let lhsAgentID = lhs.agentID
            let rhsAgentID = rhs.agentID
            let lhsSite = agentByID[lhsAgentID].map { siteNameByID[$0.siteId] ?? "" } ?? ""
            let rhsSite = agentByID[rhsAgentID].map { siteNameByID[$0.siteId] ?? "" } ?? ""
            if lhsSite != rhsSite { return lhsSite.localizedStandardCompare(rhsSite) == .orderedAscending }
            let lhsAgent = agentNameByID[lhsAgentID] ?? ""
            let rhsAgent = agentNameByID[rhsAgentID] ?? ""
            if lhsAgent != rhsAgent { return lhsAgent.localizedStandardCompare(rhsAgent) == .orderedAscending }
            if lhs.present != rhs.present { return lhs.present && !rhs.present }
            if lhs.devicePath != rhs.devicePath { return lhs.devicePath < rhs.devicePath }
            return lhs.id.uuidString < rhs.id.uuidString
        }
        let responses = sorted.compactMap { device -> StorageDeviceResponse? in
            guard let agent = agentByID[device.agentID] else { return nil }
            return StorageDeviceResponse(
                device: device,
                siteID: agent.siteId,
                agentLastHeartbeat: agent.lastHeartbeat,
                now: now
            )
        }
        return paging.page(responses)
    }

    func update(req: Request) async throws -> StorageDeviceResponse {
        guard let deviceID = req.parameters.get("deviceId", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid storage device ID")
        }
        let update = try req.content.decodeValidated(UpdateStorageDeviceRequest.self)
        guard let current = try await storageDevices.device(id: deviceID) else {
            throw Abort(.notFound, reason: "Storage device not found")
        }
        guard let agent = try await agents.agent(id: current.agentID) else {
            throw Abort(.notFound, reason: "Storage device agent not found")
        }
        if agent.organizationID == nil && agent.organizationalUnitID == nil {
            _ = try await req.requireSystemAdmin("This agent has no owning organization")
        } else {
            guard try await req.can("agent:manage", on: IAMNode(type: .agent, id: agent.id)) else {
                throw Abort(.forbidden, reason: "You don't have 'agent:manage' access on this agent")
            }
        }

        do {
            let mutation = try await storageDevices.setOSDEligibility(
                forDeviceID: deviceID,
                eligible: update.osdEligible
            )
            return StorageDeviceResponse(
                device: mutation.device,
                siteID: agent.siteID,
                agentLastHeartbeat: mutation.agentLastHeartbeat
            )
        } catch StorageDevicePersistenceError.notFound {
            throw Abort(.notFound, reason: "Storage device not found")
        } catch StorageDevicePersistenceError.agentNotFound {
            throw Abort(.notFound, reason: "Storage device agent not found")
        } catch StorageDevicePersistenceError.ineligible(let blocker) {
            throw Abort(.conflict, reason: blocker.message)
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
