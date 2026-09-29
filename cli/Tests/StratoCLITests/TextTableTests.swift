import Testing

@testable import StratoCLICore

@Suite("TextTable")
struct TextTableTests {
    @Test("Columns align to the widest cell")
    func testAlignment() {
        var table = TextTable(headers: ["id", "name"])
        table.addRow(["1", "short"])
        table.addRow(["22", "a much longer name"])

        let rendered = table.render()
        let lines = rendered.split(separator: "\n").map(String.init)
        #expect(lines.count == 3)
        #expect(lines[0] == "ID  NAME")
        #expect(lines[1] == "1   short")
        #expect(lines[2] == "22  a much longer name")
    }

    @Test("Renders headers alone when empty")
    func testEmpty() {
        let table = TextTable(headers: ["one", "two"])
        #expect(table.render() == "ONE  TWO")
    }
}
