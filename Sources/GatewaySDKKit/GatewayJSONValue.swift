import Foundation

/// A JSON value with stable, key-sorted serialization.
///
/// The kit passes gateway variables around as `GatewayJSONValue` so that document
/// building, argv building, and literal rendering all see the same value model, and so
/// that serialized output is byte-stable regardless of dictionary ordering.
public enum GatewayJSONValue: Codable, Sendable, Equatable, Hashable {
  case null
  case bool(Bool)
  case int(Int)
  case double(Double)
  case string(String)
  case array([GatewayJSONValue])
  case object([String: GatewayJSONValue])

  // MARK: - Bridging from Any

  /// Builds a value from `JSONSerialization` output (or hand-built Swift values).
  ///
  /// NSNumber discrimination goes through `objCType` rather than `is Bool` casts: on
  /// Darwin every `NSNumber` bridges successfully to `Bool`, so a cast-based check
  /// misclassifies `1` as `true`. `objCType` behaves the same on Darwin and on
  /// swift-corelibs-foundation, which keeps the package Linux-clean.
  public init(any value: Any) throws {
    switch value {
    case let existing as GatewayJSONValue:
      self = existing
    case is NSNull:
      self = .null
    case let bool as Bool where type(of: value) == Bool.self:
      self = .bool(bool)
    case let int as Int where type(of: value) == Int.self:
      self = .int(int)
    case let double as Double where type(of: value) == Double.self:
      self = .double(double)
    case let string as String:
      self = .string(string)
    case let number as NSNumber:
      self = try GatewayJSONValue(number: number)
    case let array as [Any]:
      self = .array(try array.map { try GatewayJSONValue(any: $0) })
    case let object as [String: Any]:
      var result: [String: GatewayJSONValue] = [:]
      result.reserveCapacity(object.count)
      for (key, element) in object {
        result[key] = try GatewayJSONValue(any: element)
      }
      self = .object(result)
    default:
      throw GatewaySDKError.invalidJSONValue("unsupported value of type \(type(of: value))")
    }
  }

  private init(number: NSNumber) throws {
    let code = String(cString: number.objCType)
    switch code {
    case "c", "B":
      self = .bool(number.boolValue)
    case "i", "s", "l", "q":
      // Go through int64Value, not doubleValue: converting 2^53 + 1 to Double first
      // would silently round it to 2^53 and still be Int-representable.
      if let exact = Int(exactly: number.int64Value) {
        self = .int(exact)
      } else {
        self = .double(number.doubleValue)
      }
    case "C", "S", "L", "Q":
      if let exact = Int(exactly: number.uint64Value) {
        self = .int(exact)
      } else {
        self = .double(number.doubleValue)
      }
    case "f", "d":
      self = .double(number.doubleValue)
    default:
      throw GatewaySDKError.invalidJSONValue("unsupported NSNumber type '\(code)'")
    }
  }

  /// The inverse of `init(any:)`: a Foundation-compatible object graph.
  public var anyValue: Any {
    switch self {
    case .null:
      return NSNull()
    case .bool(let value):
      return value
    case .int(let value):
      return value
    case .double(let value):
      return value
    case .string(let value):
      return value
    case .array(let values):
      return values.map { $0.anyValue }
    case .object(let values):
      var result: [String: Any] = [:]
      result.reserveCapacity(values.count)
      for (key, value) in values {
        result[key] = value.anyValue
      }
      return result
    }
  }

  // MARK: - Parsing and serialization

  /// Parses a JSON document or fragment.
  public static func parse(_ json: String) throws -> GatewayJSONValue {
    guard let data = json.data(using: .utf8) else {
      throw GatewaySDKError.invalidJSON("input is not valid UTF-8")
    }
    let object: Any
    do {
      object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    } catch {
      throw GatewaySDKError.invalidJSON(String(describing: error))
    }
    return try GatewayJSONValue(any: object)
  }

  /// Serializes the value with object keys sorted ascending.
  ///
  /// Hand-written rather than `JSONSerialization` so that key ordering, number
  /// rendering, and escaping are pinned by this package instead of by the platform.
  public func jsonString(pretty: Bool = false) throws -> String {
    var out = ""
    Self.write(self, into: &out, pretty: pretty, indent: 0)
    return out
  }

  private static func write(_ value: GatewayJSONValue, into out: inout String, pretty: Bool, indent: Int) {
    switch value {
    case .null:
      out += "null"
    case .bool(let flag):
      out += flag ? "true" : "false"
    case .int(let number):
      out += String(number)
    case .double(let number):
      out += String(describing: number)
    case .string(let text):
      out += escaped(text)
    case .array(let elements):
      if elements.isEmpty {
        out += "[]"
        return
      }
      out += "["
      let inner = indent + 1
      for (offset, element) in elements.enumerated() {
        if offset > 0 { out += "," }
        if pretty {
          out += "\n" + String(repeating: "  ", count: inner)
        }
        write(element, into: &out, pretty: pretty, indent: inner)
      }
      if pretty {
        out += "\n" + String(repeating: "  ", count: indent)
      }
      out += "]"
    case .object(let members):
      if members.isEmpty {
        out += "{}"
        return
      }
      out += "{"
      let inner = indent + 1
      let sorted = members.sorted { $0.key < $1.key }
      for (offset, member) in sorted.enumerated() {
        if offset > 0 { out += "," }
        if pretty {
          out += "\n" + String(repeating: "  ", count: inner)
        }
        out += escaped(member.key)
        out += pretty ? ": " : ":"
        write(member.value, into: &out, pretty: pretty, indent: inner)
      }
      if pretty {
        out += "\n" + String(repeating: "  ", count: indent)
      }
      out += "}"
    }
  }

  private static func escaped(_ text: String) -> String {
    var out = "\""
    for scalar in text.unicodeScalars {
      switch scalar {
      case "\"":
        out += "\\\""
      case "\\":
        out += "\\\\"
      case "\n":
        out += "\\n"
      case "\r":
        out += "\\r"
      case "\t":
        out += "\\t"
      default:
        if scalar.value < 0x20 {
          out += String(format: "\\u%04x", scalar.value)
        } else {
          out.unicodeScalars.append(scalar)
        }
      }
    }
    out += "\""
    return out
  }

  // MARK: - Codable

  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    if container.decodeNil() {
      self = .null
    } else if let value = try? container.decode(Bool.self) {
      self = .bool(value)
    } else if let value = try? container.decode(Int.self) {
      self = .int(value)
    } else if let value = try? container.decode(Double.self) {
      self = .double(value)
    } else if let value = try? container.decode(String.self) {
      self = .string(value)
    } else if let value = try? container.decode([GatewayJSONValue].self) {
      self = .array(value)
    } else if let value = try? container.decode([String: GatewayJSONValue].self) {
      self = .object(value)
    } else {
      throw DecodingError.dataCorruptedError(
        in: container,
        debugDescription: "value is not valid JSON"
      )
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .null:
      try container.encodeNil()
    case .bool(let value):
      try container.encode(value)
    case .int(let value):
      try container.encode(value)
    case .double(let value):
      try container.encode(value)
    case .string(let value):
      try container.encode(value)
    case .array(let value):
      try container.encode(value)
    case .object(let value):
      try container.encode(value)
    }
  }

  // MARK: - Diagnostics

  /// A short word naming the value's kind, used in `variableTypeMismatch` messages.
  public var kindName: String {
    switch self {
    case .null: return "null"
    case .bool: return "bool"
    case .int: return "int"
    case .double: return "double"
    case .string: return "string"
    case .array: return "array"
    case .object: return "object"
    }
  }
}
