import Foundation

/// A type-erased wrapper for JSON values, allowing dynamic dictionaries and arrays.
public struct AnyCodable: Codable, Sendable {
    public let value: Any

    public init(_ value: Any) {
        self.value = value
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let bool = try? container.decode(Bool.self) { value = bool }
        else if let int = try? container.decode(Int.self) { value = int }
        else if let double = try? container.decode(Double.self) { value = double }
        else if let string = try? container.decode(String.self) { value = string }
        else if let array = try? container.decode([AnyCodable].self) { value = array.map { $0.value } }
        else if let dictionary = try? container.decode([String: AnyCodable].self) { value = dictionary.mapValues { $0.value } }
        else if container.decodeNil() { value = NSNull() }
        else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "AnyCodable: unsupported type")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch value {
        case let bool as Bool: try container.encode(bool)
        case let int as Int: try container.encode(int)
        case let double as Double: try container.encode(double)
        case let string as String: try container.encode(string)
        case let array as [Any]: try container.encode(array.map { AnyCodable($0) })
        case let dict as [String: Any]: try container.encode(dict.mapValues { AnyCodable($0) })
        case is NSNull: try container.encodeNil()
        default:
            let mirror = Mirror(reflecting: value)
            if mirror.displayStyle == .collection {
                try container.encode(Array(mirror.children).map { AnyCodable($0.value) })
            } else {
                throw EncodingError.invalidValue(value, EncodingError.Context(codingPath: encoder.codingPath, debugDescription: "AnyCodable: cannot encode value"))
            }
        }
    }
}

extension AnyCodable: Equatable {
    public static func == (lhs: AnyCodable, rhs: AnyCodable) -> Bool {
        switch (lhs.value, rhs.value) {
        case let (a as Bool, b as Bool): return a == b
        case let (a as Int, b as Int): return a == b
        case let (a as Int64, b as Int64): return a == b
        case let (a as Double, b as Double): return a == b
        case let (a as String, b as String): return a == b
        case let (a as [Any], b as [Any]): return compareAnyArrays(a, b)
        case let (a as [String: Any], b as [String: Any]):
            guard a.count == b.count else { return false }
            for (key, val) in a {
                guard let bVal = b[key] else { return false }
                if !AnyCodable(val).isEqual(to: AnyCodable(bVal)) { return false }
            }
            return true
        case (is NSNull, is NSNull): return true
        default: return false
        }
    }
    private static func compareAnyArrays(_ lhs: [Any], _ rhs: [Any]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        for (a, b) in zip(lhs, rhs) {
            if !AnyCodable(a).isEqual(to: AnyCodable(b)) { return false }
        }
        return true
    }
}
