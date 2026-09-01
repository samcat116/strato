import Fluent
import Foundation
import SQLKit
import Vapor

struct CreateExternalCephClusterRequest: Content, ValidatedRequestBody {
    var fsid: String
    var monEndpoints: [String]
    var clientName: String
    let keyring: String

    mutating func validate() throws {
        fsid = try CephStorageInput.fsid(fsid)
        monEndpoints = try CephStorageInput.monEndpoints(monEndpoints)
        clientName = try CephStorageInput.clientName(clientName)
        try CephStorageInput.keyring(keyring, clientName: clientName)
    }
}

struct UpdateExternalCephClusterRequest: Content, ValidatedRequestBody {
    var monEndpoints: [String]
    var clientName: String
    let keyring: String?

    mutating func validate() throws {
        monEndpoints = try CephStorageInput.monEndpoints(monEndpoints)
        clientName = try CephStorageInput.clientName(clientName)
        if let keyring { try CephStorageInput.keyring(keyring, clientName: clientName) }
    }
}

struct UpsertCephProjectAccessRequest: Content, ValidatedRequestBody {
    var clientName: String
    /// Required on create and optional on update. If `clientName` changes, a
    /// replacement keyring is required because cephx keys name one principal.
    let keyring: String?
    var storagePoolName: String
    var cephPoolName: String
    var namespace: String
    /// Confirms that the operator revoked the retired cephx credential in the
    /// external cluster. Required when an existing credential is replaced.
    var cephxRevoked: Bool? = nil

    init(
        clientName: String,
        keyring: String?,
        storagePoolName: String,
        cephPoolName: String,
        namespace: String,
        cephxRevoked: Bool? = nil
    ) {
        self.clientName = clientName
        self.keyring = keyring
        self.storagePoolName = storagePoolName
        self.cephPoolName = cephPoolName
        self.namespace = namespace
        self.cephxRevoked = cephxRevoked
    }

    mutating func validate() throws {
        clientName = try CephStorageInput.clientName(clientName)
        storagePoolName = try Validate.name(storagePoolName, "storagePoolName")
        cephPoolName = try CephStorageInput.identifier(cephPoolName, field: "cephPoolName")
        namespace = try CephStorageInput.identifier(namespace, field: "namespace")
        if let keyring {
            try CephStorageInput.projectKeyring(
                keyring, clientName: clientName, pool: cephPoolName, namespace: namespace)
        }
    }
}

private enum CephStorageInput {
    static func fsid(_ raw: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let id = UUID(uuidString: trimmed) else {
            throw Abort(.badRequest, reason: "'fsid' must be a UUID")
        }
        return id.uuidString.lowercased()
    }

    static func monEndpoints(_ raw: [String]) throws -> [String] {
        try Validate.stringList(raw, "monEndpoints", maxEntries: 32, maxLength: 255)
        var seen = Set<String>()
        var endpoints: [String] = []
        for value in raw {
            let endpoint = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !endpoint.isEmpty,
                endpoint.rangeOfCharacter(from: .whitespacesAndNewlines) == nil
            else {
                throw Abort(
                    .badRequest, reason: "Each 'monEndpoints' entry must be a nonempty endpoint without whitespace")
            }
            try validateMessengerV2Endpoint(endpoint)
            if seen.insert(endpoint).inserted { endpoints.append(endpoint) }
        }
        guard !endpoints.isEmpty else {
            throw Abort(.badRequest, reason: "'monEndpoints' must contain at least one endpoint")
        }
        return endpoints
    }

    private static func validateMessengerV2Endpoint(_ endpoint: String) throws {
        guard endpoint.hasPrefix("v2:") else {
            throw Abort(.badRequest, reason: "Each monitor endpoint must use msgr2 syntax 'v2:host:port'")
        }
        let address = endpoint.dropFirst(3)
        let host: Substring
        let portText: Substring
        if address.first == "[" {
            guard let close = address.firstIndex(of: "]"),
                address.index(after: close) < address.endIndex,
                address[address.index(after: close)] == ":"
            else {
                throw Abort(.badRequest, reason: "IPv6 monitor endpoints must use 'v2:[address]:port'")
            }
            host = address[address.index(after: address.startIndex)..<close]
            portText = address[address.index(close, offsetBy: 2)...]
            guard host.contains(":"),
                host.allSatisfy({ $0.isHexDigit || $0 == ":" || $0 == "." || $0 == "%" })
            else {
                throw Abort(.badRequest, reason: "IPv6 monitor endpoints must contain a bracketed IPv6 address")
            }
        } else {
            guard let colon = address.lastIndex(of: ":"), colon != address.startIndex,
                !address[..<colon].contains(":")
            else {
                throw Abort(.badRequest, reason: "Each monitor endpoint must use 'v2:host:port'")
            }
            host = address[..<colon]
            portText = address[address.index(after: colon)...]
            guard
                host.allSatisfy({
                    $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_"
                })
            else {
                throw Abort(.badRequest, reason: "Monitor host names contain an invalid character")
            }
        }
        guard !host.isEmpty, let port = UInt16(portText), port > 0 else {
            throw Abort(.badRequest, reason: "Each monitor endpoint must contain a host and port from 1 through 65535")
        }
    }

    static func clientName(_ raw: String) throws -> String {
        let name = try Validate.name(raw, "clientName")
        guard name.hasPrefix("client."), name.count > "client.".count else {
            throw Abort(.badRequest, reason: "'clientName' must begin with 'client.'")
        }
        _ = try identifier(String(name.dropFirst("client.".count)), field: "clientName")
        return name
    }

    static func keyring(_ value: String, clientName: String) throws {
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw Abort(.badRequest, reason: "'keyring' must not be empty")
        }
        try Validate.text(value, "keyring")
        var sections: [String] = []
        var keyValues: [String] = []
        var currentSection: String?
        for rawLine in value.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("["), line.hasSuffix("]") {
                let section = String(line.dropFirst().dropLast())
                sections.append(section)
                currentSection = section
                continue
            }
            guard currentSection == clientName,
                let equals = line.firstIndex(of: "=")
            else { continue }
            let field = String(line[..<equals]).trimmingCharacters(in: .whitespaces)
            if field == "key" {
                keyValues.append(String(line[line.index(after: equals)...]).trimmingCharacters(in: .whitespaces))
            }
        }
        guard sections == [clientName], keyValues.count == 1, !keyValues[0].isEmpty else {
            throw Abort(
                .badRequest,
                reason: "'keyring' must contain exactly one [\(clientName)] section and one nonempty key entry")
        }
    }

    /// A project credential must be the output of `ceph auth get`, including
    /// the server-side authority operators configured for it. The key alone
    /// proves identity but says nothing about tenant isolation; requiring one
    /// exact namespace-scoped OSD profile rejects pool-wide and multi-cap
    /// credentials before they can be distributed to an agent.
    static func projectKeyring(
        _ value: String, clientName: String, pool: String, namespace: String
    ) throws {
        try keyring(value, clientName: clientName)
        var currentSection: String?
        var caps: [String: [String]] = [:]
        for rawLine in value.split(whereSeparator: \Character.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("["), line.hasSuffix("]") {
                currentSection = String(line.dropFirst().dropLast())
                continue
            }
            guard currentSection == clientName, let equals = line.firstIndex(of: "=") else {
                continue
            }
            let field = String(line[..<equals]).trimmingCharacters(in: .whitespaces)
            if field.hasPrefix("caps "),
                field != "caps mon" && field != "caps mgr" && field != "caps osd"
            {
                throw Abort(
                    .badRequest,
                    reason:
                        "The project keyring may contain capability entries only for mon, mgr, and osd"
                )
            }
            guard field == "caps mon" || field == "caps mgr" || field == "caps osd" else {
                continue
            }
            let rawCap = String(line[line.index(after: equals)...])
                .trimmingCharacters(in: .whitespaces)
            guard rawCap.count >= 2, rawCap.first == "\"", rawCap.last == "\"" else {
                throw Abort(
                    .badRequest,
                    reason: "The project keyring's '\(field)' value must be quoted")
            }
            caps[field, default: []].append(String(rawCap.dropFirst().dropLast()))
        }
        let expectedScoped = "profile rbd pool=\(pool) namespace=\(namespace)"
        guard caps["caps mon"] == ["profile rbd"],
            caps["caps mgr"] == [expectedScoped],
            caps["caps osd"] == [expectedScoped]
        else {
            throw Abort(
                .badRequest,
                reason:
                    "The project keyring must contain exactly one 'caps mon = \"profile rbd\"', "
                    + "'caps mgr = \"\(expectedScoped)\"', and "
                    + "'caps osd = \"\(expectedScoped)\"' entry"
            )
        }
    }

    static func identifier(_ raw: String, field: String) throws -> String {
        let value = try Validate.name(raw, field)
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        let firstAllowed = CharacterSet.alphanumerics
        guard let first = value.unicodeScalars.first,
            firstAllowed.contains(first),
            value.unicodeScalars.allSatisfy(allowed.contains)
        else {
            throw Abort(
                .badRequest,
                reason:
                    "'\(field)' must start with a letter or number and contain only letters, numbers, '.', '_' or '-'"
            )
        }
        return value
    }
}

/// Registration and tenant access for bring-your-own Ceph clusters. Secret
/// material is accepted only on writes and is never represented by a response
/// field or a read route.
struct CephStorageController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let cluster = routes.grouped("api", "sites", ":siteId", "ceph-cluster")
        cluster.get(use: getCluster)
        cluster.post(use: createCluster)
        cluster.put(use: updateCluster)
        cluster.delete(use: deleteCluster)

        let access = cluster.grouped("projects", ":projectID")
        access.get(use: getProjectAccess)
        access.put(use: upsertProjectAccess)
        access.delete(use: deleteProjectAccess)

        routes.grouped("api", "projects", ":projectID", "storage-pools")
            .get(use: listProjectStoragePools)
    }

    // MARK: Cluster registration

    func getCluster(req: Request) async throws -> CephClusterResponse {
        let site = try await requireSite(req)
        try await requireSiteAction("site:read", site: site, req: req)
        return CephClusterResponse(from: try await requireCluster(in: site, on: req.db))
    }

    func createCluster(req: Request) async throws -> Response {
        let site = try await requireSite(req)
        try await requireSiteAction("site:manage", site: site, req: req)
        let siteID = try site.requireID()
        let input = try req.content.decodeValidated(CreateExternalCephClusterRequest.self)
        try requireEncryptedCredentialStorage(req)

        guard try await CephCluster.query(on: req.db).filter(\.$site.$id == siteID).first() == nil else {
            throw Abort(.conflict, reason: "This site already has a Ceph cluster")
        }
        guard try await CephCluster.query(on: req.db).filter(\.$fsid == input.fsid).first() == nil else {
            throw Abort(.conflict, reason: "Ceph cluster FSID is already registered")
        }
        let encryptedKeyring = try req.secretsEncryption.encrypt(input.keyring)

        let created: CephCluster
        do {
            created = try await req.db.transaction { db -> CephCluster in
                let secret = StoredSecret(
                    purpose: .cephClusterObserverKeyring,
                    encryptedValue: encryptedKeyring)
                try await secret.save(on: db)
                let cluster = CephCluster(
                    siteID: siteID,
                    fsid: input.fsid,
                    monEndpoints: input.monEndpoints,
                    clientName: input.clientName,
                    keyringSecretRef: try secret.requireID())
                try await cluster.save(on: db)
                return cluster
            }
        } catch let error as any DatabaseError where error.isConstraintFailure {
            throw Abort(.conflict, reason: "This site or Ceph cluster FSID is already registered")
        }

        let response = Response(status: .created)
        try response.content.encode(CephClusterResponse(from: created))
        return response
    }

    func updateCluster(req: Request) async throws -> CephClusterResponse {
        let site = try await requireSite(req)
        try await requireSiteAction("site:manage", site: site, req: req)
        let existing = try await requireCluster(in: site, on: req.db)
        let input = try req.content.decodeValidated(UpdateExternalCephClusterRequest.self)
        if input.keyring != nil {
            try requireEncryptedCredentialStorage(req)
        }
        guard input.clientName == existing.clientName || input.keyring != nil else {
            throw Abort(.badRequest, reason: "Changing 'clientName' also requires a replacement 'keyring'")
        }
        let encryptedKeyring = try input.keyring.map { try req.secretsEncryption.encrypt($0) }
        let clusterID = try existing.requireID()

        return try await req.db.transaction { db in
            let cluster = try await lockCluster(clusterID, on: db)
            if input.monEndpoints != cluster.monEndpoints {
                let poolIDs = try await StoragePool.query(on: db)
                    .filter(\.$cephCluster.$id == clusterID)
                    .all(\.$id)
                let volumeCount =
                    poolIDs.isEmpty
                    ? 0
                    : try await Volume.query(on: db)
                        .filter(\.$pool.$id ~~ poolIDs)
                        .count()
                guard volumeCount == 0 else {
                    throw Abort(
                        .conflict,
                        reason:
                            "Ceph monitor endpoints cannot change while the cluster has volumes"
                    )
                }
            }
            if input.clientName != cluster.clientName {
                let usedByProject = try await CephProjectAccess.query(on: db)
                    .filter(\.$cluster.$id == clusterID)
                    .filter(\.$clientName == input.clientName).first()
                guard usedByProject == nil else {
                    throw Abort(.conflict, reason: "Observer clientName is already assigned to a project")
                }
            }
            guard let secret = try await StoredSecret.find(cluster.$keyringSecret.id, on: db)
            else { throw Abort(.internalServerError, reason: "Ceph observer credential is missing") }
            if let encryptedKeyring { secret.encryptedValue = encryptedKeyring; try await secret.save(on: db) }
            cluster.monEndpoints = input.monEndpoints
            cluster.clientName = input.clientName
            try await cluster.save(on: db)
            return CephClusterResponse(from: cluster)
        }
    }

    func deleteCluster(req: Request) async throws -> HTTPStatus {
        let site = try await requireSite(req)
        try await requireSiteAction("site:manage", site: site, req: req)
        let cluster = try await requireCluster(in: site, on: req.db)
        let clusterID = try cluster.requireID()
        do {
            try await req.db.transaction { db in
                let current = try await lockCluster(clusterID, on: db)
                let accessCount = try await CephProjectAccess.query(on: db)
                    .filter(\.$cluster.$id == clusterID).count()
                guard accessCount == 0 else {
                    throw Abort(
                        .conflict,
                        reason: "Ceph cluster has \(accessCount) project access configuration(s); delete them first")
                }
                let secretID = current.$keyringSecret.id
                try await current.delete(on: db)
                if let secret = try await StoredSecret.find(secretID, on: db) {
                    try await secret.delete(on: db)
                }
            }
        } catch let error as any DatabaseError where error.isConstraintFailure {
            throw Abort(.conflict, reason: "Ceph cluster is still in use")
        }
        return .noContent
    }

    // MARK: Project access and pool

    func getProjectAccess(req: Request) async throws -> CephProjectAccessResponse {
        let (site, cluster, project) = try await projectContext(req, mutation: false)
        _ = site
        let access = try await requireAccess(cluster: cluster, project: project, on: req.db)
        let pool = try await requirePool(for: access, on: req.db)
        return CephProjectAccessResponse(from: access, pool: pool)
    }

    func upsertProjectAccess(req: Request) async throws -> CephProjectAccessResponse {
        let (_, cluster, project) = try await projectContext(req, mutation: true)
        let input = try req.content.decodeValidated(UpsertCephProjectAccessRequest.self)
        if input.keyring != nil {
            try requireEncryptedCredentialStorage(req)
        }
        let clusterID = try cluster.requireID()
        let projectID = try project.requireID()
        let encryptedKeyring = try input.keyring.map { try req.secretsEncryption.encrypt($0) }

        let result: (response: CephProjectAccessResponse, nudgeSiteID: UUID?)
        do {
            result = try await req.db.transaction { db in
                let currentCluster = try await lockCluster(clusterID, on: db)
                let existing = try await CephProjectAccess.query(on: db)
                    .filter(\.$cluster.$id == clusterID)
                    .filter(\.$project.$id == projectID)
                    .first()
                guard existing != nil || encryptedKeyring != nil else {
                    throw Abort(.badRequest, reason: "'keyring' is required when configuring project access")
                }
                if let existing, input.clientName != existing.clientName, encryptedKeyring == nil {
                    throw Abort(.badRequest, reason: "Changing 'clientName' also requires a replacement 'keyring'")
                }
                guard input.clientName != currentCluster.clientName else {
                    throw Abort(
                        .conflict, reason: "Project clientName must differ from the cluster observer clientName")
                }
                var clientQuery = CephProjectAccess.query(on: db)
                    .filter(\.$cluster.$id == clusterID)
                    .filter(\.$clientName == input.clientName)
                if let existingID = existing?.id {
                    clientQuery = clientQuery.filter(\.$id != existingID)
                }
                guard try await clientQuery.first() == nil else {
                    throw Abort(.conflict, reason: "Project clientName is already assigned in this Ceph cluster")
                }

                let existingPool: StoragePool?
                if let existing {
                    existingPool = try await requirePool(for: existing, on: db)
                } else {
                    existingPool = nil
                }
                let coordinatesChanged =
                    existingPool.map {
                        $0.cephPoolName != input.cephPoolName
                            || $0.cephNamespace != input.namespace
                    } ?? false
                let identityChanged = existing.map { $0.clientName != input.clientName } ?? false
                if coordinatesChanged || identityChanged {
                    guard encryptedKeyring != nil else {
                        throw Abort(
                            .badRequest,
                            reason:
                                "Changing 'clientName', 'cephPoolName', or 'namespace' also requires a replacement keyring with matching scoped caps"
                        )
                    }
                }
                let replacesCredential = existing != nil && encryptedKeyring != nil
                if let existingPool, replacesCredential || identityChanged || coordinatesChanged {
                    let volumeCount = try await Volume.query(on: db)
                        .filter(\.$pool.$id == existingPool.requireID()).count()
                    if volumeCount > 0 {
                        throw Abort(
                            .conflict,
                            reason:
                                "Ceph credentials, clientName, pool, and namespace cannot change while the storage pool has volumes"
                        )
                    }
                }
                if replacesCredential, input.cephxRevoked != true {
                    throw Abort(
                        .badRequest,
                        reason:
                            "Set 'cephxRevoked' to true after revoking the old credential in the external Ceph cluster"
                    )
                }
                try await requirePoolCoordinatesAvailable(
                    clusterID: clusterID, poolID: existingPool?.id,
                    name: input.storagePoolName, namespace: input.namespace, on: db)

                if let existing, let existingPool {
                    guard let access = try await CephProjectAccess.find(try existing.requireID(), on: db),
                        let pool = try await StoragePool.find(try existingPool.requireID(), on: db),
                        let oldSecret = try await StoredSecret.find(access.$keyringSecret.id, on: db)
                    else { throw Abort(.conflict, reason: "Ceph project access changed concurrently") }
                    if let encryptedKeyring {
                        let oldSecretID = try oldSecret.requireID()
                        let newSecret = StoredSecret(
                            purpose: .cephProjectKeyring, encryptedValue: encryptedKeyring)
                        try await newSecret.save(on: db)
                        try await recordCredentialRevocation(
                            siteID: currentCluster.$site.id, clusterID: clusterID,
                            credentialID: oldSecretID, on: db)
                        access.$keyringSecret.id = try newSecret.requireID()
                    }
                    access.clientName = input.clientName
                    pool.name = input.storagePoolName
                    pool.cephPoolName = input.cephPoolName
                    pool.cephNamespace = input.namespace
                    try await access.save(on: db)
                    try await pool.save(on: db)
                    if encryptedKeyring != nil {
                        try await oldSecret.delete(on: db)
                    }
                    return (
                        CephProjectAccessResponse(from: access, pool: pool),
                        encryptedKeyring == nil ? nil : currentCluster.$site.id
                    )
                }

                guard let encryptedKeyring else {
                    throw Abort(.badRequest, reason: "'keyring' is required when configuring project access")
                }
                let secret = StoredSecret(purpose: .cephProjectKeyring, encryptedValue: encryptedKeyring)
                try await secret.save(on: db)
                let access = CephProjectAccess(
                    clusterID: clusterID, projectID: projectID,
                    clientName: input.clientName, keyringSecretRef: try secret.requireID())
                try await access.save(on: db)
                let pool = StoragePool(
                    name: input.storagePoolName, mode: .ceph, backing: .filesystem,
                    siteID: currentCluster.$site.id, cephClusterID: clusterID,
                    cephProjectAccessID: try access.requireID(),
                    cephPoolName: input.cephPoolName, cephNamespace: input.namespace)
                try await pool.save(on: db)
                return (CephProjectAccessResponse(from: access, pool: pool), nil)
            }
        } catch let error as any DatabaseError where error.isConstraintFailure {
            throw Abort(
                .conflict,
                reason: "Ceph project access, clientName, storage-pool name, or namespace is already assigned")
        }
        if let siteID = result.nudgeSiteID {
            await nudgeSiteAgents(siteID: siteID, req: req)
        }
        return result.response
    }

    func deleteProjectAccess(req: Request) async throws -> HTTPStatus {
        guard (try? req.query.get(Bool.self, at: "cephxRevoked")) == true else {
            throw Abort(
                .badRequest,
                reason:
                    "Set query parameter 'cephxRevoked=true' after revoking the credential in the external Ceph cluster"
            )
        }
        let (_, cluster, project) = try await projectContext(req, mutation: true)
        let clusterID = try cluster.requireID()
        let projectID = try project.requireID()
        let siteID: UUID
        do {
            siteID = try await req.db.transaction { db in
                let currentCluster = try await lockCluster(clusterID, on: db)
                let access = try await requireAccess(
                    cluster: currentCluster, project: project, on: db)
                let pool = try await requirePool(for: access, on: db)
                let volumeCount = try await Volume.query(on: db)
                    .filter(\.$pool.$id == pool.requireID()).count()
                guard volumeCount == 0 else {
                    throw Abort(
                        .conflict,
                        reason: "Storage pool has \(volumeCount) volume(s); delete them first")
                }
                guard access.$project.id == projectID else {
                    throw Abort(.conflict, reason: "Ceph project access changed concurrently")
                }
                let secretID = access.$keyringSecret.id
                try await recordCredentialRevocation(
                    siteID: currentCluster.$site.id, clusterID: clusterID,
                    credentialID: secretID, on: db)
                try await pool.delete(on: db)
                try await access.delete(on: db)
                if let secret = try await StoredSecret.find(secretID, on: db) {
                    try await secret.delete(on: db)
                }
                return currentCluster.$site.id
            }
        } catch let error as any DatabaseError where error.isConstraintFailure {
            throw Abort(.conflict, reason: "Ceph project storage is still in use")
        }
        await nudgeSiteAgents(siteID: siteID, req: req)
        return .noContent
    }

    func listProjectStoragePools(req: Request) async throws -> [StoragePoolResponse] {
        let project = try await req.requireProject()
        try await OrganizationAccessService.requireProjectMember(project: project, on: req)
        let projectID = try project.requireID()
        let accessIDs = try await CephProjectAccess.query(on: req.db)
            .filter(\.$project.$id == projectID).all(\.$id)
        let cephPools =
            accessIDs.isEmpty
            ? []
            : try await StoragePool.query(on: req.db)
                .filter(\.$cephProjectAccess.$id ~~ accessIDs).sort(\.$name).all()
        return [StoragePoolResponse(from: try await StoragePool.defaultPool(on: req.db))]
            + cephPools.map(StoragePoolResponse.init(from:))
    }

    // MARK: Helpers

    /// Ceph keyrings are new secret-reference data, not a legacy plaintext
    /// column. Refuse every create or rotation unless the deployment can
    /// actually encrypt the referent at rest; metadata-only updates and reads
    /// remain available without the key.
    private func requireEncryptedCredentialStorage(_ req: Request) throws {
        guard req.secretsEncryption.isEnabled else {
            throw Abort(
                .serviceUnavailable,
                reason:
                    "STRATO_SECRET_ENCRYPTION_KEY must be configured before storing or replacing Ceph credentials"
            )
        }
    }

    private func requireSite(_ req: Request) async throws -> Site {
        guard let siteID = req.parameters.get("siteId", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid site ID")
        }
        guard let site = try await Site.find(siteID, on: req.db) else {
            throw Abort(.notFound, reason: "Site not found")
        }
        return site
    }

    private func requireSiteAction(_ action: String, site: Site, req: Request) async throws {
        guard try await req.can(action, on: IAMNode(type: .site, id: try site.requireID())) else {
            throw Abort(.forbidden, reason: "You don't have '\(action)' access on this site")
        }
    }

    private func requireCluster(in site: Site, on db: any Database) async throws -> CephCluster {
        guard
            let cluster = try await CephCluster.query(on: db)
                .filter(\.$site.$id == site.requireID()).first()
        else { throw Abort(.notFound, reason: "Ceph cluster not registered") }
        return cluster
    }

    /// Serializes observer-identity changes with project-identity changes.
    /// Their uniqueness crosses two tables, so no single SQL unique index can
    /// preserve the invariant by itself.
    private func lockCluster(_ clusterID: UUID, on db: any Database) async throws -> CephCluster {
        guard let sql = db as? any SQLDatabase else {
            throw Abort(.internalServerError, reason: "Ceph registration requires a SQL database")
        }
        _ = try await sql.raw(
            "SELECT id FROM ceph_clusters WHERE id = \(bind: clusterID) FOR UPDATE"
        ).all()
        guard let cluster = try await CephCluster.find(clusterID, on: db) else {
            throw Abort(.notFound, reason: "Ceph cluster not registered")
        }
        return cluster
    }

    private func projectContext(_ req: Request, mutation: Bool) async throws -> (Site, CephCluster, Project) {
        let site = try await requireSite(req)
        try await requireSiteAction(mutation ? "site:manage" : "site:read", site: site, req: req)
        let project = try await req.requireProject()
        if mutation {
            try await OrganizationAccessService.requireProjectPolicyAdmin(project: project, on: req)
        } else {
            try await OrganizationAccessService.requireProjectMember(project: project, on: req)
        }
        guard try await NetworkController.siteScopeContains(project: project, site: site, on: req.db) else {
            throw Abort(.conflict, reason: "Project is outside this site's organization scope")
        }
        return (site, try await requireCluster(in: site, on: req.db), project)
    }

    private func requireAccess(
        cluster: CephCluster, project: Project, on db: any Database
    ) async throws -> CephProjectAccess {
        guard
            let access = try await CephProjectAccess.query(on: db)
                .filter(\.$cluster.$id == cluster.requireID())
                .filter(\.$project.$id == project.requireID()).first()
        else { throw Abort(.notFound, reason: "Ceph access is not configured for this project") }
        return access
    }

    private func requirePool(for access: CephProjectAccess, on db: any Database) async throws -> StoragePool {
        guard
            let pool = try await StoragePool.query(on: db)
                .filter(\.$cephProjectAccess.$id == access.requireID()).first()
        else { throw Abort(.internalServerError, reason: "Ceph project access has no storage pool") }
        return pool
    }

    private func requirePoolCoordinatesAvailable(
        clusterID: UUID, poolID: UUID?, name: String, namespace: String, on db: any Database
    ) async throws {
        if let byName = try await StoragePool.query(on: db).filter(\.$name == name).first(), byName.id != poolID {
            throw Abort(.conflict, reason: "A storage pool named '\(name)' already exists")
        }
        var namespaceQuery = StoragePool.query(on: db)
            .filter(\.$cephCluster.$id == clusterID)
            .filter(\.$cephNamespace == namespace)
        if let poolID { namespaceQuery = namespaceQuery.filter(\.$id != poolID) }
        guard try await namespaceQuery.first() == nil else {
            throw Abort(.conflict, reason: "Ceph namespace '\(namespace)' is already assigned in this cluster")
        }
    }

    /// Append-only and retry-safe. The credential and even the cluster
    /// registration may be deleted after this transaction, so neither column
    /// is a foreign key; the site is the durable delivery scope.
    private func recordCredentialRevocation(
        siteID: UUID, clusterID: UUID, credentialID: UUID, on db: any Database
    ) async throws {
        guard let sql = db as? any SQLDatabase else {
            throw Abort(.internalServerError, reason: "Ceph credential revocation requires a SQL database")
        }
        try await sql.raw(
            """
            INSERT INTO ceph_credential_revocations
                (id, site_id, cluster_id, credential_id, created_at)
            VALUES
                (\(bind: UUID()), \(bind: siteID), \(bind: clusterID), \(bind: credentialID), \(bind: Date()))
            ON CONFLICT (cluster_id, credential_id) DO NOTHING
            """
        ).run()
    }

    /// Push the newly appended ledger row immediately. Periodic full-state
    /// sync remains the correctness backstop for offline and future agents.
    private func nudgeSiteAgents(siteID: UUID, req: Request) async {
        do {
            let agentIDs = try await Agent.query(on: req.db)
                .filter(\.$site.$id == siteID)
                .all(\.$id)
            for agentID in agentIDs {
                await req.application.agentService.syncDesiredState(
                    agentId: agentID.uuidString)
            }
        } catch {
            req.logger.error(
                "Failed to nudge site agents after retiring a Ceph credential: \(error)",
                metadata: ["siteId": .string(siteID.uuidString)])
        }
    }
}
