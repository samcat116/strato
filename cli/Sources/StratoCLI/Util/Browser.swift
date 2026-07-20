import Foundation

/// Best-effort `open`/`xdg-open` of the verification URL. On headless hosts
/// (no DISPLAY, SSH session) the printed URL is the fallback, so failures are
/// silently ignored.
enum Browser {
    static func open(_ url: String) {
        #if os(macOS)
        let command = "/usr/bin/open"
        let isLocal = true
        #else
        let command = "/usr/bin/xdg-open"
        let environment = ProcessInfo.processInfo.environment
        let isLocal = environment["DISPLAY"] != nil || environment["WAYLAND_DISPLAY"] != nil
        #endif

        guard isLocal, FileManager.default.isExecutableFile(atPath: command) else { return }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: command)
        process.arguments = [url]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
    }
}
