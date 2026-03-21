import Foundation
import NIO

// MARK: - OVN Management Protocol

public protocol OVNManaging {
    // Connection Management
    func connect() async throws
    func disconnect() async throws
    var isConnected: Bool { get }
    
    // Database Operations
    func listDatabases() async throws -> [String]
    func getDatabaseSchema(database: String) async throws -> JSONValue
    
    // Logical Switch Operations
    func getLogicalSwitches() async throws -> [OVNLogicalSwitch]
    func getLogicalSwitch(named name: String) async throws -> OVNLogicalSwitch?
    func createLogicalSwitch(_ logicalSwitch: OVNLogicalSwitch) async throws -> String
    func updateLogicalSwitch(uuid: String, _ logicalSwitch: OVNLogicalSwitch) async throws
    func deleteLogicalSwitch(uuid: String) async throws
    func deleteLogicalSwitch(named name: String) async throws
    
    // Logical Switch Port Operations
    func getLogicalSwitchPorts() async throws -> [OVNLogicalSwitchPort]
    func getLogicalSwitchPort(named name: String) async throws -> OVNLogicalSwitchPort?
    func createLogicalSwitchPort(_ port: OVNLogicalSwitchPort) async throws -> String
    func updateLogicalSwitchPort(uuid: String, _ port: OVNLogicalSwitchPort) async throws
    func deleteLogicalSwitchPort(uuid: String) async throws
    func deleteLogicalSwitchPort(named name: String) async throws
    
    // Logical Router Operations
    func getLogicalRouters() async throws -> [OVNLogicalRouter]
    func getLogicalRouter(named name: String) async throws -> OVNLogicalRouter?
    func createLogicalRouter(_ router: OVNLogicalRouter) async throws -> String
    func updateLogicalRouter(uuid: String, _ router: OVNLogicalRouter) async throws
    func deleteLogicalRouter(uuid: String) async throws
    func deleteLogicalRouter(named name: String) async throws
    
    // Logical Router Port Operations
    func getLogicalRouterPorts() async throws -> [OVNLogicalRouterPort]
    func getLogicalRouterPort(named name: String) async throws -> OVNLogicalRouterPort?
    func createLogicalRouterPort(_ port: OVNLogicalRouterPort) async throws -> String
    func updateLogicalRouterPort(uuid: String, _ port: OVNLogicalRouterPort) async throws
    func deleteLogicalRouterPort(uuid: String) async throws
    func deleteLogicalRouterPort(named name: String) async throws
    
    // ACL Operations
    func getACLs() async throws -> [OVNACL]
    func createACL(_ acl: OVNACL) async throws -> String
    func updateACL(uuid: String, _ acl: OVNACL) async throws
    func deleteACL(uuid: String) async throws
    
    // Load Balancer Operations
    func getLoadBalancers() async throws -> [OVNLoadBalancer]
    func getLoadBalancer(named name: String) async throws -> OVNLoadBalancer?
    func createLoadBalancer(_ loadBalancer: OVNLoadBalancer) async throws -> String
    func updateLoadBalancer(uuid: String, _ loadBalancer: OVNLoadBalancer) async throws
    func deleteLoadBalancer(uuid: String) async throws
    func deleteLoadBalancer(named name: String) async throws
    
    // NAT Operations
    func getNATRules() async throws -> [OVNNAT]
    func createNATRule(_ nat: OVNNAT) async throws -> String
    func updateNATRule(uuid: String, _ nat: OVNNAT) async throws
    func deleteNATRule(uuid: String) async throws
    
    // DHCP Operations
    func getDHCPOptions() async throws -> [OVNDHCPOptions]
    func createDHCPOptions(_ dhcp: OVNDHCPOptions) async throws -> String
    func updateDHCPOptions(uuid: String, _ dhcp: OVNDHCPOptions) async throws
    func deleteDHCPOptions(uuid: String) async throws
    
    // Monitoring
    func startMonitoring(tables: [String]) async throws -> String
    func stopMonitoring(monitorId: String) async throws
    func monitorUpdates() -> AsyncThrowingStream<OVSDBUpdate, Error>
    
    // Southbound Operations
    func getChassis() async throws -> [OVNChassis]
    func getChassisPrivate() async throws -> [OVNChassisPrivate]
    func getPortBindings() async throws -> [OVNPortBinding]
    func getLogicalFlows() async throws -> [OVNLogicalFlow]
}

// MARK: - OVN Database Constants

public enum OVNDatabase {
    public static let northbound = "OVN_Northbound"
    public static let southbound = "OVN_Southbound"
}

public enum OVNTable {
    // Northbound tables
    public static let logicalSwitch = "Logical_Switch"
    public static let logicalSwitchPort = "Logical_Switch_Port"
    public static let logicalRouter = "Logical_Router"
    public static let logicalRouterPort = "Logical_Router_Port"
    public static let acl = "ACL"
    public static let loadBalancer = "Load_Balancer"
    public static let nat = "NAT"
    public static let dhcpOptions = "DHCP_Options"
    
    // Southbound tables
    public static let chassis = "Chassis"
    public static let chassisPrivate = "Chassis_Private"
    public static let portBinding = "Port_Binding"
    public static let logicalFlow = "Logical_Flow"
    public static let encap = "Encap"
}

// MARK: - Helper Extensions

public extension OVNManaging {
    func connectToNorthbound(socketPath: String = "/var/run/ovn/ovnnb_db.sock") async throws {
        try await connect()
    }
    
    func connectToSouthbound(socketPath: String = "/var/run/ovn/ovnsb_db.sock") async throws {
        try await connect()
    }
}