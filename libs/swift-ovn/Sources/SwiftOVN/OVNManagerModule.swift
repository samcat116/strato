// Main module file that provides package documentation and overview

import Foundation
import NIO
import Logging

// This module provides a comprehensive Swift library for managing OVN (Open Virtual Network) 
// and OVS (Open vSwitch) through their JSON-RPC APIs over Unix domain sockets.
//
// Key Features:
// - Type-safe Swift models for all OVN and OVS database schemas
// - SwiftNIO-based high-performance Unix socket communication
// - Async/await API design with modern Swift concurrency
// - Real-time monitoring capabilities via AsyncSequence
// - Cross-platform compatibility (Linux, macOS, etc.)
// - Comprehensive error handling
//
// Example Usage:
//
//     import OVNManager
//
//     // Connect to OVN Northbound database
//     let ovnManager = OVNManager(socketPath: "/var/run/ovn/ovnnb_db.sock")
//     try await ovnManager.connect()
//
//     // Create a logical switch
//     let switch = OVNLogicalSwitch(name: "my-switch")
//     let switchUUID = try await ovnManager.createLogicalSwitch(switch)
//
//     // Monitor changes
//     for try await update in ovnManager.monitorUpdates() {
//         print("Database updated: \(update)")
//     }
//
//     // Connect to OVS database
//     let ovsManager = OVSManager(socketPath: "/var/run/openvswitch/db.sock")
//     try await ovsManager.connect()
//
//     // Create a bridge
//     let bridge = OVSBridge(name: "br-int")
//     let bridgeUUID = try await ovsManager.createBridge(bridge)