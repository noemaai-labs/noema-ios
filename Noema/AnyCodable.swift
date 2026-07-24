import Foundation

public struct AnyCodable: Codable, Equatable, @unchecked Sendable {
    let value: Any
    public init(_ value: Any) { self.value = value }
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let v = try? c.decode(Bool.self) { value = v; return }
        if let v = try? c.decode(Int.self) { value = v; return }
        if let v = try? c.decode(Double.self) { value = v; return }
        if let v = try? c.decode(String.self) { value = v; return }
        if let v = try? c.decode([String: AnyCodable].self) { value = v.mapValues { $0.value }; return }
        if let v = try? c.decode([AnyCodable].self) { value = v.map { $0.value }; return }
        throw DecodingError.dataCorruptedError(in: c, debugDescription: "Unsupported type")
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch value {
        case let v as Bool: try c.encode(v)
        case let v as Int: try c.encode(v)
        case let v as Double: try c.encode(v)
        case let v as String: try c.encode(v)
        case let v as [String: Any]:
            try c.encode(v.mapValues { AnyCodable($0) })
        case let v as [Any]:
            try c.encode(v.map { AnyCodable($0) })
        default:
            try c.encodeNil()
        }
    }
    
    public static func == (lhs: AnyCodable, rhs: AnyCodable) -> Bool {
        // Compare the underlying values using a type-safe approach
        switch (lhs.value, rhs.value) {
        case let (l as Bool, r as Bool): return l == r
        case let (l as Int, r as Int): return l == r
        case let (l as Double, r as Double): return l == r
        case let (l as String, r as String): return l == r
        case let (l as [String: Any], r as [String: Any]):
            // Compare dictionaries by converting to AnyCodable and recursing
            guard l.keys == r.keys else { return false }
            return l.allSatisfy { key, value in
                guard let rValue = r[key] else { return false }
                return AnyCodable(value) == AnyCodable(rValue)
            }
        case let (l as [Any], r as [Any]):
            // Compare arrays by converting to AnyCodable and recursing
            guard l.count == r.count else { return false }
            return zip(l, r).allSatisfy { AnyCodable($0) == AnyCodable($1) }
        default:
            // For unsupported types or nil values, compare by string representation
            return String(describing: lhs.value) == String(describing: rhs.value)
        }
    }
}

extension CodingUserInfoKey { static let anyCodableDecoding = CodingUserInfoKey(rawValue: "anyCodable")! }


