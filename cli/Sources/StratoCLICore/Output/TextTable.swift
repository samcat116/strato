import Foundation

/// Minimal fixed-width table renderer for human output.
public struct TextTable: Sendable {
    private let headers: [String]
    private var rows: [[String]] = []

    public init(headers: [String]) {
        self.headers = headers
    }

    public mutating func addRow(_ cells: [String]) {
        rows.append(cells)
    }

    public func render() -> String {
        var widths = headers.map(\.count)
        for row in rows {
            for (index, cell) in row.enumerated() where index < widths.count {
                widths[index] = max(widths[index], cell.count)
            }
        }

        func line(_ cells: [String]) -> String {
            cells.enumerated()
                .map { index, cell in
                    index < widths.count ? cell.padding(toLength: widths[index], withPad: " ", startingAt: 0) : cell
                }
                .joined(separator: "  ")
                // padding(toLength:) leaves trailing spaces on the last column
                .replacingOccurrences(of: " +$", with: "", options: .regularExpression)
        }

        var output = [line(headers.map { $0.uppercased() })]
        output.append(contentsOf: rows.map(line))
        return output.joined(separator: "\n")
    }
}
