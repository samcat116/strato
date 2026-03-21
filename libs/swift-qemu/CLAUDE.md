# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

SwiftQEMU is a Swift library for managing QEMU virtual machines via the QEMU Monitor Protocol (QMP). It provides a high-level API for creating, controlling, and monitoring QEMU processes using Swift concurrency (async/await) and SwiftNIO for networking.

## Build and Test Commands

```bash
# Build the project
swift build

# Run tests
swift test

# Build in release mode
swift build -c release

# Run specific test
swift test --filter QMPProtocolTests
```

## Architecture

### Core Components

**QEMUManager** (Sources/SwiftQEMU/QEMUManager.swift)
- High-level API that coordinates process and QMP management
- Manages VM lifecycle: create, start, pause, reset, shutdown, destroy
- Tracks VM status (stopped, creating, running, paused, shuttingDown, unknown)
- Actor-based for thread-safe concurrent access

**QEMUProcess** (Sources/SwiftQEMU/QEMUProcess.swift)
- Manages the QEMU process lifecycle using Foundation's Process API
- Builds QEMU command-line arguments from QEMUConfiguration
- Handles QMP Unix socket creation and readiness with retry logic (up to 10 seconds)
- **Critical fix**: Redirects stdout/stderr to prevent pipe buffer overflow crashes
  - If `ENABLE_QEMU_PROCESS_LOG_FILES=true` (or `yes`, `1`): outputs to `/tmp/qemu-*.log`
  - Otherwise: redirects to `/dev/null` (default behavior)

**QMPClient** (Sources/SwiftQEMU/QMPClient.swift)
- Implements QMP protocol communication using SwiftNIO
- Supports Unix domain socket and TCP connections
- **Critical fix**: Implements exponential backoff retry logic (up to 10 attempts) for socket connection timing issues
- Handles QMP greeting, capability negotiation, and command execution
- Executes QMP commands: query-status, cont, stop, system_powerdown, system_reset, quit

**QMPProtocol** (Sources/SwiftQEMU/QMPProtocol.swift)
- Defines QMP message types: QMPGreeting, QMPRequest, QMPResponse, QMPEvent
- Provides type-safe QMPCommand enum for common commands
- Includes AnyCodable wrapper for type-erased JSON encoding/decoding

### Critical Reliability Fixes

The codebase includes two critical fixes for production reliability (documented in CHANGES.md):

1. **Pipe Buffer Overflow Prevention**: QEMU stdout/stderr are redirected away from pipes to prevent crashes when buffers fill up. The original implementation used `Pipe()` objects but never read from them, causing QEMU to crash with `NIOCore.IOError` when the 64KB buffer filled. Current behavior:
   - Set `ENABLE_QEMU_PROCESS_LOG_FILES=true` to capture output in `/tmp/qemu-*.log` files
   - Default behavior (when env var not set): redirects to `/dev/null`
   - **Never** redirects to Pipe() objects without active reading

2. **QMP Connection Retry Logic**:
   - QEMUProcess waits up to 10 seconds (20 retries × 0.5s) for QMP socket file creation
   - QMPClient retries connection up to 10 times with exponential backoff (0.1s, 0.2s, 0.4s, 0.8s, max 1s)
   - Handles timing issues where socket file exists but isn't ready for connections

### Configuration Types

**QEMUConfiguration**: Main VM configuration
- Machine type, CPU type/count, memory
- KVM acceleration support
- Disks (QEMUDisk): path, format (qcow2/raw), interface (virtio/ide)
- Networks (QEMUNetwork): backend (user/tap/bridge), model (virtio-net-pci)
- Kernel, initrd, and kernel arguments for direct kernel boot
- Display options (noGraphic flag)
- Start paused option for controlled initialization

### Concurrency Model

- QEMUManager is an actor for thread-safe state management
- QEMUProcess uses @unchecked Sendable (process management is inherently thread-unsafe)
- QMPClient uses @unchecked Sendable (manages its own thread safety via SwiftNIO EventLoopGroup)
- All async operations use Swift's async/await and structured concurrency

### Dependencies

- swift-nio: Async networking for QMP socket communication
- swift-log: Structured logging throughout the library

## Development Notes

### Environment Variables

**ENABLE_QEMU_PROCESS_LOG_FILES**: Controls QEMU process output handling
- Set to `true`, `yes`, or `1` to capture output in `/tmp/qemu-*.log` files
- When unset or any other value: redirects output to `/dev/null`
- Usage: `ENABLE_QEMU_PROCESS_LOG_FILES=true swift run`

### Testing with Real QEMU

Tests in SwiftQEMUTests primarily cover protocol encoding/decoding. Integration testing requires a QEMU installation:

```bash
# Verify QEMU is installed
which qemu-system-x86_64

# Check for KVM support (optional but recommended)
kvm-ok  # On Linux
```

### QMP Socket Debugging

When debugging QMP issues:
- Enable log files: `export ENABLE_QEMU_PROCESS_LOG_FILES=true`
- Check socket file creation: `ls -la /tmp/qemu-*.sock`
- Monitor QEMU output logs: `tail -f /tmp/qemu-*.log`
- Watch for "Connection refused" errors (indicates timing issues)
- Verify socket permissions and ownership

### Common VM Lifecycle Pattern

```swift
let manager = QEMUManager(qemuPath: "/usr/bin/qemu-system-x86_64")

var config = QEMUConfiguration()
config.memoryMB = 2048
config.cpuCount = 2
config.disks.append(QEMUDisk(path: "/path/to/disk.qcow2"))

// Create VM (starts QEMU process in paused state by default)
try await manager.createVM(config: config)

// Start VM execution
try await manager.start()

// Later: gracefully shutdown (30 second timeout, then force quit)
try await manager.shutdown()
```

### Error Handling

All errors conform to QMPError enum (Sources/SwiftQEMU/QMPError.swift):
- notConnected, connectionLost
- processNotRunning, processAlreadyRunning
- socketCreationFailed (QMP socket not created within timeout)
- invalidResponse, invalidConfiguration
- qmpError(class, description) for QMP-specific errors

### Logging

All components use swift-log with labeled loggers:
- "SwiftQEMU.QEMUManager"
- "SwiftQEMU.QEMUProcess"
- "SwiftQEMU.QMPClient"

Set log level in consuming applications to control verbosity.
