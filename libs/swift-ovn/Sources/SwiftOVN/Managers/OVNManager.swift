import Foundation
import NIO
import Logging

public final class OVNManager: OVNManaging {
    private let connection: OVSDBConnection
    private let logger: Logger
    private let database: String
    
    public init(socketPath: String, database: String = OVNDatabase.northbound, eventLoopGroup: EventLoopGroup? = nil, logger: Logger? = nil) {
        self.connection = OVSDBConnection(
            socketPath: socketPath,
            eventLoopGroup: eventLoopGroup,
            logger: logger
        )
        self.database = database
        self.logger = logger ?? Logger(label: "ovn-manager.ovn")
    }
    
    // MARK: - Connection Management
    
    public func connect() async throws {
        try await connection.connect()
        logger.info("Connected to OVN database: \(database)")
    }
    
    public func disconnect() async throws {
        try await connection.disconnect()
        logger.info("Disconnected from OVN database")
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
    
    // MARK: - Logical Switch Operations
    
    public func getLogicalSwitches() async throws -> [OVNLogicalSwitch] {
        let rows = try await connection.selectAll(from: OVNTable.logicalSwitch, in: database)
        return try rows.compactMap { row in
            try parseRow(row, as: OVNLogicalSwitch.self)
        }
    }
    
    public func getLogicalSwitch(named name: String) async throws -> OVNLogicalSwitch? {
        let condition = OVSDBCondition(column: "name", function: "==", value: .string(name))
        let rows = try await connection.select(from: OVNTable.logicalSwitch, in: database, where: [condition])
        
        guard let firstRow = rows.first else { return nil }
        return try parseRow(firstRow, as: OVNLogicalSwitch.self)
    }
    
    public func createLogicalSwitch(_ logicalSwitch: OVNLogicalSwitch) async throws -> String {
        let row = try createRow(from: logicalSwitch)
        let result = try await connection.insert(into: OVNTable.logicalSwitch, in: database, row: row)
        
        guard case .object(let resultObject) = result,
              let uuid = resultObject["uuid"],
              case .array(let uuidArray) = uuid,
              uuidArray.count == 2,
              case .string(let uuidValue) = uuidArray[1] else {
            throw OVNManagerError.invalidResponse("Invalid UUID in insert response")
        }
        
        logger.info("Created logical switch: \(logicalSwitch.name)")
        return uuidValue
    }
    
    public func updateLogicalSwitch(uuid: String, _ logicalSwitch: OVNLogicalSwitch) async throws {
        let condition = OVSDBCondition(column: "_uuid", function: "==", value: .array([.string("uuid"), .string(uuid)]))
        let row = try createRow(from: logicalSwitch)
        
        let count = try await connection.update(table: OVNTable.logicalSwitch, in: database, where: [condition], row: row)
        
        if count == 0 {
            throw OVNManagerError.operationFailed("Logical switch not found: \(uuid)")
        }
        
        logger.info("Updated logical switch: \(logicalSwitch.name)")
    }
    
    public func deleteLogicalSwitch(uuid: String) async throws {
        let condition = OVSDBCondition(column: "_uuid", function: "==", value: .array([.string("uuid"), .string(uuid)]))
        let count = try await connection.delete(from: OVNTable.logicalSwitch, in: database, where: [condition])
        
        if count == 0 {
            throw OVNManagerError.operationFailed("Logical switch not found: \(uuid)")
        }
        
        logger.info("Deleted logical switch: \(uuid)")
    }
    
    public func deleteLogicalSwitch(named name: String) async throws {
        let condition = OVSDBCondition(column: "name", function: "==", value: .string(name))
        let count = try await connection.delete(from: OVNTable.logicalSwitch, in: database, where: [condition])
        
        if count == 0 {
            throw OVNManagerError.operationFailed("Logical switch not found: \(name)")
        }
        
        logger.info("Deleted logical switch: \(name)")
    }
    
    // MARK: - Logical Switch Port Operations
    
    public func getLogicalSwitchPorts() async throws -> [OVNLogicalSwitchPort] {
        let rows = try await connection.selectAll(from: OVNTable.logicalSwitchPort, in: database)
        return try rows.compactMap { row in
            try parseRow(row, as: OVNLogicalSwitchPort.self)
        }
    }
    
    public func getLogicalSwitchPort(named name: String) async throws -> OVNLogicalSwitchPort? {
        let condition = OVSDBCondition(column: "name", function: "==", value: .string(name))
        let rows = try await connection.select(from: OVNTable.logicalSwitchPort, in: database, where: [condition])
        
        guard let firstRow = rows.first else { return nil }
        return try parseRow(firstRow, as: OVNLogicalSwitchPort.self)
    }
    
    public func createLogicalSwitchPort(_ port: OVNLogicalSwitchPort) async throws -> String {
        let row = try createRow(from: port)
        let result = try await connection.insert(into: OVNTable.logicalSwitchPort, in: database, row: row)
        
        guard case .object(let resultObject) = result,
              let uuid = resultObject["uuid"],
              case .array(let uuidArray) = uuid,
              uuidArray.count == 2,
              case .string(let uuidValue) = uuidArray[1] else {
            throw OVNManagerError.invalidResponse("Invalid UUID in insert response")
        }
        
        logger.info("Created logical switch port: \(port.name)")
        return uuidValue
    }
    
    public func updateLogicalSwitchPort(uuid: String, _ port: OVNLogicalSwitchPort) async throws {
        let condition = OVSDBCondition(column: "_uuid", function: "==", value: .array([.string("uuid"), .string(uuid)]))
        let row = try createRow(from: port)
        
        let count = try await connection.update(table: OVNTable.logicalSwitchPort, in: database, where: [condition], row: row)
        
        if count == 0 {
            throw OVNManagerError.operationFailed("Logical switch port not found: \(uuid)")
        }
        
        logger.info("Updated logical switch port: \(port.name)")
    }
    
    public func deleteLogicalSwitchPort(uuid: String) async throws {
        let condition = OVSDBCondition(column: "_uuid", function: "==", value: .array([.string("uuid"), .string(uuid)]))
        let count = try await connection.delete(from: OVNTable.logicalSwitchPort, in: database, where: [condition])
        
        if count == 0 {
            throw OVNManagerError.operationFailed("Logical switch port not found: \(uuid)")
        }
        
        logger.info("Deleted logical switch port: \(uuid)")
    }
    
    public func deleteLogicalSwitchPort(named name: String) async throws {
        let condition = OVSDBCondition(column: "name", function: "==", value: .string(name))
        let count = try await connection.delete(from: OVNTable.logicalSwitchPort, in: database, where: [condition])
        
        if count == 0 {
            throw OVNManagerError.operationFailed("Logical switch port not found: \(name)")
        }
        
        logger.info("Deleted logical switch port: \(name)")
    }
    
    // MARK: - Logical Router Operations
    
    public func getLogicalRouters() async throws -> [OVNLogicalRouter] {
        let rows = try await connection.selectAll(from: OVNTable.logicalRouter, in: database)
        return try rows.compactMap { row in
            try parseRow(row, as: OVNLogicalRouter.self)
        }
    }
    
    public func getLogicalRouter(named name: String) async throws -> OVNLogicalRouter? {
        let condition = OVSDBCondition(column: "name", function: "==", value: .string(name))
        let rows = try await connection.select(from: OVNTable.logicalRouter, in: database, where: [condition])
        
        guard let firstRow = rows.first else { return nil }
        return try parseRow(firstRow, as: OVNLogicalRouter.self)
    }
    
    public func createLogicalRouter(_ router: OVNLogicalRouter) async throws -> String {
        let row = try createRow(from: router)
        let result = try await connection.insert(into: OVNTable.logicalRouter, in: database, row: row)
        
        guard case .object(let resultObject) = result,
              let uuid = resultObject["uuid"],
              case .array(let uuidArray) = uuid,
              uuidArray.count == 2,
              case .string(let uuidValue) = uuidArray[1] else {
            throw OVNManagerError.invalidResponse("Invalid UUID in insert response")
        }
        
        logger.info("Created logical router: \(router.name)")
        return uuidValue
    }
    
    public func updateLogicalRouter(uuid: String, _ router: OVNLogicalRouter) async throws {
        let condition = OVSDBCondition(column: "_uuid", function: "==", value: .array([.string("uuid"), .string(uuid)]))
        let row = try createRow(from: router)
        
        let count = try await connection.update(table: OVNTable.logicalRouter, in: database, where: [condition], row: row)
        
        if count == 0 {
            throw OVNManagerError.operationFailed("Logical router not found: \(uuid)")
        }
        
        logger.info("Updated logical router: \(router.name)")
    }
    
    public func deleteLogicalRouter(uuid: String) async throws {
        let condition = OVSDBCondition(column: "_uuid", function: "==", value: .array([.string("uuid"), .string(uuid)]))
        let count = try await connection.delete(from: OVNTable.logicalRouter, in: database, where: [condition])
        
        if count == 0 {
            throw OVNManagerError.operationFailed("Logical router not found: \(uuid)")
        }
        
        logger.info("Deleted logical router: \(uuid)")
    }
    
    public func deleteLogicalRouter(named name: String) async throws {
        let condition = OVSDBCondition(column: "name", function: "==", value: .string(name))
        let count = try await connection.delete(from: OVNTable.logicalRouter, in: database, where: [condition])
        
        if count == 0 {
            throw OVNManagerError.operationFailed("Logical router not found: \(name)")
        }
        
        logger.info("Deleted logical router: \(name)")
    }
    
    // MARK: - Logical Router Port Operations
    
    public func getLogicalRouterPorts() async throws -> [OVNLogicalRouterPort] {
        let rows = try await connection.selectAll(from: OVNTable.logicalRouterPort, in: database)
        return try rows.compactMap { row in
            try parseRow(row, as: OVNLogicalRouterPort.self)
        }
    }
    
    public func getLogicalRouterPort(named name: String) async throws -> OVNLogicalRouterPort? {
        let condition = OVSDBCondition(column: "name", function: "==", value: .string(name))
        let rows = try await connection.select(from: OVNTable.logicalRouterPort, in: database, where: [condition])
        
        guard let firstRow = rows.first else { return nil }
        return try parseRow(firstRow, as: OVNLogicalRouterPort.self)
    }
    
    public func createLogicalRouterPort(_ port: OVNLogicalRouterPort) async throws -> String {
        let row = try createRow(from: port)
        let result = try await connection.insert(into: OVNTable.logicalRouterPort, in: database, row: row)
        
        guard case .object(let resultObject) = result,
              let uuid = resultObject["uuid"],
              case .array(let uuidArray) = uuid,
              uuidArray.count == 2,
              case .string(let uuidValue) = uuidArray[1] else {
            throw OVNManagerError.invalidResponse("Invalid UUID in insert response")
        }
        
        logger.info("Created logical router port: \(port.name)")
        return uuidValue
    }
    
    public func updateLogicalRouterPort(uuid: String, _ port: OVNLogicalRouterPort) async throws {
        let condition = OVSDBCondition(column: "_uuid", function: "==", value: .array([.string("uuid"), .string(uuid)]))
        let row = try createRow(from: port)
        
        let count = try await connection.update(table: OVNTable.logicalRouterPort, in: database, where: [condition], row: row)
        
        if count == 0 {
            throw OVNManagerError.operationFailed("Logical router port not found: \(uuid)")
        }
        
        logger.info("Updated logical router port: \(port.name)")
    }
    
    public func deleteLogicalRouterPort(uuid: String) async throws {
        let condition = OVSDBCondition(column: "_uuid", function: "==", value: .array([.string("uuid"), .string(uuid)]))
        let count = try await connection.delete(from: OVNTable.logicalRouterPort, in: database, where: [condition])
        
        if count == 0 {
            throw OVNManagerError.operationFailed("Logical router port not found: \(uuid)")
        }
        
        logger.info("Deleted logical router port: \(uuid)")
    }
    
    public func deleteLogicalRouterPort(named name: String) async throws {
        let condition = OVSDBCondition(column: "name", function: "==", value: .string(name))
        let count = try await connection.delete(from: OVNTable.logicalRouterPort, in: database, where: [condition])
        
        if count == 0 {
            throw OVNManagerError.operationFailed("Logical router port not found: \(name)")
        }
        
        logger.info("Deleted logical router port: \(name)")
    }
    
    // MARK: - ACL Operations
    
    public func getACLs() async throws -> [OVNACL] {
        let rows = try await connection.selectAll(from: OVNTable.acl, in: database)
        return try rows.compactMap { row in
            try parseRow(row, as: OVNACL.self)
        }
    }
    
    public func createACL(_ acl: OVNACL) async throws -> String {
        let row = try createRow(from: acl)
        let result = try await connection.insert(into: OVNTable.acl, in: database, row: row)
        
        guard case .object(let resultObject) = result,
              let uuid = resultObject["uuid"],
              case .array(let uuidArray) = uuid,
              uuidArray.count == 2,
              case .string(let uuidValue) = uuidArray[1] else {
            throw OVNManagerError.invalidResponse("Invalid UUID in insert response")
        }
        
        logger.info("Created ACL")
        return uuidValue
    }
    
    public func updateACL(uuid: String, _ acl: OVNACL) async throws {
        let condition = OVSDBCondition(column: "_uuid", function: "==", value: .array([.string("uuid"), .string(uuid)]))
        let row = try createRow(from: acl)
        
        let count = try await connection.update(table: OVNTable.acl, in: database, where: [condition], row: row)
        
        if count == 0 {
            throw OVNManagerError.operationFailed("ACL not found: \(uuid)")
        }
        
        logger.info("Updated ACL: \(uuid)")
    }
    
    public func deleteACL(uuid: String) async throws {
        let condition = OVSDBCondition(column: "_uuid", function: "==", value: .array([.string("uuid"), .string(uuid)]))
        let count = try await connection.delete(from: OVNTable.acl, in: database, where: [condition])
        
        if count == 0 {
            throw OVNManagerError.operationFailed("ACL not found: \(uuid)")
        }
        
        logger.info("Deleted ACL: \(uuid)")
    }
    
    // MARK: - Load Balancer Operations
    
    public func getLoadBalancers() async throws -> [OVNLoadBalancer] {
        let rows = try await connection.selectAll(from: OVNTable.loadBalancer, in: database)
        return try rows.compactMap { row in
            try parseRow(row, as: OVNLoadBalancer.self)
        }
    }
    
    public func getLoadBalancer(named name: String) async throws -> OVNLoadBalancer? {
        let condition = OVSDBCondition(column: "name", function: "==", value: .string(name))
        let rows = try await connection.select(from: OVNTable.loadBalancer, in: database, where: [condition])
        
        guard let firstRow = rows.first else { return nil }
        return try parseRow(firstRow, as: OVNLoadBalancer.self)
    }
    
    public func createLoadBalancer(_ loadBalancer: OVNLoadBalancer) async throws -> String {
        let row = try createRow(from: loadBalancer)
        let result = try await connection.insert(into: OVNTable.loadBalancer, in: database, row: row)
        
        guard case .object(let resultObject) = result,
              let uuid = resultObject["uuid"],
              case .array(let uuidArray) = uuid,
              uuidArray.count == 2,
              case .string(let uuidValue) = uuidArray[1] else {
            throw OVNManagerError.invalidResponse("Invalid UUID in insert response")
        }
        
        logger.info("Created load balancer: \(loadBalancer.name)")
        return uuidValue
    }
    
    public func updateLoadBalancer(uuid: String, _ loadBalancer: OVNLoadBalancer) async throws {
        let condition = OVSDBCondition(column: "_uuid", function: "==", value: .array([.string("uuid"), .string(uuid)]))
        let row = try createRow(from: loadBalancer)
        
        let count = try await connection.update(table: OVNTable.loadBalancer, in: database, where: [condition], row: row)
        
        if count == 0 {
            throw OVNManagerError.operationFailed("Load balancer not found: \(uuid)")
        }
        
        logger.info("Updated load balancer: \(loadBalancer.name)")
    }
    
    public func deleteLoadBalancer(uuid: String) async throws {
        let condition = OVSDBCondition(column: "_uuid", function: "==", value: .array([.string("uuid"), .string(uuid)]))
        let count = try await connection.delete(from: OVNTable.loadBalancer, in: database, where: [condition])
        
        if count == 0 {
            throw OVNManagerError.operationFailed("Load balancer not found: \(uuid)")
        }
        
        logger.info("Deleted load balancer: \(uuid)")
    }
    
    public func deleteLoadBalancer(named name: String) async throws {
        let condition = OVSDBCondition(column: "name", function: "==", value: .string(name))
        let count = try await connection.delete(from: OVNTable.loadBalancer, in: database, where: [condition])
        
        if count == 0 {
            throw OVNManagerError.operationFailed("Load balancer not found: \(name)")
        }
        
        logger.info("Deleted load balancer: \(name)")
    }
    
    // MARK: - NAT Operations
    
    public func getNATRules() async throws -> [OVNNAT] {
        let rows = try await connection.selectAll(from: OVNTable.nat, in: database)
        return try rows.compactMap { row in
            try parseRow(row, as: OVNNAT.self)
        }
    }
    
    public func createNATRule(_ nat: OVNNAT) async throws -> String {
        let row = try createRow(from: nat)
        let result = try await connection.insert(into: OVNTable.nat, in: database, row: row)
        
        guard case .object(let resultObject) = result,
              let uuid = resultObject["uuid"],
              case .array(let uuidArray) = uuid,
              uuidArray.count == 2,
              case .string(let uuidValue) = uuidArray[1] else {
            throw OVNManagerError.invalidResponse("Invalid UUID in insert response")
        }
        
        logger.info("Created NAT rule")
        return uuidValue
    }
    
    public func updateNATRule(uuid: String, _ nat: OVNNAT) async throws {
        let condition = OVSDBCondition(column: "_uuid", function: "==", value: .array([.string("uuid"), .string(uuid)]))
        let row = try createRow(from: nat)
        
        let count = try await connection.update(table: OVNTable.nat, in: database, where: [condition], row: row)
        
        if count == 0 {
            throw OVNManagerError.operationFailed("NAT rule not found: \(uuid)")
        }
        
        logger.info("Updated NAT rule: \(uuid)")
    }
    
    public func deleteNATRule(uuid: String) async throws {
        let condition = OVSDBCondition(column: "_uuid", function: "==", value: .array([.string("uuid"), .string(uuid)]))
        let count = try await connection.delete(from: OVNTable.nat, in: database, where: [condition])
        
        if count == 0 {
            throw OVNManagerError.operationFailed("NAT rule not found: \(uuid)")
        }
        
        logger.info("Deleted NAT rule: \(uuid)")
    }
    
    // MARK: - DHCP Operations
    
    public func getDHCPOptions() async throws -> [OVNDHCPOptions] {
        let rows = try await connection.selectAll(from: OVNTable.dhcpOptions, in: database)
        return try rows.compactMap { row in
            try parseRow(row, as: OVNDHCPOptions.self)
        }
    }
    
    public func createDHCPOptions(_ dhcp: OVNDHCPOptions) async throws -> String {
        let row = try createRow(from: dhcp)
        let result = try await connection.insert(into: OVNTable.dhcpOptions, in: database, row: row)
        
        guard case .object(let resultObject) = result,
              let uuid = resultObject["uuid"],
              case .array(let uuidArray) = uuid,
              uuidArray.count == 2,
              case .string(let uuidValue) = uuidArray[1] else {
            throw OVNManagerError.invalidResponse("Invalid UUID in insert response")
        }
        
        logger.info("Created DHCP options")
        return uuidValue
    }
    
    public func updateDHCPOptions(uuid: String, _ dhcp: OVNDHCPOptions) async throws {
        let condition = OVSDBCondition(column: "_uuid", function: "==", value: .array([.string("uuid"), .string(uuid)]))
        let row = try createRow(from: dhcp)
        
        let count = try await connection.update(table: OVNTable.dhcpOptions, in: database, where: [condition], row: row)
        
        if count == 0 {
            throw OVNManagerError.operationFailed("DHCP options not found: \(uuid)")
        }
        
        logger.info("Updated DHCP options: \(uuid)")
    }
    
    public func deleteDHCPOptions(uuid: String) async throws {
        let condition = OVSDBCondition(column: "_uuid", function: "==", value: .array([.string("uuid"), .string(uuid)]))
        let count = try await connection.delete(from: OVNTable.dhcpOptions, in: database, where: [condition])
        
        if count == 0 {
            throw OVNManagerError.operationFailed("DHCP options not found: \(uuid)")
        }
        
        logger.info("Deleted DHCP options: \(uuid)")
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
    
    // MARK: - Southbound Operations
    
    public func getChassis() async throws -> [OVNChassis] {
        guard database == OVNDatabase.southbound else {
            throw OVNManagerError.operationFailed("Chassis operations require southbound database")
        }
        
        let rows = try await connection.selectAll(from: OVNTable.chassis, in: database)
        return try rows.compactMap { row in
            try parseRow(row, as: OVNChassis.self)
        }
    }
    
    public func getChassisPrivate() async throws -> [OVNChassisPrivate] {
        guard database == OVNDatabase.southbound else {
            throw OVNManagerError.operationFailed("Chassis Private operations require southbound database")
        }
        
        let rows = try await connection.selectAll(from: OVNTable.chassisPrivate, in: database)
        return try rows.compactMap { row in
            try parseRow(row, as: OVNChassisPrivate.self)
        }
    }
    
    public func getPortBindings() async throws -> [OVNPortBinding] {
        guard database == OVNDatabase.southbound else {
            throw OVNManagerError.operationFailed("Port Binding operations require southbound database")
        }
        
        let rows = try await connection.selectAll(from: OVNTable.portBinding, in: database)
        return try rows.compactMap { row in
            try parseRow(row, as: OVNPortBinding.self)
        }
    }
    
    public func getLogicalFlows() async throws -> [OVNLogicalFlow] {
        guard database == OVNDatabase.southbound else {
            throw OVNManagerError.operationFailed("Logical Flow operations require southbound database")
        }
        
        let rows = try await connection.selectAll(from: OVNTable.logicalFlow, in: database)
        return try rows.compactMap { row in
            try parseRow(row, as: OVNLogicalFlow.self)
        }
    }
}

// MARK: - Helper Methods

private extension OVNManager {
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
                NSError(domain: "OVNManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "Unsupported type for JSON conversion"])
            )
        }
    }
}