import Synchronization
import Vapor

/// Captures command output so tests can inspect generated credentials and
/// recovery URLs without coupling command suites to one another.
package final class CaptureConsole: Console, Sendable {
    private struct State {
        var lines: [String] = []
        var userInfo: [AnySendableHashable: any Sendable] = [:]
    }

    private let state = Mutex(State())

    package init() {}

    package var lines: [String] { state.withLock { $0.lines } }

    package var userInfo: [AnySendableHashable: any Sendable] {
        get { state.withLock { $0.userInfo } }
        set { state.withLock { $0.userInfo = newValue } }
    }

    package var size: (width: Int, height: Int) { (80, 25) }

    package func input(isSecure: Bool) -> String { "" }

    package func output(_ text: ConsoleText, newLine: Bool) {
        state.withLock { $0.lines.append(text.description) }
    }

    package func clear(_ type: ConsoleClear) {}

    package func report(error: String, newLine: Bool) {
        state.withLock { $0.lines.append(error) }
    }
}
