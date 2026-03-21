import Foundation
import NIO

// MARK: - OVS Management Protocol

public protocol OVSManaging {
    // Connection Management
    func connect() async throws
    func disconnect() async throws
    var isConnected: Bool { get }
    
    // Database Operations
    func listDatabases() async throws -> [String]
    func getDatabaseSchema(database: String) async throws -> JSONValue
    
    // Bridge Operations
    func getBridges() async throws -> [OVSBridge]
    func getBridge(named name: String) async throws -> OVSBridge?
    func createBridge(_ bridge: OVSBridge) async throws -> String
    func updateBridge(uuid: String, _ bridge: OVSBridge) async throws
    func deleteBridge(uuid: String) async throws
    func deleteBridge(named name: String) async throws
    
    // Port Operations
    func getPorts() async throws -> [OVSPort]
    func getPort(named name: String) async throws -> OVSPort?
    func createPort(_ port: OVSPort) async throws -> String
    func updatePort(uuid: String, _ port: OVSPort) async throws
    func deletePort(uuid: String) async throws
    func deletePort(named name: String) async throws
    
    // Interface Operations
    func getInterfaces() async throws -> [OVSInterface]
    func getInterface(named name: String) async throws -> OVSInterface?
    func createInterface(_ interface: OVSInterface) async throws -> String
    func updateInterface(uuid: String, _ interface: OVSInterface) async throws
    func deleteInterface(uuid: String) async throws
    func deleteInterface(named name: String) async throws
    
    // Controller Operations
    func getControllers() async throws -> [OVSController]
    func getController(target: String) async throws -> OVSController?
    func createController(_ controller: OVSController) async throws -> String
    func updateController(uuid: String, _ controller: OVSController) async throws
    func deleteController(uuid: String) async throws
    func deleteController(target: String) async throws
    
    // Flow Operations
    func getFlows(bridge: String, table: Int?) async throws -> [OVSFlow]
    func addFlow(bridge: String, flow: OVSFlow) async throws
    func deleteFlow(bridge: String, flow: OVSFlow) async throws
    func deleteAllFlows(bridge: String) async throws
    func modifyFlow(bridge: String, flow: OVSFlow) async throws
    
    // Mirror Operations
    func getMirrors() async throws -> [OVSMirror]
    func getMirror(named name: String) async throws -> OVSMirror?
    func createMirror(_ mirror: OVSMirror) async throws -> String
    func updateMirror(uuid: String, _ mirror: OVSMirror) async throws
    func deleteMirror(uuid: String) async throws
    func deleteMirror(named name: String) async throws
    
    // NetFlow Operations
    func getNetFlows() async throws -> [OVSNetFlow]
    func createNetFlow(_ netflow: OVSNetFlow) async throws -> String
    func updateNetFlow(uuid: String, _ netflow: OVSNetFlow) async throws
    func deleteNetFlow(uuid: String) async throws
    
    // QoS Operations
    func getQoSPolicies() async throws -> [OVSQoS]
    func createQoSPolicy(_ qos: OVSQoS) async throws -> String
    func updateQoSPolicy(uuid: String, _ qos: OVSQoS) async throws
    func deleteQoSPolicy(uuid: String) async throws
    
    // Queue Operations
    func getQueues() async throws -> [OVSQueue]
    func createQueue(_ queue: OVSQueue) async throws -> String
    func updateQueue(uuid: String, _ queue: OVSQueue) async throws
    func deleteQueue(uuid: String) async throws
    
    // Statistics Operations
    func getBridgeStatistics(bridge: String) async throws -> [String: Any]
    func getPortStatistics(port: String) async throws -> [String: Any]
    func getInterfaceStatistics(interface: String) async throws -> [String: Any]
    
    // Monitoring
    func startMonitoring(tables: [String]) async throws -> String
    func stopMonitoring(monitorId: String) async throws
    func monitorUpdates() -> AsyncThrowingStream<OVSDBUpdate, Error>
}

// MARK: - OVS Database Constants

public enum OVSDatabase {
    public static let openVSwitch = "Open_vSwitch"
}

public enum OVSTable {
    public static let bridge = "Bridge"
    public static let port = "Port"
    public static let interface = "Interface"
    public static let controller = "Controller"
    public static let manager = "Manager"
    public static let mirror = "Mirror"
    public static let netflow = "NetFlow"
    public static let sflow = "sFlow"
    public static let ipfix = "IPFIX"
    public static let qos = "QoS"
    public static let queue = "Queue"
    public static let ssl = "SSL"
    public static let openVSwitch = "Open_vSwitch"
    public static let flowTable = "Flow_Table"
    public static let flowSampleCollectorSet = "Flow_Sample_Collector_Set"
}

// MARK: - OVS Command Builders

public struct OVSFlowBuilder {
    private var table: Int?
    private var priority: Int?
    private var match: String?
    private var actions: String?
    private var idle_timeout: Int?
    private var hard_timeout: Int?
    private var cookie: String?
    
    public init() {}
    
    public func table(_ table: Int) -> OVSFlowBuilder {
        var builder = self
        builder.table = table
        return builder
    }
    
    public func priority(_ priority: Int) -> OVSFlowBuilder {
        var builder = self
        builder.priority = priority
        return builder
    }
    
    public func match(_ match: String) -> OVSFlowBuilder {
        var builder = self
        builder.match = match
        return builder
    }
    
    public func actions(_ actions: String) -> OVSFlowBuilder {
        var builder = self
        builder.actions = actions
        return builder
    }
    
    public func idleTimeout(_ timeout: Int) -> OVSFlowBuilder {
        var builder = self
        builder.idle_timeout = timeout
        return builder
    }
    
    public func hardTimeout(_ timeout: Int) -> OVSFlowBuilder {
        var builder = self
        builder.hard_timeout = timeout
        return builder
    }
    
    public func cookie(_ cookie: String) -> OVSFlowBuilder {
        var builder = self
        builder.cookie = cookie
        return builder
    }
    
    public func build() -> OVSFlow {
        return OVSFlow(
            table: table,
            priority: priority,
            match: match,
            actions: actions,
            idle_timeout: idle_timeout,
            hard_timeout: hard_timeout,
            cookie: cookie
        )
    }
}

// MARK: - Helper Extensions

public extension OVSManaging {
    func connectToOVS(socketPath: String = "/var/run/openvswitch/db.sock") async throws {
        try await connect()
    }
    
    func flowBuilder() -> OVSFlowBuilder {
        return OVSFlowBuilder()
    }
}