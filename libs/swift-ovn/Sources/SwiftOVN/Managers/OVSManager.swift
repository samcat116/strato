import Foundation
import NIO
import Logging

public final class OVSManager: OVSManaging {
    private let connection: OVSDBConnection
    private let logger: Logger
    private let database: String
    
    public init(socketPath: String, database: String = OVSDatabase.openVSwitch, eventLoopGroup: EventLoopGroup? = nil, logger: Logger? = nil) {
        self.connection = OVSDBConnection(
            socketPath: socketPath,
            eventLoopGroup: eventLoopGroup,
            logger: logger
        )
        self.database = database
        self.logger = logger ?? Logger(label: "ovn-manager.ovs")
    }
    
    // MARK: - Connection Management
    
    public func connect() async throws {
        try await connection.connect()
        logger.info("Connected to OVS database: \(database)")
    }
    
    public func disconnect() async throws {
        try await connection.disconnect()
        logger.info("Disconnected from OVS database")
    }
    
    public var isConnected: Bool {
        return connection.isConnected
    }
    
    // MARK: - Database Operations
    
    public func listDatabases() async throws -> [String] {
        return try await connection.listDatabases()
    }
    
    public func getDatabaseSchema(database: String) async throws -> JSONValue {
        return try await connection.getDatabaseSchema(database: database)
    }
    
    // MARK: - Bridge Operations
    
    public func getBridges() async throws -> [OVSBridge] {
        let rows = try await connection.selectAll(from: OVSTable.bridge, in: database)
        return try rows.compactMap { row in
            try parseRow(row, as: OVSBridge.self)
        }
    }
    
    public func getBridge(named name: String) async throws -> OVSBridge? {
        let condition = OVSDBCondition(column: "name", function: "==", value: .string(name))
        let rows = try await connection.select(from: OVSTable.bridge, in: database, where: [condition])
        
        guard let firstRow = rows.first else { return nil }
        return try parseRow(firstRow, as: OVSBridge.self)
    }
    
    public func createBridge(_ bridge: OVSBridge) async throws -> String {
        let row = try createRow(from: bridge)
        let result = try await connection.insert(into: OVSTable.bridge, in: database, row: row)
        
        guard case .object(let resultObject) = result,
              let uuid = resultObject["uuid"],
              case .array(let uuidArray) = uuid,
              uuidArray.count == 2,
              case .string(let uuidValue) = uuidArray[1] else {
            throw OVNManagerError.invalidResponse("Invalid UUID in insert response")
        }
        
        logger.info("Created bridge: \(bridge.name)")
        return uuidValue
    }
    
    public func updateBridge(uuid: String, _ bridge: OVSBridge) async throws {
        let condition = OVSDBCondition(column: "_uuid", function: "==", value: .array([.string("uuid"), .string(uuid)]))
        let row = try createRow(from: bridge)
        
        let count = try await connection.update(table: OVSTable.bridge, in: database, where: [condition], row: row)
        
        if count == 0 {
            throw OVNManagerError.operationFailed("Bridge not found: \(uuid)")
        }
        
        logger.info("Updated bridge: \(bridge.name)")
    }
    
    public func deleteBridge(uuid: String) async throws {
        let condition = OVSDBCondition(column: "_uuid", function: "==", value: .array([.string("uuid"), .string(uuid)]))
        let count = try await connection.delete(from: OVSTable.bridge, in: database, where: [condition])
        
        if count == 0 {
            throw OVNManagerError.operationFailed("Bridge not found: \(uuid)")
        }
        
        logger.info("Deleted bridge: \(uuid)")
    }
    
    public func deleteBridge(named name: String) async throws {
        let condition = OVSDBCondition(column: "name", function: "==", value: .string(name))
        let count = try await connection.delete(from: OVSTable.bridge, in: database, where: [condition])
        
        if count == 0 {
            throw OVNManagerError.operationFailed("Bridge not found: \(name)")
        }
        
        logger.info("Deleted bridge: \(name)")
    }
    
    // MARK: - Port Operations
    
    public func getPorts() async throws -> [OVSPort] {
        let rows = try await connection.selectAll(from: OVSTable.port, in: database)
        return try rows.compactMap { row in
            try parseRow(row, as: OVSPort.self)
        }
    }
    
    public func getPort(named name: String) async throws -> OVSPort? {
        let condition = OVSDBCondition(column: "name", function: "==", value: .string(name))
        let rows = try await connection.select(from: OVSTable.port, in: database, where: [condition])
        
        guard let firstRow = rows.first else { return nil }
        return try parseRow(firstRow, as: OVSPort.self)
    }
    
    public func createPort(_ port: OVSPort) async throws -> String {
        let row = try createRow(from: port)
        let result = try await connection.insert(into: OVSTable.port, in: database, row: row)
        
        guard case .object(let resultObject) = result,
              let uuid = resultObject["uuid"],
              case .array(let uuidArray) = uuid,
              uuidArray.count == 2,
              case .string(let uuidValue) = uuidArray[1] else {
            throw OVNManagerError.invalidResponse("Invalid UUID in insert response")
        }
        
        logger.info("Created port: \(port.name)")
        return uuidValue
    }
    
    public func updatePort(uuid: String, _ port: OVSPort) async throws {
        let condition = OVSDBCondition(column: "_uuid", function: "==", value: .array([.string("uuid"), .string(uuid)]))
        let row = try createRow(from: port)
        
        let count = try await connection.update(table: OVSTable.port, in: database, where: [condition], row: row)
        
        if count == 0 {
            throw OVNManagerError.operationFailed("Port not found: \(uuid)")
        }
        
        logger.info("Updated port: \(port.name)")
    }
    
    public func deletePort(uuid: String) async throws {
        let condition = OVSDBCondition(column: "_uuid", function: "==", value: .array([.string("uuid"), .string(uuid)]))
        let count = try await connection.delete(from: OVSTable.port, in: database, where: [condition])
        
        if count == 0 {
            throw OVNManagerError.operationFailed("Port not found: \(uuid)")
        }
        
        logger.info("Deleted port: \(uuid)")
    }
    
    public func deletePort(named name: String) async throws {
        let condition = OVSDBCondition(column: "name", function: "==", value: .string(name))
        let count = try await connection.delete(from: OVSTable.port, in: database, where: [condition])
        
        if count == 0 {
            throw OVNManagerError.operationFailed("Port not found: \(name)")
        }
        
        logger.info("Deleted port: \(name)")
    }
    
    // MARK: - Interface Operations
    
    public func getInterfaces() async throws -> [OVSInterface] {
        let rows = try await connection.selectAll(from: OVSTable.interface, in: database)
        return try rows.compactMap { row in
            try parseRow(row, as: OVSInterface.self)
        }
    }
    
    public func getInterface(named name: String) async throws -> OVSInterface? {
        let condition = OVSDBCondition(column: "name", function: "==", value: .string(name))
        let rows = try await connection.select(from: OVSTable.interface, in: database, where: [condition])
        
        guard let firstRow = rows.first else { return nil }
        return try parseRow(firstRow, as: OVSInterface.self)
    }
    
    public func createInterface(_ interface: OVSInterface) async throws -> String {
        let row = try createRow(from: interface)
        let result = try await connection.insert(into: OVSTable.interface, in: database, row: row)
        
        guard case .object(let resultObject) = result,
              let uuid = resultObject["uuid"],
              case .array(let uuidArray) = uuid,
              uuidArray.count == 2,
              case .string(let uuidValue) = uuidArray[1] else {
            throw OVNManagerError.invalidResponse("Invalid UUID in insert response")
        }
        
        logger.info("Created interface: \(interface.name)")
        return uuidValue
    }
    
    public func updateInterface(uuid: String, _ interface: OVSInterface) async throws {
        let condition = OVSDBCondition(column: "_uuid", function: "==", value: .array([.string("uuid"), .string(uuid)]))
        let row = try createRow(from: interface)
        
        let count = try await connection.update(table: OVSTable.interface, in: database, where: [condition], row: row)
        
        if count == 0 {
            throw OVNManagerError.operationFailed("Interface not found: \(uuid)")
        }
        
        logger.info("Updated interface: \(interface.name)")
    }
    
    public func deleteInterface(uuid: String) async throws {
        let condition = OVSDBCondition(column: "_uuid", function: "==", value: .array([.string("uuid"), .string(uuid)]))
        let count = try await connection.delete(from: OVSTable.interface, in: database, where: [condition])
        
        if count == 0 {
            throw OVNManagerError.operationFailed("Interface not found: \(uuid)")
        }
        
        logger.info("Deleted interface: \(uuid)")
    }
    
    public func deleteInterface(named name: String) async throws {
        let condition = OVSDBCondition(column: "name", function: "==", value: .string(name))
        let count = try await connection.delete(from: OVSTable.interface, in: database, where: [condition])
        
        if count == 0 {
            throw OVNManagerError.operationFailed("Interface not found: \(name)")
        }
        
        logger.info("Deleted interface: \(name)")
    }
    
    // MARK: - Controller Operations
    
    public func getControllers() async throws -> [OVSController] {
        let rows = try await connection.selectAll(from: OVSTable.controller, in: database)
        return try rows.compactMap { row in
            try parseRow(row, as: OVSController.self)
        }
    }
    
    public func getController(target: String) async throws -> OVSController? {
        let condition = OVSDBCondition(column: "target", function: "==", value: .string(target))
        let rows = try await connection.select(from: OVSTable.controller, in: database, where: [condition])
        
        guard let firstRow = rows.first else { return nil }
        return try parseRow(firstRow, as: OVSController.self)
    }
    
    public func createController(_ controller: OVSController) async throws -> String {
        let row = try createRow(from: controller)
        let result = try await connection.insert(into: OVSTable.controller, in: database, row: row)
        
        guard case .object(let resultObject) = result,
              let uuid = resultObject["uuid"],
              case .array(let uuidArray) = uuid,
              uuidArray.count == 2,
              case .string(let uuidValue) = uuidArray[1] else {
            throw OVNManagerError.invalidResponse("Invalid UUID in insert response")
        }
        
        logger.info("Created controller: \(controller.target)")
        return uuidValue
    }
    
    public func updateController(uuid: String, _ controller: OVSController) async throws {
        let condition = OVSDBCondition(column: "_uuid", function: "==", value: .array([.string("uuid"), .string(uuid)]))
        let row = try createRow(from: controller)
        
        let count = try await connection.update(table: OVSTable.controller, in: database, where: [condition], row: row)
        
        if count == 0 {
            throw OVNManagerError.operationFailed("Controller not found: \(uuid)")
        }
        
        logger.info("Updated controller: \(controller.target)")
    }
    
    public func deleteController(uuid: String) async throws {
        let condition = OVSDBCondition(column: "_uuid", function: "==", value: .array([.string("uuid"), .string(uuid)]))
        let count = try await connection.delete(from: OVSTable.controller, in: database, where: [condition])
        
        if count == 0 {
            throw OVNManagerError.operationFailed("Controller not found: \(uuid)")
        }
        
        logger.info("Deleted controller: \(uuid)")
    }
    
    public func deleteController(target: String) async throws {
        let condition = OVSDBCondition(column: "target", function: "==", value: .string(target))
        let count = try await connection.delete(from: OVSTable.controller, in: database, where: [condition])
        
        if count == 0 {
            throw OVNManagerError.operationFailed("Controller not found: \(target)")
        }
        
        logger.info("Deleted controller: \(target)")
    }
    
    // MARK: - Flow Operations (Note: These would typically use ovs-ofctl commands, not OVSDB)
    
    public func getFlows(bridge: String, table: Int? = nil) async throws -> [OVSFlow] {
        // This is a simplified implementation
        // In practice, you'd use ovs-ofctl dump-flows command
        logger.warning("Flow operations typically require ovs-ofctl commands, not OVSDB")
        return []
    }
    
    public func addFlow(bridge: String, flow: OVSFlow) async throws {
        // This would typically use ovs-ofctl add-flow command
        logger.warning("Flow operations typically require ovs-ofctl commands, not OVSDB")
        throw OVNManagerError.operationFailed("Flow operations not implemented via OVSDB")
    }
    
    public func deleteFlow(bridge: String, flow: OVSFlow) async throws {
        // This would typically use ovs-ofctl del-flows command
        logger.warning("Flow operations typically require ovs-ofctl commands, not OVSDB")
        throw OVNManagerError.operationFailed("Flow operations not implemented via OVSDB")
    }
    
    public func deleteAllFlows(bridge: String) async throws {
        // This would typically use ovs-ofctl del-flows command
        logger.warning("Flow operations typically require ovs-ofctl commands, not OVSDB")
        throw OVNManagerError.operationFailed("Flow operations not implemented via OVSDB")
    }
    
    public func modifyFlow(bridge: String, flow: OVSFlow) async throws {
        // This would typically use ovs-ofctl mod-flows command
        logger.warning("Flow operations typically require ovs-ofctl commands, not OVSDB")
        throw OVNManagerError.operationFailed("Flow operations not implemented via OVSDB")
    }
    
    // MARK: - Mirror Operations
    
    public func getMirrors() async throws -> [OVSMirror] {
        let rows = try await connection.selectAll(from: OVSTable.mirror, in: database)
        return try rows.compactMap { row in
            try parseRow(row, as: OVSMirror.self)
        }
    }
    
    public func getMirror(named name: String) async throws -> OVSMirror? {
        let condition = OVSDBCondition(column: "name", function: "==", value: .string(name))
        let rows = try await connection.select(from: OVSTable.mirror, in: database, where: [condition])
        
        guard let firstRow = rows.first else { return nil }
        return try parseRow(firstRow, as: OVSMirror.self)
    }
    
    public func createMirror(_ mirror: OVSMirror) async throws -> String {
        let row = try createRow(from: mirror)
        let result = try await connection.insert(into: OVSTable.mirror, in: database, row: row)
        
        guard case .object(let resultObject) = result,
              let uuid = resultObject["uuid"],
              case .array(let uuidArray) = uuid,
              uuidArray.count == 2,
              case .string(let uuidValue) = uuidArray[1] else {
            throw OVNManagerError.invalidResponse("Invalid UUID in insert response")
        }
        
        logger.info("Created mirror: \(mirror.name)")
        return uuidValue
    }
    
    public func updateMirror(uuid: String, _ mirror: OVSMirror) async throws {
        let condition = OVSDBCondition(column: "_uuid", function: "==", value: .array([.string("uuid"), .string(uuid)]))
        let row = try createRow(from: mirror)
        
        let count = try await connection.update(table: OVSTable.mirror, in: database, where: [condition], row: row)
        
        if count == 0 {
            throw OVNManagerError.operationFailed("Mirror not found: \(uuid)")
        }
        
        logger.info("Updated mirror: \(mirror.name)")
    }
    
    public func deleteMirror(uuid: String) async throws {
        let condition = OVSDBCondition(column: "_uuid", function: "==", value: .array([.string("uuid"), .string(uuid)]))
        let count = try await connection.delete(from: OVSTable.mirror, in: database, where: [condition])
        
        if count == 0 {
            throw OVNManagerError.operationFailed("Mirror not found: \(uuid)")
        }
        
        logger.info("Deleted mirror: \(uuid)")
    }
    
    public func deleteMirror(named name: String) async throws {
        let condition = OVSDBCondition(column: "name", function: "==", value: .string(name))
        let count = try await connection.delete(from: OVSTable.mirror, in: database, where: [condition])
        
        if count == 0 {
            throw OVNManagerError.operationFailed("Mirror not found: \(name)")
        }
        
        logger.info("Deleted mirror: \(name)")
    }
    
    // MARK: - NetFlow Operations
    
    public func getNetFlows() async throws -> [OVSNetFlow] {
        let rows = try await connection.selectAll(from: OVSTable.netflow, in: database)
        return try rows.compactMap { row in
            try parseRow(row, as: OVSNetFlow.self)
        }
    }
    
    public func createNetFlow(_ netflow: OVSNetFlow) async throws -> String {
        let row = try createRow(from: netflow)
        let result = try await connection.insert(into: OVSTable.netflow, in: database, row: row)
        
        guard case .object(let resultObject) = result,
              let uuid = resultObject["uuid"],
              case .array(let uuidArray) = uuid,
              uuidArray.count == 2,
              case .string(let uuidValue) = uuidArray[1] else {
            throw OVNManagerError.invalidResponse("Invalid UUID in insert response")
        }
        
        logger.info("Created NetFlow")
        return uuidValue
    }
    
    public func updateNetFlow(uuid: String, _ netflow: OVSNetFlow) async throws {
        let condition = OVSDBCondition(column: "_uuid", function: "==", value: .array([.string("uuid"), .string(uuid)]))
        let row = try createRow(from: netflow)
        
        let count = try await connection.update(table: OVSTable.netflow, in: database, where: [condition], row: row)
        
        if count == 0 {
            throw OVNManagerError.operationFailed("NetFlow not found: \(uuid)")
        }
        
        logger.info("Updated NetFlow: \(uuid)")
    }
    
    public func deleteNetFlow(uuid: String) async throws {
        let condition = OVSDBCondition(column: "_uuid", function: "==", value: .array([.string("uuid"), .string(uuid)]))
        let count = try await connection.delete(from: OVSTable.netflow, in: database, where: [condition])
        
        if count == 0 {
            throw OVNManagerError.operationFailed("NetFlow not found: \(uuid)")
        }
        
        logger.info("Deleted NetFlow: \(uuid)")
    }
    
    // MARK: - QoS Operations
    
    public func getQoSPolicies() async throws -> [OVSQoS] {
        let rows = try await connection.selectAll(from: OVSTable.qos, in: database)
        return try rows.compactMap { row in
            try parseRow(row, as: OVSQoS.self)
        }
    }
    
    public func createQoSPolicy(_ qos: OVSQoS) async throws -> String {
        let row = try createRow(from: qos)
        let result = try await connection.insert(into: OVSTable.qos, in: database, row: row)
        
        guard case .object(let resultObject) = result,
              let uuid = resultObject["uuid"],
              case .array(let uuidArray) = uuid,
              uuidArray.count == 2,
              case .string(let uuidValue) = uuidArray[1] else {
            throw OVNManagerError.invalidResponse("Invalid UUID in insert response")
        }
        
        logger.info("Created QoS policy")
        return uuidValue
    }
    
    public func updateQoSPolicy(uuid: String, _ qos: OVSQoS) async throws {
        let condition = OVSDBCondition(column: "_uuid", function: "==", value: .array([.string("uuid"), .string(uuid)]))
        let row = try createRow(from: qos)
        
        let count = try await connection.update(table: OVSTable.qos, in: database, where: [condition], row: row)
        
        if count == 0 {
            throw OVNManagerError.operationFailed("QoS policy not found: \(uuid)")
        }
        
        logger.info("Updated QoS policy: \(uuid)")
    }
    
    public func deleteQoSPolicy(uuid: String) async throws {
        let condition = OVSDBCondition(column: "_uuid", function: "==", value: .array([.string("uuid"), .string(uuid)]))
        let count = try await connection.delete(from: OVSTable.qos, in: database, where: [condition])
        
        if count == 0 {
            throw OVNManagerError.operationFailed("QoS policy not found: \(uuid)")
        }
        
        logger.info("Deleted QoS policy: \(uuid)")
    }
    
    // MARK: - Queue Operations
    
    public func getQueues() async throws -> [OVSQueue] {
        let rows = try await connection.selectAll(from: OVSTable.queue, in: database)
        return try rows.compactMap { row in
            try parseRow(row, as: OVSQueue.self)
        }
    }
    
    public func createQueue(_ queue: OVSQueue) async throws -> String {
        let row = try createRow(from: queue)
        let result = try await connection.insert(into: OVSTable.queue, in: database, row: row)
        
        guard case .object(let resultObject) = result,
              let uuid = resultObject["uuid"],
              case .array(let uuidArray) = uuid,
              uuidArray.count == 2,
              case .string(let uuidValue) = uuidArray[1] else {
            throw OVNManagerError.invalidResponse("Invalid UUID in insert response")
        }
        
        logger.info("Created queue")
        return uuidValue
    }
    
    public func updateQueue(uuid: String, _ queue: OVSQueue) async throws {
        let condition = OVSDBCondition(column: "_uuid", function: "==", value: .array([.string("uuid"), .string(uuid)]))
        let row = try createRow(from: queue)
        
        let count = try await connection.update(table: OVSTable.queue, in: database, where: [condition], row: row)
        
        if count == 0 {
            throw OVNManagerError.operationFailed("Queue not found: \(uuid)")
        }
        
        logger.info("Updated queue: \(uuid)")
    }
    
    public func deleteQueue(uuid: String) async throws {
        let condition = OVSDBCondition(column: "_uuid", function: "==", value: .array([.string("uuid"), .string(uuid)]))
        let count = try await connection.delete(from: OVSTable.queue, in: database, where: [condition])
        
        if count == 0 {
            throw OVNManagerError.operationFailed("Queue not found: \(uuid)")
        }
        
        logger.info("Deleted queue: \(uuid)")
    }
    
    // MARK: - Statistics Operations
    
    public func getBridgeStatistics(bridge: String) async throws -> [String: Any] {
        // This would typically require parsing statistics from the Bridge table
        let condition = OVSDBCondition(column: "name", function: "==", value: .string(bridge))
        let rows = try await connection.select(from: OVSTable.bridge, in: database, where: [condition], columns: ["statistics"])
        
        guard let firstRow = rows.first,
              let stats = firstRow["statistics"] else {
            return [:]
        }
        
        return convertJSONValueToObject(stats) as? [String: Any] ?? [:]
    }
    
    public func getPortStatistics(port: String) async throws -> [String: Any] {
        let condition = OVSDBCondition(column: "name", function: "==", value: .string(port))
        let rows = try await connection.select(from: OVSTable.port, in: database, where: [condition], columns: ["statistics"])
        
        guard let firstRow = rows.first,
              let stats = firstRow["statistics"] else {
            return [:]
        }
        
        return convertJSONValueToObject(stats) as? [String: Any] ?? [:]
    }
    
    public func getInterfaceStatistics(interface: String) async throws -> [String: Any] {
        let condition = OVSDBCondition(column: "name", function: "==", value: .string(interface))
        let rows = try await connection.select(from: OVSTable.interface, in: database, where: [condition], columns: ["statistics"])
        
        guard let firstRow = rows.first,
              let stats = firstRow["statistics"] else {
            return [:]
        }
        
        return convertJSONValueToObject(stats) as? [String: Any] ?? [:]
    }
    
    // MARK: - Monitoring
    
    public func startMonitoring(tables: [String]) async throws -> String {
        var monitorRequests: [String: OVSDBMonitorRequest] = [:]
        
        for table in tables {
            monitorRequests[table] = OVSDBMonitorRequest()
        }
        
        return try await connection.startMonitoring(database: database, tables: monitorRequests)
    }
    
    public func stopMonitoring(monitorId: String) async throws {
        try await connection.stopMonitoring(monitorId: monitorId)
    }
    
    public func monitorUpdates() -> AsyncThrowingStream<OVSDBUpdate, Error> {
        return connection.monitorUpdates()
    }
}

// MARK: - Helper Methods

private extension OVSManager {
    func parseRow<T: Codable>(_ row: OVSDBRow, as type: T.Type) throws -> T {
        let jsonObject = convertRowToJSONObject(row)
        let data = try JSONSerialization.data(withJSONObject: jsonObject)
        let decoder = JSONDecoder()
        return try decoder.decode(type, from: data)
    }
    
    func createRow<T: Codable>(from object: T) throws -> OVSDBRow {
        let encoder = JSONEncoder()
        let data = try encoder.encode(object)
        let jsonObject = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        
        var row: OVSDBRow = [:]
        for (key, value) in jsonObject {
            if key != "_uuid" { // Skip UUID for inserts
                row[key] = try convertToJSONValue(value)
            }
        }
        return row
    }
    
    func convertRowToJSONObject(_ row: OVSDBRow) -> [String: Any] {
        var result: [String: Any] = [:]
        for (key, value) in row {
            result[key] = convertJSONValueToObject(value)
        }
        return result
    }
    
    func convertJSONValueToObject(_ value: JSONValue) -> Any {
        switch value {
        case .null:
            return NSNull()
        case .boolean(let bool):
            return bool
        case .number(let number):
            return number
        case .string(let string):
            return string
        case .array(let array):
            return array.map { convertJSONValueToObject($0) }
        case .object(let object):
            var result: [String: Any] = [:]
            for (key, val) in object {
                result[key] = convertJSONValueToObject(val)
            }
            return result
        }
    }
    
    func convertToJSONValue(_ object: Any) throws -> JSONValue {
        if object is NSNull {
            return .null
        } else if let bool = object as? Bool {
            return .boolean(bool)
        } else if let number = object as? NSNumber {
            return .number(number.doubleValue)
        } else if let string = object as? String {
            return .string(string)
        } else if let array = object as? [Any] {
            let jsonArray = try array.map { try convertToJSONValue($0) }
            return .array(jsonArray)
        } else if let dict = object as? [String: Any] {
            var jsonObject: [String: JSONValue] = [:]
            for (key, value) in dict {
                jsonObject[key] = try convertToJSONValue(value)
            }
            return .object(jsonObject)
        } else {
            throw OVNManagerError.encodingError(
                NSError(domain: "OVSManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "Unsupported type for JSON conversion"])
            )
        }
    }
}