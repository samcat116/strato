import Foundation

/// The lifecycle mutations recorded for asynchronous resource operations.
enum VMOperationKind: String, Codable, CaseIterable, Sendable {
    case create
    case boot
    case shutdown
    case reboot
    case pause
    case resume
    case delete
    case resize
    case snapshot
    case snapshotDelete = "snapshot_delete"
    case restore
    case snapshotExport = "snapshot_export"
    case attach
    case detach
    case throttle
    case run
}

/// Terminal-or-not state of an asynchronous operation.
enum VMOperationStatus: String, Codable, CaseIterable, Sendable {
    case pending
    case succeeded
    case failed

    var isTerminal: Bool { self != .pending }
}

/// The backing transport for a VM serial or virtio console.
enum ConsoleMode: String, Codable, CaseIterable, Sendable {
    case off = "Off"
    case pty = "Pty"
    case tty = "Tty"
    case file = "File"
    case socket = "Socket"
    case null = "Null"
}
