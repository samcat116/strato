import Foundation
import PostgresNIO

public struct ProjectSnapshot: Equatable, Sendable {
    public let id: UUID
    public let name: String
    public let description: String
    public let organizationID: UUID?
    public let organizationalUnitID: UUID?
    public let rootOrganizationID: UUID?
    public let path: String
    public let defaultEnvironment: String
    public let environments: [String]
    public let createdAt: Date?
    public let updatedAt: Date?
}

public struct ProjectOverview: Equatable, Sendable {
    public let project: ProjectSnapshot
    public let virtualMachineCount: Int
}

public struct ProjectStatsSnapshot: Equatable, Sendable {
    public let totalVMs: Int
    public let vmsByEnvironment: [String: Int]
    public let totalVCPUs: Int
    public let totalMemoryBytes: Int64
    public let totalStorageBytes: Int64
}

public struct ProjectCreateWrite: Sendable {
    public let id: UUID
    public let name: String
    public let description: String
    public let organizationID: UUID?
    public let organizationalUnitID: UUID?
    public let defaultEnvironment: String
    public let environments: [String]
    public let creatorID: UUID?
    public let administratorRoleID: UUID

    public init(
        id: UUID = UUID(),
        name: String,
        description: String,
        organizationID: UUID?,
        organizationalUnitID: UUID?,
        defaultEnvironment: String,
        environments: [String],
        creatorID: UUID?,
        administratorRoleID: UUID
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.organizationID = organizationID
        self.organizationalUnitID = organizationalUnitID
        self.defaultEnvironment = defaultEnvironment
        self.environments = environments
        self.creatorID = creatorID
        self.administratorRoleID = administratorRoleID
    }
}

public enum ProjectCreateResult: Equatable, Sendable {
    case created(ProjectSnapshot)
    case invalidScope
    case organizationNotFound
    case organizationalUnitNotFound
    case duplicateName
}

public enum ProjectEnvironmentMutationResult: Equatable, Sendable {
    case updated(ProjectOverview)
    case notFound
    case inUseByVirtualMachines
    case inUseBySandboxes
    case cannotRemove
}

public struct ProjectMetadataWrite: Sendable {
    public let id: UUID
    public let name: String
    public let description: String
    public let defaultEnvironment: String
    public let environments: [String]

    public init(
        id: UUID,
        name: String,
        description: String,
        defaultEnvironment: String,
        environments: [String]
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.defaultEnvironment = defaultEnvironment
        self.environments = environments
    }
}

public enum ProjectMetadataUpdateResult: Equatable, Sendable {
    case updated(ProjectOverview)
    case notFound
    case duplicateName
    case environmentsInUseByVirtualMachines([String])
    case environmentsInUseBySandboxes([String])
}

public struct ProjectTransferWrite: Sendable {
    public let project: ProjectMetadataWrite
    public let organizationID: UUID?
    public let organizationalUnitID: UUID?

    public init(
        project: ProjectMetadataWrite,
        organizationID: UUID?,
        organizationalUnitID: UUID?
    ) {
        self.project = project
        self.organizationID = organizationID
        self.organizationalUnitID = organizationalUnitID
    }
}

public enum ProjectTransferResult: Equatable, Sendable {
    case updated(ProjectOverview)
    case notFound
    case invalidDestination
    case organizationNotFound
    case organizationalUnitNotFound
    case duplicateName
    case environmentsInUseByVirtualMachines([String])
    case environmentsInUseBySandboxes([String])
    case networkQuotaExceeded(name: String, limit: Int)
    case loadBalancerQuotaExceeded(name: String, limit: Int)
}

/// Owns project hierarchy and lifecycle behavior. It starts with the identity
/// lookup used by project-scoped modules and grows with the project API cohort.
public struct ProjectsPersistence: Sendable {
    private let database: PostgresDatabase

    init(database: PostgresDatabase) {
        self.database = database
    }

    public func project(id: UUID) async throws -> ProjectSnapshot? {
        try await database.withSession(operation: "projects.lookup") { session in
            let rows = try await session.execute(
                FindProject(id: id),
                operation: "projects.lookup.query"
            )
            guard rows.count <= 1 else {
                throw ProjectsPersistenceError.unexpectedRowCount(
                    expected: 1,
                    actual: rows.count
                )
            }
            return rows.first
        }
    }

    public func projectOverview(id: UUID) async throws -> ProjectOverview? {
        try await database.withSession(operation: "projects.overview") { session in
            let rows = try await session.execute(
                FindProjectOverview(id: id),
                operation: "projects.overview.query"
            )
            guard rows.count <= 1 else {
                throw ProjectsPersistenceError.unexpectedRowCount(
                    expected: 1,
                    actual: rows.count
                )
            }
            return rows.first
        }
    }

    public func allProjectOverviews() async throws -> [ProjectOverview] {
        try await database.withSession(operation: "projects.list") { session in
            try await session.execute(
                ListProjectOverviews(),
                operation: "projects.list.query"
            )
        }
    }

    public func projectOverviews(ids: [UUID]) async throws -> [ProjectOverview] {
        guard !ids.isEmpty else { return [] }
        return try await database.withSession(operation: "projects.list_scoped") { session in
            try await session.execute(
                ListSelectedProjectOverviews(ids: Array(Set(ids))),
                operation: "projects.list_scoped.query"
            )
        }
    }

    public func projectOverviews(organizationalUnitID: UUID) async throws
        -> [ProjectOverview]
    {
        try await database.withSession(operation: "projects.list_for_folder") { session in
            try await session.execute(
                ListOrganizationalUnitProjectOverviews(organizationalUnitID: organizationalUnitID),
                operation: "projects.list_for_folder.query"
            )
        }
    }

    public func stats(project: ProjectSnapshot) async throws -> ProjectStatsSnapshot {
        try await database.withSession(operation: "projects.stats") { session in
            let totalRows = try await session.execute(
                ProjectVMResourceTotals(projectID: project.id),
                operation: "projects.stats.totals"
            )
            guard totalRows.count == 1, let totals = totalRows.first else {
                throw ProjectsPersistenceError.unexpectedRowCount(
                    expected: 1,
                    actual: totalRows.count
                )
            }
            let counts = try await session.execute(
                ProjectVMEnvironmentCounts(projectID: project.id),
                operation: "projects.stats.environments"
            )
            var byEnvironment = Dictionary(
                uniqueKeysWithValues: project.environments.map { ($0, 0) })
            for count in counts {
                byEnvironment[count.environment] = count.count
            }
            return ProjectStatsSnapshot(
                totalVMs: totals.count,
                vmsByEnvironment: byEnvironment,
                totalVCPUs: totals.vcpus,
                totalMemoryBytes: totals.memoryBytes,
                totalStorageBytes: totals.storageBytes
            )
        }
    }

    /// Creates the project, its creator-admin binding, and the complete default
    /// security-group graph in one transaction.
    public func create(_ write: ProjectCreateWrite) async throws -> ProjectCreateResult {
        guard (write.organizationID == nil) != (write.organizationalUnitID == nil) else {
            return .invalidScope
        }
        do {
            return try await database.withTransaction(operation: "projects.create") { session in
                let parentPath: String
                if let organizationID = write.organizationID {
                    let rows = try await session.execute(
                        FindProjectOrganizationPath(id: organizationID),
                        operation: "projects.create.organization"
                    )
                    guard rows.count <= 1 else {
                        throw ProjectsPersistenceError.unexpectedRowCount(
                            expected: 1, actual: rows.count)
                    }
                    guard let path = rows.first else { return .organizationNotFound }
                    parentPath = path
                } else if let organizationalUnitID = write.organizationalUnitID {
                    let rows = try await session.execute(
                        FindProjectOrganizationalUnitPath(id: organizationalUnitID),
                        operation: "projects.create.folder"
                    )
                    guard rows.count <= 1 else {
                        throw ProjectsPersistenceError.unexpectedRowCount(
                            expected: 1, actual: rows.count)
                    }
                    guard let path = rows.first else { return .organizationalUnitNotFound }
                    parentPath = path
                } else {
                    return .invalidScope
                }

                let path = "\(parentPath)/\(write.id.uuidString)"
                _ = try await session.execute(
                    InsertProject(write: write, path: path),
                    operation: "projects.create.project"
                )
                if let creatorID = write.creatorID {
                    _ = try await session.execute(
                        InsertProjectCreatorBinding(
                            id: UUID(),
                            creatorID: creatorID,
                            projectID: write.id,
                            administratorRoleID: write.administratorRoleID
                        ),
                        operation: "projects.create.binding"
                    )
                }
                let groupID = UUID()
                _ = try await session.execute(
                    InsertProjectDefaultSecurityGroup(id: groupID, projectID: write.id),
                    operation: "projects.create.default_group"
                )
                for ethertype in ["ipv4", "ipv6"] {
                    _ = try await session.execute(
                        InsertProjectDefaultSecurityGroupRule(
                            id: UUID(), groupID: groupID,
                            direction: "ingress", ethertype: ethertype,
                            remoteGroupID: groupID
                        ),
                        operation: "projects.create.default_group.ingress"
                    )
                    _ = try await session.execute(
                        InsertProjectDefaultSecurityGroupRule(
                            id: UUID(), groupID: groupID,
                            direction: "egress", ethertype: ethertype,
                            remoteGroupID: nil
                        ),
                        operation: "projects.create.default_group.egress"
                    )
                }
                let projects = try await session.execute(
                    FindProject(id: write.id),
                    operation: "projects.create.reload"
                )
                guard projects.count == 1, let project = projects.first else {
                    throw ProjectsPersistenceError.unexpectedRowCount(
                        expected: 1, actual: projects.count)
                }
                return .created(project)
            }
        } catch let error as PSQLError
            where error.serverInfo?[.sqlState] == "23505"
                && [
                    "uq:projects.organization_id+projects.name",
                    "uq:projects.organizational_unit_id+projects.name",
                ].contains(error.serverInfo?[.constraintName])
        {
            return .duplicateName
        }
    }

    public func addEnvironment(projectID: UUID, environment: String) async throws
        -> ProjectEnvironmentMutationResult
    {
        try await database.withTransaction(operation: "projects.environments.add") { session in
            guard
                let project = try oneProject(
                    await session.execute(
                        LockProject(id: projectID),
                        operation: "projects.environments.add.lock"
                    )
                )
            else { return .notFound }
            if !project.environments.contains(environment) {
                _ = try await session.execute(
                    SetProjectEnvironments(
                        id: projectID,
                        environments: project.environments + [environment]
                    ),
                    operation: "projects.environments.add.update"
                )
            }
            return .updated(try await requireOverview(projectID, session: session))
        }
    }

    public func removeEnvironment(projectID: UUID, environment: String) async throws
        -> ProjectEnvironmentMutationResult
    {
        try await database.withTransaction(operation: "projects.environments.remove") { session in
            guard
                let project = try oneProject(
                    await session.execute(
                        LockProject(id: projectID),
                        operation: "projects.environments.remove.lock"
                    )
                )
            else { return .notFound }
            if try await count(
                ProjectVirtualMachinesInEnvironment(
                    projectID: projectID, environment: environment),
                session: session,
                operation: "projects.environments.remove.virtual_machines"
            ) > 0 {
                return .inUseByVirtualMachines
            }
            if try await count(
                ProjectSandboxesInEnvironment(
                    projectID: projectID, environment: environment),
                session: session,
                operation: "projects.environments.remove.sandboxes"
            ) > 0 {
                return .inUseBySandboxes
            }
            guard environment != project.defaultEnvironment,
                project.environments.contains(environment)
            else { return .cannotRemove }
            _ = try await session.execute(
                SetProjectEnvironments(
                    id: projectID,
                    environments: project.environments.filter { $0 != environment }
                ),
                operation: "projects.environments.remove.update"
            )
            return .updated(try await requireOverview(projectID, session: session))
        }
    }

    public func updateMetadata(_ write: ProjectMetadataWrite) async throws
        -> ProjectMetadataUpdateResult
    {
        do {
            return try await database.withTransaction(operation: "projects.update_metadata") { session in
                guard
                    let current = try oneProject(
                        await session.execute(
                            LockProject(id: write.id),
                            operation: "projects.update_metadata.lock"
                        )
                    )
                else { return .notFound }
                let removed = Array(Set(current.environments).subtracting(write.environments))
                if !removed.isEmpty {
                    if try await count(
                        ProjectVirtualMachinesInEnvironments(
                            projectID: write.id, environments: removed),
                        session: session,
                        operation: "projects.update_metadata.virtual_machines"
                    ) > 0 {
                        return .environmentsInUseByVirtualMachines(removed)
                    }
                    if try await count(
                        ProjectSandboxesInEnvironments(
                            projectID: write.id, environments: removed),
                        session: session,
                        operation: "projects.update_metadata.sandboxes"
                    ) > 0 {
                        return .environmentsInUseBySandboxes(removed)
                    }
                }
                _ = try await session.execute(
                    UpdateProjectMetadata(write: write),
                    operation: "projects.update_metadata.update"
                )
                return .updated(try await requireOverview(write.id, session: session))
            }
        } catch let error as PSQLError
            where error.serverInfo?[.sqlState] == "23505"
                && [
                    "uq:projects.organization_id+projects.name",
                    "uq:projects.organizational_unit_id+projects.name",
                ].contains(error.serverInfo?[.constraintName])
        {
            return .duplicateName
        }
    }

    /// Moves a project and refreshes every affected project-wide quota while
    /// holding the same project and quota advisory locks as network admission.
    public func transfer(_ write: ProjectTransferWrite) async throws -> ProjectTransferResult {
        guard (write.organizationID == nil) != (write.organizationalUnitID == nil) else {
            return .invalidDestination
        }
        do {
            return try await database.withTransaction(operation: "projects.transfer") { session in
                _ = try await session.execute(
                    LockProjectNetworkMutations(id: write.project.id),
                    operation: "projects.transfer.project_advisory_lock"
                )
                guard
                    let current = try oneProject(
                        await session.execute(
                            LockProject(id: write.project.id),
                            operation: "projects.transfer.lock"
                        )
                    )
                else { return .notFound }

                let removed = Array(Set(current.environments).subtracting(write.project.environments))
                if !removed.isEmpty {
                    if try await count(
                        ProjectVirtualMachinesInEnvironments(
                            projectID: write.project.id, environments: removed),
                        session: session,
                        operation: "projects.transfer.virtual_machines"
                    ) > 0 {
                        return .environmentsInUseByVirtualMachines(removed)
                    }
                    if try await count(
                        ProjectSandboxesInEnvironments(
                            projectID: write.project.id, environments: removed),
                        session: session,
                        operation: "projects.transfer.sandboxes"
                    ) > 0 {
                        return .environmentsInUseBySandboxes(removed)
                    }
                }

                let destination: ProjectTransferDestination
                if let organizationID = write.organizationID {
                    let rows = try await session.execute(
                        FindProjectTransferOrganization(id: organizationID),
                        operation: "projects.transfer.organization"
                    )
                    guard rows.count <= 1 else {
                        throw ProjectsPersistenceError.unexpectedRowCount(
                            expected: 1, actual: rows.count)
                    }
                    guard let found = rows.first else { return .organizationNotFound }
                    destination = found
                } else if let organizationalUnitID = write.organizationalUnitID {
                    let rows = try await session.execute(
                        FindProjectTransferOrganizationalUnit(id: organizationalUnitID),
                        operation: "projects.transfer.folder"
                    )
                    guard rows.count <= 1 else {
                        throw ProjectsPersistenceError.unexpectedRowCount(
                            expected: 1, actual: rows.count)
                    }
                    guard let found = rows.first else { return .organizationalUnitNotFound }
                    destination = found
                } else {
                    return .invalidDestination
                }

                let sourceAncestorIDs = try await organizationalUnitAncestorIDs(
                    current.organizationalUnitID, session: session)
                let destinationAncestorIDs = try await organizationalUnitAncestorIDs(
                    destination.organizationalUnitID, session: session)
                let sourceQuotas = try await session.execute(
                    FindApplicableProjectWideQuotas(
                        projectID: current.id,
                        organizationID: current.rootOrganizationID,
                        organizationalUnitIDs: sourceAncestorIDs
                    ),
                    operation: "projects.transfer.source_quotas"
                )
                let destinationQuotas = try await session.execute(
                    FindApplicableProjectWideQuotas(
                        projectID: current.id,
                        organizationID: destination.rootOrganizationID,
                        organizationalUnitIDs: destinationAncestorIDs
                    ),
                    operation: "projects.transfer.destination_quotas"
                )
                var affectedByID: [UUID: ResourceQuotaSnapshot] = [:]
                for quota in sourceQuotas + destinationQuotas { affectedByID[quota.id] = quota }
                for id in affectedByID.keys.sorted(by: { $0.uuidString < $1.uuidString }) {
                    _ = try await session.execute(
                        LockProjectQuota(id: id),
                        operation: "projects.transfer.quota_advisory_lock"
                    )
                }

                let networkCount = try await count(
                    CountProjectNetworks(projectID: current.id), session: session,
                    operation: "projects.transfer.network_count")
                let loadBalancerCount = try await count(
                    CountProjectLoadBalancers(projectID: current.id), session: session,
                    operation: "projects.transfer.load_balancer_count")
                let sourceIDs = Set(sourceQuotas.map(\.id))
                for quota in destinationQuotas where !sourceIDs.contains(quota.id) {
                    let usage = try await measure(quota, session: session)
                    if quota.isEnabled {
                        let (incomingNetworks, networkOverflow) = usage.networkCount
                            .addingReportingOverflow(networkCount)
                        if networkOverflow || incomingNetworks > quota.maxNetworks {
                            return .networkQuotaExceeded(
                                name: quota.name, limit: quota.maxNetworks)
                        }
                        let (incomingLoadBalancers, loadBalancerOverflow) = usage.loadBalancerCount
                            .addingReportingOverflow(loadBalancerCount)
                        if loadBalancerOverflow || incomingLoadBalancers > quota.maxLoadBalancers {
                            return .loadBalancerQuotaExceeded(
                                name: quota.name, limit: quota.maxLoadBalancers)
                        }
                    }
                }

                _ = try await session.execute(
                    TransferProject(
                        write: write,
                        path: "\(destination.parentPath)/\(write.project.id.uuidString)"
                    ),
                    operation: "projects.transfer.update"
                )
                for quota in affectedByID.values {
                    let usage = try await measure(quota, session: session)
                    _ = try await session.execute(
                        UpdateProjectTransferQuota(id: quota.id, usage: usage),
                        operation: "projects.transfer.resync_quota"
                    )
                }
                return .updated(try await requireOverview(write.project.id, session: session))
            }
        } catch let error as PSQLError
            where error.serverInfo?[.sqlState] == "23505"
                && [
                    "uq:projects.organization_id+projects.name",
                    "uq:projects.organizational_unit_id+projects.name",
                ].contains(error.serverInfo?[.constraintName])
        {
            return .duplicateName
        }
    }

    private func organizationalUnitAncestorIDs(
        _ id: UUID?, session: PostgresSession
    ) async throws -> [UUID] {
        guard let id else { return [] }
        return try await session.execute(
            FindProjectOrganizationalUnitAncestorIDs(id: id),
            operation: "projects.transfer.folder_ancestors"
        )
    }

    private func measure(
        _ quota: ResourceQuotaSnapshot, session: PostgresSession
    ) async throws -> ResourceQuotaMeasuredUsage {
        let rows = try await session.execute(
            MeasureResourceQuotaScope(scope: .init(quota)),
            operation: "projects.transfer.measure_quota"
        )
        guard rows.count == 1, let usage = rows.first else {
            throw ProjectsPersistenceError.unexpectedRowCount(
                expected: 1, actual: rows.count)
        }
        return usage
    }

    private func requireOverview(_ id: UUID, session: PostgresSession) async throws
        -> ProjectOverview
    {
        let rows = try await session.execute(
            FindProjectOverview(id: id), operation: "projects.overview.reload")
        guard rows.count == 1, let overview = rows.first else {
            throw ProjectsPersistenceError.unexpectedRowCount(
                expected: 1, actual: rows.count)
        }
        return overview
    }

    private func oneProject(_ rows: [ProjectSnapshot]) throws -> ProjectSnapshot? {
        guard rows.count <= 1 else {
            throw ProjectsPersistenceError.unexpectedRowCount(
                expected: 1, actual: rows.count)
        }
        return rows.first
    }

    private func count<Statement: PostgresPreparedStatement>(
        _ statement: Statement,
        session: PostgresSession,
        operation: PostgresOperation
    ) async throws -> Int where Statement.Row == Int {
        let rows = try await session.execute(statement, operation: operation)
        guard rows.count == 1, let value = rows.first else {
            throw ProjectsPersistenceError.unexpectedRowCount(
                expected: 1, actual: rows.count)
        }
        return value
    }

    public func candidateProjectIDs(
        organizationIDs: [UUID],
        organizationalUnitIDs: [UUID],
        projectIDs: [UUID]
    ) async throws -> [UUID] {
        guard !organizationIDs.isEmpty || !organizationalUnitIDs.isEmpty || !projectIDs.isEmpty else {
            return []
        }
        return try await database.withSession(operation: "projects.visibility.candidates") { session in
            try await session.execute(
                FindCandidateProjectIDs(
                    organizationIDs: Array(Set(organizationIDs)),
                    organizationalUnitIDs: Array(Set(organizationalUnitIDs)),
                    projectIDs: Array(Set(projectIDs))
                ),
                operation: "projects.visibility.candidates.query"
            )
        }
    }
}

public enum ProjectsPersistenceError: Error, Equatable, Sendable {
    case unexpectedRowCount(expected: Int, actual: Int)
}

private let projectColumns = """
    p.id, p.name, p.description, p.organization_id, p.organizational_unit_id,
    COALESCE(p.organization_id, folder.organization_id) AS root_organization_id,
    p.path, p.default_environment, p.environments, p.created_at, p.updated_at
    """

private protocol ProjectStatement: PostgresPreparedStatement where Row == ProjectSnapshot {}

private extension ProjectStatement {
    func decodeRow(_ row: PostgresRow) throws -> ProjectSnapshot {
        let value = try row.decode(
            (UUID, String, String, UUID?, UUID?, UUID?, String, String, [String], Date?, Date?).self
        )
        return ProjectSnapshot(
            id: value.0,
            name: value.1,
            description: value.2,
            organizationID: value.3,
            organizationalUnitID: value.4,
            rootOrganizationID: value.5,
            path: value.6,
            defaultEnvironment: value.7,
            environments: value.8,
            createdAt: value.9,
            updatedAt: value.10
        )
    }
}

private struct FindProject: ProjectStatement {
    static let sql = """
        SELECT \(projectColumns)
        FROM projects AS p
        LEFT JOIN organizational_units AS folder ON folder.id = p.organizational_unit_id
        WHERE p.id = $1
        """
    let id: UUID
    func makeBindings() throws -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 1)
        bindings.append(id)
        return bindings
    }
}

private struct LockProject: ProjectStatement {
    static let sql = """
        SELECT \(projectColumns)
        FROM projects AS p
        LEFT JOIN organizational_units AS folder ON folder.id = p.organizational_unit_id
        WHERE p.id = $1
        FOR UPDATE OF p
        """
    let id: UUID
    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 1)
        bindings.append(id)
        return bindings
    }
}

private struct FindCandidateProjectIDs: PostgresPreparedStatement {
    static let sql = """
        WITH selected_folders AS (
            SELECT candidate.id
            FROM organizational_units AS candidate
            WHERE candidate.organization_id = ANY($1::uuid[])
               OR EXISTS (
                    SELECT 1 FROM organizational_units AS root
                    WHERE root.id = ANY($2::uuid[])
                      AND (candidate.path = root.path OR candidate.path LIKE root.path || '/%')
               )
        )
        SELECT id
        FROM projects
        WHERE organization_id = ANY($1::uuid[])
           OR organizational_unit_id IN (SELECT id FROM selected_folders)
           OR id = ANY($3::uuid[])
        ORDER BY id
        """
    typealias Row = UUID
    let organizationIDs: [UUID]
    let organizationalUnitIDs: [UUID]
    let projectIDs: [UUID]
    func makeBindings() throws -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 3)
        bindings.append(organizationIDs)
        bindings.append(organizationalUnitIDs)
        bindings.append(projectIDs)
        return bindings
    }
    func decodeRow(_ row: PostgresRow) throws -> UUID { try row.decode(UUID.self) }
}

private struct FindProjectOrganizationPath: PostgresPreparedStatement {
    static let sql = "SELECT '/' || id::text FROM organizations WHERE id = $1"
    typealias Row = String
    let id: UUID
    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 1)
        bindings.append(id)
        return bindings
    }
    func decodeRow(_ row: PostgresRow) throws -> String { try row.decode(String.self) }
}

private struct FindProjectOrganizationalUnitPath: PostgresPreparedStatement {
    static let sql = "SELECT path FROM organizational_units WHERE id = $1"
    typealias Row = String
    let id: UUID
    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 1)
        bindings.append(id)
        return bindings
    }
    func decodeRow(_ row: PostgresRow) throws -> String { try row.decode(String.self) }
}

private struct ProjectTransferDestination: Sendable {
    let organizationID: UUID?
    let organizationalUnitID: UUID?
    let rootOrganizationID: UUID
    let parentPath: String
}

private struct FindProjectTransferOrganization: PostgresPreparedStatement {
    static let sql = "SELECT id, '/' || id::text FROM organizations WHERE id = $1"
    typealias Row = ProjectTransferDestination
    let id: UUID
    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 1)
        bindings.append(id)
        return bindings
    }
    func decodeRow(_ row: PostgresRow) throws -> ProjectTransferDestination {
        let value = try row.decode((UUID, String).self)
        return ProjectTransferDestination(
            organizationID: value.0,
            organizationalUnitID: nil,
            rootOrganizationID: value.0,
            parentPath: value.1
        )
    }
}

private struct FindProjectTransferOrganizationalUnit: PostgresPreparedStatement {
    static let sql = "SELECT id, organization_id, path FROM organizational_units WHERE id = $1"
    typealias Row = ProjectTransferDestination
    let id: UUID
    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 1)
        bindings.append(id)
        return bindings
    }
    func decodeRow(_ row: PostgresRow) throws -> ProjectTransferDestination {
        let value = try row.decode((UUID, UUID, String).self)
        return ProjectTransferDestination(
            organizationID: nil,
            organizationalUnitID: value.0,
            rootOrganizationID: value.1,
            parentPath: value.2
        )
    }
}

private struct FindProjectOrganizationalUnitAncestorIDs: PostgresPreparedStatement {
    static let sql = """
        SELECT ancestor.id
        FROM organizational_units AS root
        JOIN organizational_units AS ancestor
          ON root.path = ancestor.path OR root.path LIKE ancestor.path || '/%'
        WHERE root.id = $1
        ORDER BY ancestor.depth, ancestor.id
        """
    typealias Row = UUID
    let id: UUID
    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 1)
        bindings.append(id)
        return bindings
    }
    func decodeRow(_ row: PostgresRow) throws -> UUID { try row.decode(UUID.self) }
}

private struct FindApplicableProjectWideQuotas: ResourceQuotaStatement {
    static let sql = """
        SELECT \(resourceQuotaColumns)
        FROM resource_quotas
        WHERE environment IS NULL AND (
            project_id = $1
            OR ($2::uuid IS NOT NULL AND organization_id = $2)
            OR organizational_unit_id = ANY($3::uuid[])
        )
        ORDER BY id
        """
    let projectID: UUID
    let organizationID: UUID?
    let organizationalUnitIDs: [UUID]
    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 3)
        bindings.append(projectID)
        bindings.append(organizationID)
        bindings.append(organizationalUnitIDs)
        return bindings
    }
}

private struct LockProjectNetworkMutations: PostgresPreparedStatement {
    static let sql = "SELECT pg_advisory_xact_lock(hashtext($1))"
    typealias Row = Void
    let id: UUID
    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 1)
        bindings.append("project-network:\(id.uuidString)")
        return bindings
    }
    func decodeRow(_ row: PostgresRow) throws {}
}

private struct LockProjectQuota: PostgresPreparedStatement {
    static let sql = "SELECT pg_advisory_xact_lock(hashtext($1))"
    typealias Row = Void
    let id: UUID
    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 1)
        bindings.append(id.uuidString)
        return bindings
    }
    func decodeRow(_ row: PostgresRow) throws {}
}

private struct InsertProject: PostgresPreparedStatement {
    static let sql = """
        INSERT INTO projects (
            id, name, description, organization_id, organizational_unit_id, path,
            default_environment, environments, created_at, updated_at
        ) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
        RETURNING id
        """
    typealias Row = UUID
    let write: ProjectCreateWrite
    let path: String
    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 8)
        bindings.append(write.id)
        bindings.append(write.name)
        bindings.append(write.description)
        bindings.append(write.organizationID)
        bindings.append(write.organizationalUnitID)
        bindings.append(path)
        bindings.append(write.defaultEnvironment)
        bindings.append(write.environments)
        return bindings
    }
    func decodeRow(_ row: PostgresRow) throws -> UUID { try row.decode(UUID.self) }
}

private struct InsertProjectCreatorBinding: PostgresPreparedStatement {
    static let sql = """
        INSERT INTO role_bindings (
            id, principal_type, principal_id, role_id, node_type, node_id,
            condition, expires_at, created_by, created_at
        ) VALUES ($1, 'user', $2, $3, 'project', $4, NULL, NULL, $2, CURRENT_TIMESTAMP)
        RETURNING id
        """
    typealias Row = UUID
    let id: UUID
    let creatorID: UUID
    let projectID: UUID
    let administratorRoleID: UUID
    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 4)
        bindings.append(id)
        bindings.append(creatorID)
        bindings.append(administratorRoleID)
        bindings.append(projectID)
        return bindings
    }
    func decodeRow(_ row: PostgresRow) throws -> UUID { try row.decode(UUID.self) }
}

private struct InsertProjectDefaultSecurityGroup: PostgresPreparedStatement {
    static let sql = """
        INSERT INTO security_groups (
            id, project_id, name, description, is_default, generation,
            created_by_id, created_at, updated_at
        ) VALUES ($1, $2, 'default', 'Default security group', true, 0, NULL,
                  CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
        RETURNING id
        """
    typealias Row = UUID
    let id: UUID
    let projectID: UUID
    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 2)
        bindings.append(id)
        bindings.append(projectID)
        return bindings
    }
    func decodeRow(_ row: PostgresRow) throws -> UUID { try row.decode(UUID.self) }
}

private struct InsertProjectDefaultSecurityGroupRule: PostgresPreparedStatement {
    static let sql = """
        INSERT INTO security_group_rules (
            id, security_group_id, direction, ethertype, protocol,
            port_range_min, port_range_max, remote_cidr, remote_group_id,
            log, description, created_at
        ) VALUES ($1, $2, $3, $4, NULL, NULL, NULL, NULL, $5, false, NULL,
                  CURRENT_TIMESTAMP)
        RETURNING id
        """
    typealias Row = UUID
    let id: UUID
    let groupID: UUID
    let direction: String
    let ethertype: String
    let remoteGroupID: UUID?
    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 5)
        bindings.append(id)
        bindings.append(groupID)
        bindings.append(direction)
        bindings.append(ethertype)
        bindings.append(remoteGroupID)
        return bindings
    }
    func decodeRow(_ row: PostgresRow) throws -> UUID { try row.decode(UUID.self) }
}

private struct SetProjectEnvironments: PostgresPreparedStatement {
    static let sql = """
        UPDATE projects
        SET environments = $2, updated_at = CURRENT_TIMESTAMP
        WHERE id = $1
        RETURNING id
        """
    typealias Row = UUID
    let id: UUID
    let environments: [String]
    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 2)
        bindings.append(id)
        bindings.append(environments)
        return bindings
    }
    func decodeRow(_ row: PostgresRow) throws -> UUID { try row.decode(UUID.self) }
}

private struct UpdateProjectMetadata: PostgresPreparedStatement {
    static let sql = """
        UPDATE projects
        SET name = $2, description = $3, default_environment = $4,
            environments = $5, updated_at = CURRENT_TIMESTAMP
        WHERE id = $1
        RETURNING id
        """
    typealias Row = UUID
    let write: ProjectMetadataWrite
    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 5)
        bindings.append(write.id)
        bindings.append(write.name)
        bindings.append(write.description)
        bindings.append(write.defaultEnvironment)
        bindings.append(write.environments)
        return bindings
    }
    func decodeRow(_ row: PostgresRow) throws -> UUID { try row.decode(UUID.self) }
}

private struct TransferProject: PostgresPreparedStatement {
    static let sql = """
        UPDATE projects
        SET name = $2, description = $3, organization_id = $4,
            organizational_unit_id = $5, path = $6,
            default_environment = $7, environments = $8,
            updated_at = CURRENT_TIMESTAMP
        WHERE id = $1
        RETURNING id
        """
    typealias Row = UUID
    let write: ProjectTransferWrite
    let path: String
    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 8)
        bindings.append(write.project.id)
        bindings.append(write.project.name)
        bindings.append(write.project.description)
        bindings.append(write.organizationID)
        bindings.append(write.organizationalUnitID)
        bindings.append(path)
        bindings.append(write.project.defaultEnvironment)
        bindings.append(write.project.environments)
        return bindings
    }
    func decodeRow(_ row: PostgresRow) throws -> UUID { try row.decode(UUID.self) }
}

private struct CountProjectNetworks: PostgresPreparedStatement {
    static let sql = "SELECT count(*)::bigint FROM logical_networks WHERE project_id = $1"
    typealias Row = Int
    let projectID: UUID
    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 1)
        bindings.append(projectID)
        return bindings
    }
    func decodeRow(_ row: PostgresRow) throws -> Int { try row.decode(Int.self) }
}

private struct CountProjectLoadBalancers: PostgresPreparedStatement {
    static let sql = "SELECT count(*)::bigint FROM load_balancers WHERE project_id = $1"
    typealias Row = Int
    let projectID: UUID
    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 1)
        bindings.append(projectID)
        return bindings
    }
    func decodeRow(_ row: PostgresRow) throws -> Int { try row.decode(Int.self) }
}

private struct UpdateProjectTransferQuota: PostgresPreparedStatement {
    static let sql = """
        UPDATE resource_quotas
        SET reserved_vcpus = $2, reserved_memory = $3, reserved_storage = $4,
            vm_count = $5, sandbox_count = $6, volume_count = $7,
            network_count = $8, load_balancer_count = $9,
            updated_at = CURRENT_TIMESTAMP
        WHERE id = $1
        RETURNING id
        """
    typealias Row = UUID
    let id: UUID
    let usage: ResourceQuotaMeasuredUsage
    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 9)
        bindings.append(id)
        bindings.append(usage.vcpus)
        bindings.append(usage.memoryBytes)
        bindings.append(usage.storageBytes)
        bindings.append(usage.vmCount)
        bindings.append(usage.sandboxCount)
        bindings.append(usage.volumeCount)
        bindings.append(usage.networkCount)
        bindings.append(usage.loadBalancerCount)
        return bindings
    }
    func decodeRow(_ row: PostgresRow) throws -> UUID { try row.decode(UUID.self) }
}

private struct ProjectVirtualMachinesInEnvironment: PostgresPreparedStatement {
    static let sql = "SELECT count(*)::bigint FROM vms WHERE project_id = $1 AND environment = $2"
    typealias Row = Int
    let projectID: UUID
    let environment: String
    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 2)
        bindings.append(projectID)
        bindings.append(environment)
        return bindings
    }
    func decodeRow(_ row: PostgresRow) throws -> Int { try row.decode(Int.self) }
}

private struct ProjectSandboxesInEnvironment: PostgresPreparedStatement {
    static let sql = "SELECT count(*)::bigint FROM sandboxes WHERE project_id = $1 AND environment = $2"
    typealias Row = Int
    let projectID: UUID
    let environment: String
    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 2)
        bindings.append(projectID)
        bindings.append(environment)
        return bindings
    }
    func decodeRow(_ row: PostgresRow) throws -> Int { try row.decode(Int.self) }
}


private struct ProjectVirtualMachinesInEnvironments: PostgresPreparedStatement {
    static let sql = "SELECT count(*)::bigint FROM vms WHERE project_id = $1 AND environment = ANY($2::text[])"
    typealias Row = Int
    let projectID: UUID
    let environments: [String]
    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 2)
        bindings.append(projectID)
        bindings.append(environments)
        return bindings
    }
    func decodeRow(_ row: PostgresRow) throws -> Int { try row.decode(Int.self) }
}

private struct ProjectSandboxesInEnvironments: PostgresPreparedStatement {
    static let sql = "SELECT count(*)::bigint FROM sandboxes WHERE project_id = $1 AND environment = ANY($2::text[])"
    typealias Row = Int
    let projectID: UUID
    let environments: [String]
    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 2)
        bindings.append(projectID)
        bindings.append(environments)
        return bindings
    }
    func decodeRow(_ row: PostgresRow) throws -> Int { try row.decode(Int.self) }
}

private let projectOverviewColumns = """
    \(projectColumns),
    (SELECT count(*)::bigint FROM vms WHERE project_id = p.id) AS virtual_machine_count
    """

private protocol ProjectOverviewStatement: PostgresPreparedStatement
    where Row == ProjectOverview {}

private extension ProjectOverviewStatement {
    func decodeRow(_ row: PostgresRow) throws -> ProjectOverview {
        let value = try row.decode((
            UUID, String, String, UUID?, UUID?, UUID?, String, String, [String],
            Date?, Date?, Int
        ).self)
        return ProjectOverview(
            project: ProjectSnapshot(
                id: value.0,
                name: value.1,
                description: value.2,
                organizationID: value.3,
                organizationalUnitID: value.4,
                rootOrganizationID: value.5,
                path: value.6,
                defaultEnvironment: value.7,
                environments: value.8,
                createdAt: value.9,
                updatedAt: value.10
            ),
            virtualMachineCount: value.11
        )
    }
}

private struct FindProjectOverview: ProjectOverviewStatement {
    static var sql: String {
        """
        SELECT \(projectOverviewColumns)
        FROM projects AS p
        LEFT JOIN organizational_units AS folder ON folder.id = p.organizational_unit_id
        WHERE p.id = $1
        """
    }
    let id: UUID
    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 1)
        bindings.append(id)
        return bindings
    }
}

private struct ListProjectOverviews: ProjectOverviewStatement {
    static var sql: String {
        """
        SELECT \(projectOverviewColumns)
        FROM projects AS p
        LEFT JOIN organizational_units AS folder ON folder.id = p.organizational_unit_id
        ORDER BY p.name, p.id
        """
    }
    func makeBindings() -> PostgresBindings { PostgresBindings() }
}

private struct ListSelectedProjectOverviews: ProjectOverviewStatement {
    static var sql: String {
        """
        SELECT \(projectOverviewColumns)
        FROM projects AS p
        LEFT JOIN organizational_units AS folder ON folder.id = p.organizational_unit_id
        WHERE p.id = ANY($1::uuid[])
        ORDER BY p.name, p.id
        """
    }
    let ids: [UUID]
    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 1)
        bindings.append(ids)
        return bindings
    }
}

private struct ListOrganizationalUnitProjectOverviews: ProjectOverviewStatement {
    static var sql: String {
        """
        SELECT \(projectOverviewColumns)
        FROM projects AS p
        LEFT JOIN organizational_units AS folder ON folder.id = p.organizational_unit_id
        WHERE p.organizational_unit_id = $1
        ORDER BY p.name, p.id
        """
    }
    let organizationalUnitID: UUID
    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 1)
        bindings.append(organizationalUnitID)
        return bindings
    }
}

private struct ProjectVMResourceTotals: PostgresPreparedStatement {
    static let sql = """
        SELECT count(*)::bigint, COALESCE(sum(cpu), 0)::bigint,
               COALESCE(sum(memory), 0)::bigint, COALESCE(sum(disk), 0)::bigint
        FROM vms
        WHERE project_id = $1
        """
    struct Row: Sendable {
        let count: Int
        let vcpus: Int
        let memoryBytes: Int64
        let storageBytes: Int64
    }
    let projectID: UUID
    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 1)
        bindings.append(projectID)
        return bindings
    }
    func decodeRow(_ row: PostgresRow) throws -> Row {
        let value = try row.decode((Int, Int, Int64, Int64).self)
        return Row(
            count: value.0,
            vcpus: value.1,
            memoryBytes: value.2,
            storageBytes: value.3
        )
    }
}

private struct ProjectVMEnvironmentCounts: PostgresPreparedStatement {
    static let sql = """
        SELECT environment, count(*)::bigint
        FROM vms
        WHERE project_id = $1
        GROUP BY environment
        ORDER BY environment
        """
    struct Row: Sendable {
        let environment: String
        let count: Int
    }
    let projectID: UUID
    func makeBindings() -> PostgresBindings {
        var bindings = PostgresBindings(capacity: 1)
        bindings.append(projectID)
        return bindings
    }
    func decodeRow(_ row: PostgresRow) throws -> Row {
        let value = try row.decode((String, Int).self)
        return Row(environment: value.0, count: value.1)
    }
}
