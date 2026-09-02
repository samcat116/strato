import Foundation
import Testing

@testable import App

@Suite("Control-plane operation enums")
struct OperationEnumTests {
    @Test("Console modes reject graphics values")
    func consoleModeRejectsGraphicsValue() {
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode([ConsoleMode].self, from: Data(#"["Vnc"]"#.utf8))
        }
    }
}
