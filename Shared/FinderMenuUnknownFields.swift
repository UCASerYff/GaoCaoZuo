import Foundation

/// Unknown menu configuration fields survive a read/edit/write cycle. They are
/// inert data and never interpreted as action IDs or executable instructions.
enum FinderJSONValue: Codable, Equatable {
    case null, bool(Bool), integer(Int64), unsigned(UInt64), number(Decimal), string(String), array([FinderJSONValue]), object([String:FinderJSONValue])
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let value = try? c.decode(Bool.self) { self = .bool(value) }
        else if let value = try? c.decode(String.self) { self = .string(value) }
        else if let value = try? c.decode(Int64.self) { self = .integer(value) }
        else if let value = try? c.decode(UInt64.self) { self = .unsigned(value) }
        else if let value = try? c.decode(Decimal.self) { self = .number(value) }
        else if let value = try? c.decode([FinderJSONValue].self) { self = .array(value) }
        else { self = .object(try c.decode([String:FinderJSONValue].self)) }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self { case .null: try c.encodeNil(); case .bool(let v): try c.encode(v); case .integer(let v): try c.encode(v); case .unsigned(let v): try c.encode(v); case .number(let v): try c.encode(v); case .string(let v): try c.encode(v); case .array(let v): try c.encode(v); case .object(let v): try c.encode(v) }
    }
}
struct FinderCodingKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init(_ value: String) { stringValue = value }
    init?(stringValue: String) { self.init(stringValue) }
    init?(intValue: Int) { return nil }
}
extension KeyedDecodingContainer where Key == FinderCodingKey {
    func unknown(excluding known: Set<String>) throws -> [String:FinderJSONValue] {
        var result: [String:FinderJSONValue] = [:]
        for key in allKeys where !known.contains(key.stringValue) { result[key.stringValue] = try decode(FinderJSONValue.self, forKey: key) }
        return result
    }
}
