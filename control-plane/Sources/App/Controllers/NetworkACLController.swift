import Fluent
import Vapor

/// A network-owned stateless ACL. Rules are immutable subresources and the
/// ACL itself is optional: existing networks remain unfiltered until a caller
/// explicitly creates one.
struct NetworkACLController: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        let acl =
            routes
            .grouped("api", "networks", ":networkId", "acl")
            .grouped(User.guardMiddleware())
        acl.get(use: getACL)
        acl.post(use: createACL)
        acl.delete(use: deleteACL)
        acl.post("rules", use: createRule)
        acl.delete("rules", ":ruleId", use: deleteRule)
    }

    /// GET /api/networks/:networkId/acl
    @Sendable
    func getACL(req: Request) async throws -> NetworkACLResponse {
        let network = try await authorizedNetwork(req: req, action: "network:read")
        let networkID = try network.requireID()
        guard let acl = try await Self.loadACL(for: networkID, withRules: true, on: req.db) else {
            throw Abort(.notFound, reason: "Network ACL not found")
        }
        return try NetworkACLResponse(from: acl)
    }

    /// POST /api/networks/:networkId/acl
    @Sendable
    func createACL(req: Request) async throws -> NetworkACLResponse {
        let network = try await authorizedNetwork(req: req, action: "network:update")
        let networkID = try network.requireID()

        let acl: NetworkACL
        do {
            acl = try await req.db.transaction { db in
                try await NetworkACLService.lockNetwork(networkID, on: db)
                guard try await Self.loadACL(for: networkID, withRules: false, on: db) == nil else {
                    throw Abort(.conflict, reason: "Network already has an ACL")
                }

                let acl = NetworkACL(logicalNetworkID: networkID)
                try await acl.save(on: db)
                try await NetworkACLService.bumpNetworkGeneration(networkID, on: db)
                return acl
            }
        } catch let error as any DatabaseError where error.isConstraintFailure {
            // The unique network FK is the authority if two creators race.
            throw Abort(.conflict, reason: "Network already has an ACL")
        }

        acl.$rules.value = []
        await req.application.agentService.syncDesiredStateToFleet()
        req.logger.info(
            "Network ACL created",
            metadata: [
                "networkACLId": .string(acl.id!.uuidString),
                "networkId": .string(networkID.uuidString),
            ])
        return try NetworkACLResponse(from: acl)
    }

    /// DELETE /api/networks/:networkId/acl
    @Sendable
    func deleteACL(req: Request) async throws -> HTTPStatus {
        let network = try await authorizedNetwork(req: req, action: "network:update")
        let networkID = try network.requireID()

        try await req.db.transaction { db in
            try await NetworkACLService.lockNetwork(networkID, on: db)
            guard let acl = try await Self.loadACL(for: networkID, withRules: false, on: db) else {
                throw Abort(.notFound, reason: "Network ACL not found")
            }
            let aclID = try acl.requireID()
            try await NetworkACLService.lockACL(aclID, on: db)
            // Advance the inner guard before removing the row, and the outer
            // network guard before removing it. All operations commit
            // atomically with the cascade deletion of the rules.
            try await NetworkACLService.bumpACLGeneration(aclID, on: db)
            try await NetworkACLService.bumpNetworkGeneration(networkID, on: db)
            try await acl.delete(on: db)
        }

        await req.application.agentService.syncDesiredStateToFleet()
        req.logger.info(
            "Network ACL deleted",
            metadata: ["networkId": .string(networkID.uuidString)])
        return .noContent
    }

    /// POST /api/networks/:networkId/acl/rules
    @Sendable
    func createRule(req: Request) async throws -> NetworkACLRuleResponse {
        let network = try await authorizedNetwork(req: req, action: "network:update")
        let networkID = try network.requireID()
        let request = try req.content.decodeValidated(CreateNetworkACLRuleRequest.self)
        let protocolName = try NetworkACLService.validateRule(request)

        let rule: NetworkACLRule
        do {
            rule = try await req.db.transaction { db in
                try await NetworkACLService.lockNetwork(networkID, on: db)
                guard let acl = try await Self.loadACL(for: networkID, withRules: false, on: db) else {
                    throw Abort(.notFound, reason: "Network ACL not found")
                }
                let aclID = try acl.requireID()
                try await NetworkACLService.lockACL(aclID, on: db)

                let count = try await NetworkACLRule.query(on: db)
                    .filter(\.$networkACL.$id == aclID)
                    .count()
                guard count < NetworkACL.maxRules else {
                    throw Abort(
                        .forbidden,
                        reason: "Rule limit reached: \(NetworkACL.maxRules) rules per network ACL")
                }

                let rule = NetworkACLRule(
                    networkACLID: aclID,
                    ruleNumber: request.ruleNumber,
                    direction: request.direction,
                    ethertype: request.ethertype,
                    action: request.action,
                    protocolName: protocolName,
                    portRangeMin: request.portRangeMin,
                    portRangeMax: request.portRangeMax,
                    remoteCIDR: request.remoteCIDR,
                    description: request.description)
                try await rule.save(on: db)
                try await NetworkACLService.bumpACLGeneration(aclID, on: db)
                try await NetworkACLService.bumpNetworkGeneration(networkID, on: db)
                return rule
            }
        } catch let error as any DatabaseError where error.isConstraintFailure {
            throw Abort(
                .conflict,
                reason: "Rule number \(request.ruleNumber) already exists for \(request.direction.rawValue) traffic")
        }

        await req.application.agentService.syncDesiredStateToFleet()
        req.logger.info(
            "Network ACL rule created",
            metadata: [
                "networkACLRuleId": .string(rule.id!.uuidString),
                "networkId": .string(networkID.uuidString),
                "ruleNumber": .stringConvertible(request.ruleNumber),
            ])
        return try NetworkACLRuleResponse(from: rule)
    }

    /// DELETE /api/networks/:networkId/acl/rules/:ruleId
    @Sendable
    func deleteRule(req: Request) async throws -> HTTPStatus {
        let network = try await authorizedNetwork(req: req, action: "network:update")
        let networkID = try network.requireID()
        guard let ruleID = req.parameters.get("ruleId", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid rule ID")
        }

        try await req.db.transaction { db in
            try await NetworkACLService.lockNetwork(networkID, on: db)
            guard let acl = try await Self.loadACL(for: networkID, withRules: false, on: db) else {
                throw Abort(.notFound, reason: "Network ACL not found")
            }
            let aclID = try acl.requireID()
            try await NetworkACLService.lockACL(aclID, on: db)
            guard
                let rule = try await NetworkACLRule.query(on: db)
                    .filter(\.$id == ruleID)
                    .filter(\.$networkACL.$id == aclID)
                    .first()
            else {
                throw Abort(.notFound, reason: "Rule not found in this network ACL")
            }

            try await rule.delete(on: db)
            try await NetworkACLService.bumpACLGeneration(aclID, on: db)
            try await NetworkACLService.bumpNetworkGeneration(networkID, on: db)
        }

        await req.application.agentService.syncDesiredStateToFleet()
        req.logger.info(
            "Network ACL rule deleted",
            metadata: [
                "networkACLRuleId": .string(ruleID.uuidString),
                "networkId": .string(networkID.uuidString),
            ])
        return .noContent
    }

    private static func loadACL(
        for networkID: UUID, withRules: Bool, on db: any Database
    ) async throws -> NetworkACL? {
        var query = NetworkACL.query(on: db)
            .filter(\.$logicalNetwork.$id == networkID)
        if withRules {
            query = query.with(\.$rules)
        }
        return try await query.first()
    }

    /// Network ACLs inherit their owning network's IAM node. Keeping the
    /// authorization check at that boundary avoids a parallel ACL resource
    /// tree and prevents an opaque ACL id from becoming a cross-project probe.
    private func authorizedNetwork(req: Request, action: String) async throws -> LogicalNetwork {
        _ = try req.auth.require(User.self)
        guard let networkID = req.parameters.get("networkId", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid network ID")
        }
        guard let network = try await LogicalNetwork.find(networkID, on: req.db) else {
            throw Abort(.notFound, reason: "Network not found")
        }
        guard try await req.can(action, on: IAMNode(type: .network, id: networkID)) else {
            throw Abort(.forbidden, reason: "You don't have '\(action)' access on this network")
        }
        return network
    }
}
