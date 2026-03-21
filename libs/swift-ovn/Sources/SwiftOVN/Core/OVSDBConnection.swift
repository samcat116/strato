import Foundation
import NIO
import Logging

public final class OVSDBConnection {
    private let client: JSONRPCClient
    private let logger: Logger
    private var activeMonitors: Set<String> = []
    private let monitorLock = NSLock()
    
    public init(socketPath: String, eventLoopGroup: EventLoopGroup? = nil, logger: Logger? = nil) {
        self.client = JSONRPCClient(
            socketPath: socketPath,
            eventLoopGroup: eventLoopGroup,
            logger: logger
        )
        self.logger = logger ?? Logger(label: "ovn-manager.ovsdb-connection")
    }
    
    public func connect() async throws {
        try await client.connect()
        logger.info("Connected to OVSDB")
    }
    
    public func disconnect() async throws {
        // Cancel all active monitors
        for monitorId in activeMonitors {
            try? await client.cancelMonitor(monitorId: monitorId)
        }
        activeMonitors.removeAll()
        
        try await client.disconnect()
        logger.info("Disconnected from OVSDB")
    }
    
    public var isConnected: Bool {
        return client.isConnected
    }
    
    // MARK: - Database Operations
    
    public func listDatabases() async throws -> [String] {
        logger.debug("Listing databases")
        return try await client.listDatabases()
    }
    
    public func getDatabaseSchema(database: String) async throws -> JSONValue {
        logger.debug("Getting schema for database: \(database)")
        return try await client.getSchema(database: database)
    }
    
    // MARK: - Table Operations
    
    public func selectAll(from table: String, in database: String, columns: [String]? = nil) async throws -> [OVSDBRow] {
        let operation = OVSDBOperation(
            op: "select",
            table: table,
            columns: columns
        )
        
        let results = try await client.transact(database: database, operations: [operation])
        
        guard let firstResult = results.first,
              case .object(let resultObject) = firstResult,
              let rows = resultObject["rows"],
              case .array(let rowsArray) = rows else {
            throw OVNManagerError.invalidResponse("Invalid select response format")
        }
        
        return try rowsArray.map { jsonValue in
            guard case .object(let rowObject) = jsonValue else {
                throw OVNManagerError.invalidResponse("Invalid row format")
            }
            return rowObject
        }
    }
    
    public func select(
        from table: String,
        in database: String,
        where conditions: [OVSDBCondition],
        columns: [String]? = nil
    ) async throws -> [OVSDBRow] {
        let operation = OVSDBOperation(
            op: "select",
            table: table,
            whereConditions: conditions,
            columns: columns
        )
        
        let results = try await client.transact(database: database, operations: [operation])
        
        guard let firstResult = results.first,
              case .object(let resultObject) = firstResult,
              let rows = resultObject["rows"],
              case .array(let rowsArray) = rows else {
            throw OVNManagerError.invalidResponse("Invalid select response format")
        }
        
        return try rowsArray.map { jsonValue in
            guard case .object(let rowObject) = jsonValue else {
                throw OVNManagerError.invalidResponse("Invalid row format")
            }
            return rowObject
        }
    }
    
    public func insert(into table: String, in database: String, row: OVSDBRow) async throws -> JSONValue {
        let operation = OVSDBOperation(
            op: "insert",
            table: table,
            row: row
        )
        
        let results = try await client.transact(database: database, operations: [operation])
        
        guard let firstResult = results.first else {
            throw OVNManagerError.invalidResponse("No result from insert operation")
        }
        
        return firstResult
    }
    
    public func update(
        table: String,
        in database: String,
        where conditions: [OVSDBCondition],
        row: OVSDBRow
    ) async throws -> Int {
        let operation = OVSDBOperation(
            op: "update",
            table: table,
            whereConditions: conditions,
            row: row
        )
        
        let results = try await client.transact(database: database, operations: [operation])
        
        guard let firstResult = results.first,
              case .object(let resultObject) = firstResult,
              let count = resultObject["count"],
              case .number(let countValue) = count else {
            throw OVNManagerError.invalidResponse("Invalid update response format")
        }
        
        return Int(countValue)
    }
    
    public func delete(
        from table: String,
        in database: String,
        where conditions: [OVSDBCondition]
    ) async throws -> Int {
        let operation = OVSDBOperation(
            op: "delete",
            table: table,
            whereConditions: conditions
        )
        
        let results = try await client.transact(database: database, operations: [operation])
        
        guard let firstResult = results.first,
              case .object(let resultObject) = firstResult,
              let count = resultObject["count"],
              case .number(let countValue) = count else {
            throw OVNManagerError.invalidResponse("Invalid delete response format")
        }
        
        return Int(countValue)
    }
    
    public func mutate(
        table: String,
        in database: String,
        where conditions: [OVSDBCondition],
        mutations: [OVSDBMutation]
    ) async throws -> Int {
        let operation = OVSDBOperation(
            op: "mutate",
            table: table,
            whereConditions: conditions,
            mutations: mutations
        )
        
        let results = try await client.transact(database: database, operations: [operation])
        
        guard let firstResult = results.first,
              case .object(let resultObject) = firstResult,
              let count = resultObject["count"],
              case .number(let countValue) = count else {
            throw OVNManagerError.invalidResponse("Invalid mutate response format")
        }
        
        return Int(countValue)
    }
    
    // MARK: - Monitoring
    
    public func startMonitoring(
        database: String,
        tables: [String: OVSDBMonitorRequest],
        monitorId: String? = nil
    ) async throws -> String {
        let id = monitorId ?? UUID().uuidString
        
        let initialState = try await client.monitor(
            database: database,
            monitorId: id,
            requests: tables
        )
        
        monitorLock.lock()
        activeMonitors.insert(id)
        monitorLock.unlock()
        
        logger.info("Started monitoring database \(database) with ID: \(id)")
        
        return id
    }
    
    public func stopMonitoring(monitorId: String) async throws {
        try await client.cancelMonitor(monitorId: monitorId)
        
        monitorLock.lock()
        activeMonitors.remove(monitorId)
        monitorLock.unlock()
        
        logger.info("Stopped monitoring with ID: \(monitorId)")
    }
    
    public func monitorUpdates() -> AsyncThrowingStream<OVSDBUpdate, Error> {
        let clientStream = client.monitorUpdates()
        
        return AsyncThrowingStream { continuation in
            Task {
                do {
                    for try await (monitorId, updateValue) in clientStream {
                        // Parse the update value into OVSDBUpdate format
                        if case .object(let updateObject) = updateValue {
                            for (tableName, tableUpdate) in updateObject {
                                if case .object(let tableUpdateObject) = tableUpdate {
                                    for (rowId, rowUpdate) in tableUpdateObject {
                                        if case .object(let rowUpdateObject) = rowUpdate {
                                            let old = rowUpdateObject["old"].flatMap { value in
                                                if case .object(let obj) = value { return obj }
                                                return nil
                                            }
                                            let new = rowUpdateObject["new"].flatMap { value in
                                                if case .object(let obj) = value { return obj }
                                                return nil
                                            }
                                            
                                            let update = OVSDBUpdate(old: old, new: new)
                                            continuation.yield(update)
                                        }
                                    }
                                }
                            }
                        }
                    }
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
}