import Foundation
import PostgresNIO

/// A small, PostgresNIO-native SQL interpolation type used while Strato's
/// domain stores move behind intent-oriented persistence modules.
///
/// Values are always bindings. Raw fragments and identifiers require explicit
/// labels so dynamic query structure remains visible during review.
public struct PostgresSQLQuery: ExpressibleByStringInterpolation, ExpressibleByStringLiteral, Sendable {
    fileprivate enum Fragment: Sendable {
        case literal(String)
        case binding(@Sendable (inout PostgresBindings) throws -> Void)
    }

    fileprivate var fragments: [Fragment]

    public init(stringLiteral value: String) {
        self.fragments = [.literal(value)]
    }

    public init(stringInterpolation: StringInterpolation) {
        self.fragments = stringInterpolation.fragments
    }

    public struct StringInterpolation: StringInterpolationProtocol, Sendable {
        fileprivate var fragments: [Fragment]

        public init(literalCapacity: Int, interpolationCount: Int) {
            self.fragments = []
            self.fragments.reserveCapacity(interpolationCount * 2 + 1)
        }

        public mutating func appendLiteral(_ literal: String) {
            fragments.append(.literal(literal))
        }

        public mutating func appendInterpolation<Value>(bind value: Value)
        where Value: PostgresThrowingDynamicTypeEncodable & Sendable {
            fragments.append(.binding { bindings in
                try bindings.append(value)
            })
        }

        public mutating func appendInterpolation<Value>(bind value: Value?)
        where Value: PostgresThrowingDynamicTypeEncodable & Sendable {
            fragments.append(.binding { bindings in
                try bindings.append(value)
            })
        }

        public mutating func appendInterpolation(unsafeRaw value: String) {
            fragments.append(.literal(value))
        }

        public mutating func appendInterpolation(ident value: String) {
            fragments.append(.literal("\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""))
        }

        public mutating func appendInterpolation(_ query: PostgresSQLQuery) {
            fragments.append(contentsOf: query.fragments)
        }
    }

    public static func += (lhs: inout PostgresSQLQuery, rhs: PostgresSQLQuery) {
        lhs.fragments.append(contentsOf: rhs.fragments)
    }

    public func postgresQuery() throws -> PostgresQuery {
        var sql = ""
        var bindings = PostgresBindings(capacity: fragments.count)
        for fragment in fragments {
            switch fragment {
            case .literal(let literal):
                sql.append(literal)
            case .binding(let append):
                try append(&bindings)
                sql.append("$\(bindings.count)")
            }
        }
        return PostgresQuery(unsafeSQL: sql, binds: bindings)
    }
}

/// The stable portion of database failures that application policy needs.
/// Unknown Postgres errors remain the original `PSQLError` for logging.
public protocol PostgresConstraintError: Error {
    var isConstraintFailure: Bool { get }
}

extension PSQLError: PostgresConstraintError {
    public var isConstraintFailure: Bool {
        serverInfo?[.sqlState]?.hasPrefix("23") == true
    }
}

/// Decode a private persistence record directly from a PostgresNIO row.
public enum PostgresRecordDecoder {
    public static func decode<Value: Decodable>(
        _ type: Value.Type,
        from row: PostgresRow
    ) throws -> Value {
        try Value(from: RowDecoder(row: row.makeRandomAccess()))
    }
}

private struct RowDecoder: Decoder {
    let row: PostgresRandomAccessRow
    let codingPath: [any CodingKey] = []
    let userInfo: [CodingUserInfoKey: Any] = [:]

    func container<Key: CodingKey>(keyedBy type: Key.Type) throws -> KeyedDecodingContainer<Key> {
        KeyedDecodingContainer(RowKeyedContainer<Key>(row: row))
    }

    func unkeyedContainer() throws -> any UnkeyedDecodingContainer {
        throw DecodingError.typeMismatch(
            [Any].self,
            .init(codingPath: codingPath, debugDescription: "PostgreSQL records require keyed decoding")
        )
    }

    func singleValueContainer() throws -> any SingleValueDecodingContainer {
        throw DecodingError.typeMismatch(
            Any.self,
            .init(codingPath: codingPath, debugDescription: "PostgreSQL records require keyed decoding")
        )
    }
}

private struct RowKeyedContainer<Key: CodingKey>: KeyedDecodingContainerProtocol {
    let row: PostgresRandomAccessRow
    let codingPath: [any CodingKey] = []
    var allKeys: [Key] { row.compactMap { Key(stringValue: $0.columnName) } }

    func contains(_ key: Key) -> Bool { row.contains(key.stringValue) }

    func decodeNil(forKey key: Key) throws -> Bool {
        try cell(for: key).bytes == nil
    }

    func decode(_ type: Bool.Type, forKey key: Key) throws -> Bool { try decodeCell(type, forKey: key) }
    func decode(_ type: String.Type, forKey key: Key) throws -> String { try decodeCell(type, forKey: key) }
    func decode(_ type: Double.Type, forKey key: Key) throws -> Double { try decodeCell(type, forKey: key) }
    func decode(_ type: Float.Type, forKey key: Key) throws -> Float { try decodeCell(type, forKey: key) }
    func decode(_ type: Int.Type, forKey key: Key) throws -> Int { try decodeCell(type, forKey: key) }
    func decode(_ type: Int8.Type, forKey key: Key) throws -> Int8 {
        Int8(try decodeCell(Int16.self, forKey: key))
    }
    func decode(_ type: Int16.Type, forKey key: Key) throws -> Int16 { try decodeCell(type, forKey: key) }
    func decode(_ type: Int32.Type, forKey key: Key) throws -> Int32 { try decodeCell(type, forKey: key) }
    func decode(_ type: Int64.Type, forKey key: Key) throws -> Int64 { try decodeCell(type, forKey: key) }
    func decode(_ type: UInt.Type, forKey key: Key) throws -> UInt { UInt(try decode(Int64.self, forKey: key)) }
    func decode(_ type: UInt8.Type, forKey key: Key) throws -> UInt8 { UInt8(try decode(Int64.self, forKey: key)) }
    func decode(_ type: UInt16.Type, forKey key: Key) throws -> UInt16 { UInt16(try decode(Int64.self, forKey: key)) }
    func decode(_ type: UInt32.Type, forKey key: Key) throws -> UInt32 { UInt32(try decode(Int64.self, forKey: key)) }
    func decode(_ type: UInt64.Type, forKey key: Key) throws -> UInt64 { UInt64(try decode(Int64.self, forKey: key)) }

    func decode<Value: Decodable>(_ type: Value.Type, forKey key: Key) throws -> Value {
        let value: Any
        switch type {
        case is UUID.Type:
            value = try decodeCell(UUID.self, forKey: key)
        case is Date.Type:
            value = try decodeCell(Date.self, forKey: key)
        case is [String].Type:
            value = try decodeCell([String].self, forKey: key)
        case is [UUID].Type:
            value = try decodeCell([UUID].self, forKey: key)
        case is [Int].Type:
            value = try decodeCell([Int].self, forKey: key)
        case is Data.Type:
            value = try decodeCell(Data.self, forKey: key)
        default:
            // RawRepresentable enums synthesized by Codable request a single
            // primitive value. Decode that value from the cell without making
            // every application enum conform to PostgresDecodable.
            return try Value(from: CellDecoder(cell: try cell(for: key), codingPath: codingPath + [key]))
        }
        return value as! Value
    }

    func nestedContainer<NestedKey: CodingKey>(
        keyedBy type: NestedKey.Type,
        forKey key: Key
    ) throws -> KeyedDecodingContainer<NestedKey> {
        throw unsupportedContainer(for: key)
    }

    func nestedUnkeyedContainer(forKey key: Key) throws -> any UnkeyedDecodingContainer {
        throw unsupportedContainer(for: key)
    }

    func superDecoder() throws -> any Decoder { RowDecoder(row: row) }
    func superDecoder(forKey key: Key) throws -> any Decoder { RowDecoder(row: row) }

    private func cell(for key: Key) throws -> PostgresCell {
        guard row.contains(key.stringValue) else {
            throw DecodingError.keyNotFound(
                key,
                .init(codingPath: codingPath, debugDescription: "Column \(key.stringValue) is absent")
            )
        }
        return row[key.stringValue]
    }

    private func decodeCell<Value: PostgresDecodable>(
        _ type: Value.Type,
        forKey key: Key
    ) throws -> Value {
        try cell(for: key).decode(type)
    }

    private func unsupportedContainer(for key: Key) -> DecodingError {
        .typeMismatch(
            Any.self,
            .init(
                codingPath: codingPath + [key],
                debugDescription: "Nested PostgreSQL record containers are unsupported"
            )
        )
    }
}

private struct CellDecoder: Decoder {
    let cell: PostgresCell
    let codingPath: [any CodingKey]
    let userInfo: [CodingUserInfoKey: Any] = [:]

    func container<Key: CodingKey>(keyedBy type: Key.Type) throws -> KeyedDecodingContainer<Key> {
        throw unsupported()
    }

    func unkeyedContainer() throws -> any UnkeyedDecodingContainer { throw unsupported() }

    func singleValueContainer() throws -> any SingleValueDecodingContainer {
        CellSingleValueContainer(cell: cell, codingPath: codingPath)
    }

    private func unsupported() -> DecodingError {
        .typeMismatch(
            Any.self,
            .init(codingPath: codingPath, debugDescription: "PostgreSQL cells are scalar values")
        )
    }
}

private struct CellSingleValueContainer: SingleValueDecodingContainer {
    let cell: PostgresCell
    let codingPath: [any CodingKey]

    func decodeNil() -> Bool { cell.bytes == nil }
    func decode(_ type: Bool.Type) throws -> Bool { try cell.decode(type) }
    func decode(_ type: String.Type) throws -> String { try cell.decode(type) }
    func decode(_ type: Double.Type) throws -> Double { try cell.decode(type) }
    func decode(_ type: Float.Type) throws -> Float { try cell.decode(type) }
    func decode(_ type: Int.Type) throws -> Int { try cell.decode(type) }
    func decode(_ type: Int8.Type) throws -> Int8 { Int8(try cell.decode(Int16.self)) }
    func decode(_ type: Int16.Type) throws -> Int16 { try cell.decode(type) }
    func decode(_ type: Int32.Type) throws -> Int32 { try cell.decode(type) }
    func decode(_ type: Int64.Type) throws -> Int64 { try cell.decode(type) }
    func decode(_ type: UInt.Type) throws -> UInt { UInt(try cell.decode(Int64.self)) }
    func decode(_ type: UInt8.Type) throws -> UInt8 { UInt8(try cell.decode(Int64.self)) }
    func decode(_ type: UInt16.Type) throws -> UInt16 { UInt16(try cell.decode(Int64.self)) }
    func decode(_ type: UInt32.Type) throws -> UInt32 { UInt32(try cell.decode(Int64.self)) }
    func decode(_ type: UInt64.Type) throws -> UInt64 { UInt64(try cell.decode(Int64.self)) }

    func decode<Value: Decodable>(_ type: Value.Type) throws -> Value {
        switch type {
        case is UUID.Type: return try cell.decode(UUID.self) as! Value
        case is Date.Type: return try cell.decode(Date.self) as! Value
        case is Data.Type: return try cell.decode(Data.self) as! Value
        default: return try Value(from: CellDecoder(cell: cell, codingPath: codingPath))
        }
    }
}
