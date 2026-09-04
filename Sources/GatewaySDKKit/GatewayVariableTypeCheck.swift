import Foundation

/// The lightweight variable type check shared by the document builder, the argv
/// builder, and the variable inliner.
///
/// It is deliberately permissive where GraphQL itself coerces (single values against
/// list types, ints against `Float`) and opaque for `JSON`, so a gateway keeps its own
/// authoritative validation.
public enum GatewayVariableTypeCheck {
  /// Throws `GatewaySDKError.variableTypeMismatch` when `value` cannot be passed for a
  /// variable of type `type`. `name` labels the outermost variable in the message.
  public static func check(
    _ value: GatewayJSONValue,
    against type: GatewayTypeRef,
    name: String,
    catalog: GatewaySchemaCatalog
  ) throws {
    guard matches(value, type, catalog) else {
      throw GatewaySDKError.variableTypeMismatch(
        name: name,
        expected: type.graphQLString,
        actual: value.kindName
      )
    }
  }

  /// Non-throwing form, used by the check above and by callers that only need a verdict.
  public static func matches(
    _ value: GatewayJSONValue,
    _ type: GatewayTypeRef,
    _ catalog: GatewaySchemaCatalog
  ) -> Bool {
    // A non-finite double has no JSON or GraphQL spelling, so it can never reach a
    // gateway intact whatever the declared type says (JSON included). Rejecting it here
    // means the argv builder and the inliner cannot render `inf`/`nan` downstream.
    if case .double(let number) = value, !number.isFinite { return false }

    if case .nonNull(let inner) = type {
      if case .null = value { return false }
      return matches(value, inner, catalog)
    }
    if case .null = value { return true }

    if case .list(let element) = type {
      if case .array(let elements) = value {
        return elements.allSatisfy { matches($0, element, catalog) }
      }
      // GraphQL coerces a single value into a one-element list.
      return matches(value, element, catalog)
    }

    let typeName = type.namedTypeName
    switch typeName {
    case "ID", "String":
      if case .string = value { return true }
      return false
    case "Int":
      if case .int = value { return true }
      return false
    case "Float":
      switch value {
      case .int, .double: return true
      default: return false
      }
    case "Boolean":
      if case .bool = value { return true }
      return false
    case "JSON":
      return true
    default:
      break
    }

    guard let named = catalog.namedType(typeName) else { return false }
    switch named.kind {
    case .scalar:
      // Custom scalars carry no wire contract in the catalog, so anything non-null goes.
      return true
    case .enumeration(let values):
      guard case .string(let text) = value else { return false }
      return values.contains(text)
    case .object:
      // Objects are output types; they never appear as a variable type.
      return false
    case .inputObject(let fields):
      guard case .object(let members) = value else { return false }
      let byName = Dictionary(uniqueKeysWithValues: fields.map { ($0.name, $0) })
      for (key, member) in members {
        guard let field = byName[key] else { return false }
        guard matches(member, field.type, catalog) else { return false }
      }
      for field in fields where field.defaultValue == nil {
        let isRequired = field.isRequired || field.type.isRequired
        guard isRequired else { continue }
        guard let supplied = members[field.name], !supplied.isNull else { return false }
      }
      return true
    }
  }
}

extension GatewayJSONValue {
  var isNull: Bool {
    if case .null = self { return true }
    return false
  }
}
