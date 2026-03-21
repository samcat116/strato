import Foundation

public struct OVSDBOperation: Codable {
    public let op: String
    public let table: String
    public let whereConditions: [OVSDBCondition]?
    public let columns: [String]?
    public let rows: [OVSDBRow]?
    public let row: OVSDBRow?
    public let mutations: [OVSDBMutation]?
    
    private enum CodingKeys: String, CodingKey {
        case op, table, columns, rows, row, mutations
        case whereConditions = "where"
    }
    
    public init(op: String, table: String, whereConditions: [OVSDBCondition]? = nil, columns: [String]? = nil, rows: [OVSDBRow]? = nil, row: OVSDBRow? = nil, mutations: [OVSDBMutation]? = nil) {
        self.op = op
        self.table = table
        self.whereConditions = whereConditions
        self.columns = columns
        self.rows = rows
        self.row = row
        self.mutations = mutations
    }
}