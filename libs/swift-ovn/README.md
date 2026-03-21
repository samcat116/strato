# SwiftOVN

A comprehensive Swift package for managing OVN (Open Virtual Network) and OVS (Open vSwitch) through their JSON-RPC APIs over Unix domain sockets.

## Features

- 🚀 **Type-Safe Swift Models**: Strongly typed, Codable structs for all OVN and OVS database schemas
- ⚡ **High Performance**: SwiftNIO-based asynchronous Unix socket communication
- 🔄 **Modern Concurrency**: Built with Swift's async/await and AsyncSequence
- 📡 **Real-time Monitoring**: Monitor database changes in real-time using AsyncSequence
- 🌍 **Cross-Platform**: Works on Linux, macOS, and other platforms supported by Swift
- 🛡️ **Comprehensive Error Handling**: Detailed error types and proper error propagation
- 📚 **Feature Complete**: Support for all major OVN and OVS operations

## Installation

Add SwiftOVN to your Swift package dependencies:

```swift
dependencies: [
    .package(url: "https://github.com/samcat116/SwiftOVN.git", from: "1.0.0")
]
```

## Quick Start

### OVN Management

```swift
import SwiftOVN

// Connect to OVN Northbound database
let SwiftOVN = SwiftOVN(socketPath: "/var/run/ovn/ovnnb_db.sock")
try await SwiftOVN.connect()

// Create a logical switch
let switch = OVNLogicalSwitch(
    name: "my-switch",
    external_ids: ["description": "My test switch"]
)
let switchUUID = try await SwiftOVN.createLogicalSwitch(switch)

// Create a logical switch port
let port = OVNLogicalSwitchPort(
    name: "vm1-port",
    addresses: ["02:ac:10:ff:01:30 10.0.0.10"],
    port_security: ["02:ac:10:ff:01:30 10.0.0.10"]
)
let portUUID = try await SwiftOVN.createLogicalSwitchPort(port)

// Get all logical switches
let switches = try await SwiftOVN.getLogicalSwitches()
print("Found \(switches.count) logical switches")
```

### OVS Management

```swift
import SwiftOVN

// Connect to OVS database
let ovsManager = OVSManager(socketPath: "/var/run/openvswitch/db.sock")
try await ovsManager.connect()

// Create a bridge
let bridge = OVSBridge(
    name: "br-int",
    fail_mode: "secure",
    protocols: ["OpenFlow13"]
)
let bridgeUUID = try await ovsManager.createBridge(bridge)

// Create a port
let port = OVSPort(
    name: "veth1",
    interfaces: ["interface-uuid-here"]
)
let portUUID = try await ovsManager.createPort(port)

// Get bridge statistics
let stats = try await ovsManager.getBridgeStatistics(bridge: "br-int")
print("Bridge statistics: \(stats)")
```

### Real-time Monitoring

```swift
// Start monitoring OVN database changes
let monitorId = try await SwiftOVN.startMonitoring(tables: ["Logical_Switch", "Logical_Switch_Port"])

// Process updates in real-time
for try await update in SwiftOVN.monitorUpdates() {
    if let newRow = update.new {
        print("Row updated: \(newRow)")
    }
    if let oldRow = update.old {
        print("Previous row: \(oldRow)")
    }
}

// Stop monitoring when done
try await SwiftOVN.stopMonitoring(monitorId: monitorId)
```

## Architecture

### Core Components

- **JSONRPCClient**: Low-level JSON-RPC communication over Unix sockets
- **UnixSocketConnection**: SwiftNIO-based Unix domain socket handling
- **OVSDBConnection**: OVSDB protocol implementation with monitoring support
- **SwiftOVN**: High-level interface for OVN operations
- **OVSManager**: High-level interface for OVS operations

### Models

The package includes comprehensive Swift models for:

#### OVN Models
- `OVNLogicalSwitch` - Virtual switches in the logical network
- `OVNLogicalSwitchPort` - Ports on logical switches
- `OVNLogicalRouter` - Virtual routers
- `OVNLogicalRouterPort` - Ports on logical routers
- `OVNACL` - Access control lists
- `OVNLoadBalancer` - Load balancing rules
- `OVNNAT` - Network address translation rules
- `OVNDHCPOptions` - DHCP configuration

#### OVS Models
- `OVSBridge` - Open vSwitch bridges
- `OVSPort` - Bridge ports
- `OVSInterface` - Network interfaces
- `OVSController` - OpenFlow controllers
- `OVSFlow` - Flow table entries
- `OVSMirror` - Port mirroring configuration
- `OVSQoS` - Quality of service policies

## Advanced Usage

### Custom Connection Configuration

```swift
// Custom event loop group
let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 2)

// Custom logger
var logger = Logger(label: "my-ovn-app")
logger.logLevel = .debug

let SwiftOVN = SwiftOVN(
    socketPath: "/custom/path/to/ovnnb_db.sock",
    database: OVNDatabase.northbound,
    eventLoopGroup: eventLoopGroup,
    logger: logger
)
```

### Building Complex Queries

```swift
// Find logical switches with specific external IDs
let switches = try await SwiftOVN.getLogicalSwitches()
let productionSwitches = switches.filter {
    $0.external_ids?["environment"] == "production"
}

// Create ACL with specific conditions
let acl = OVNACL(
    priority: 1000,
    direction: "to-lport",
    match: "ip4.src == 192.168.1.0/24 && tcp.dst == 80",
    action: "allow",
    log: true,
    name: "allow-web-traffic"
)
try await SwiftOVN.createACL(acl)
```

### Flow Management with OVS

```swift
// Build OpenFlow rules using the flow builder
let flow = ovsManager.flowBuilder()
    .table(0)
    .priority(1000)
    .match("in_port=1,dl_type=0x0800")
    .actions("output:2")
    .idleTimeout(300)
    .build()

// Note: Flow operations typically require ovs-ofctl commands
// This package focuses on OVSDB operations
```

## Error Handling

The package provides comprehensive error handling:

```swift
do {
    try await SwiftOVN.connect()
    let switches = try await SwiftOVN.getLogicalSwitches()
} catch SwiftOVNError.connectionFailed(let message) {
    print("Connection failed: \(message)")
} catch SwiftOVNError.timeoutError {
    print("Operation timed out")
} catch SwiftOVNError.rpcError(let rpcError) {
    print("RPC Error: \(rpcError.message)")
} catch {
    print("Unexpected error: \(error)")
}
```

## Database Support

### OVN Databases
- **Northbound**: High-level logical network configuration
- **Southbound**: Low-level physical network state

### OVS Database
- **Open_vSwitch**: Configuration and state of Open vSwitch instances

## Requirements

- Swift 5.9+
- SwiftNIO 2.65.0+
- Access to OVN/OVS Unix domain sockets

## Contributing

1. Fork the repository
2. Create a feature branch
3. Add tests for new functionality
4. Ensure all tests pass
5. Submit a pull request

## License

This package is released under the MIT License. See [LICENSE](LICENSE) for details.

## Acknowledgments

- [Open Virtual Network (OVN)](https://www.ovn.org/)
- [Open vSwitch](https://www.openvswitch.org/)
- [SwiftNIO](https://github.com/apple/swift-nio)
- [RFC 7047 - OVSDB Management Protocol](https://tools.ietf.org/html/rfc7047)
