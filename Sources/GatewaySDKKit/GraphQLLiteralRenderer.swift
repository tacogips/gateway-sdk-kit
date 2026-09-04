import Foundation

/// Renders a JSON value as a GraphQL literal.
///
/// The declared type provides the context GraphQL needs but JSON does not carry: a
/// string whose type resolves to an enum renders bare (`ROWS`, not `"ROWS"`), and an
/// object's members are rendered against the matching input-field types.
public enum GraphQLLiteralRenderer {
  public static func render(
    _ value: GatewayJSONValue,
    as type: GatewayTypeRef?,
    catalog: GatewaySchemaCatalog
  ) -> String {
    let unwrapped = type?.unwrappingNonNull

    switch value {
    case .null:
      return "null"
    case .bool(let flag):
      return flag ? "true" : "false"
    case .int(let number):
      return String(number)
    case .double(let number):
      return String(describing: number)
    case .string(let text):
      if let unwrapped, case .named(let name) = unwrapped,
        catalog.namedType(name)?.enumValues != nil {
        return text
      }
      return quoted(text)
    case .array(let elements):
      let elementType = unwrapped?.listElementType
      let rendered = elements.map { render($0, as: elementType, catalog: catalog) }
      return "[" + rendered.joined(separator: ", ") + "]"
    case .object(let members):
      // GraphQL coerces a single value into a list, so an object against a list type is
      // rendered against that list's element type.
      let objectType = unwrapped?.listElementType?.unwrappingNonNull ?? unwrapped
      var inputFields: [String: GatewayArgument] = [:]
      if let objectType, case .named(let name) = objectType,
        let fields = catalog.namedType(name)?.inputFields {
        inputFields = Dictionary(uniqueKeysWithValues: fields.map { ($0.name, $0) })
      }
      let rendered = members.sorted { $0.key < $1.key }.map { member in
        "\(member.key): \(render(member.value, as: inputFields[member.key]?.type, catalog: catalog))"
      }
      return "{" + rendered.joined(separator: ", ") + "}"
    }
  }

  /// A GraphQL string literal: the spec's named escapes, `\u00XX` for the remaining C0
  /// controls, and every other character (including non-ASCII) raw.
  static func quoted(_ text: String) -> String {
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
      case "\u{08}":
        out += "\\b"
      case "\u{0C}":
        out += "\\f"
      default:
        if scalar.value < 0x20 {
          out += String(format: "\\u%04X", scalar.value)
        } else {
          out.unicodeScalars.append(scalar)
        }
      }
    }
    return out + "\""
  }
}
