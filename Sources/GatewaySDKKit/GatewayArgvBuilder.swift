import Foundation

/// Turns a request for a `command` operation into an argv array.
///
/// `values get` with `spreadsheet-id` and `range` becomes
/// `["values", "get", "--spreadsheet-id", "X", "--range", "A1:B2"]`. Selection is
/// ignored: command gateways return opaque JSON.
public enum GatewayArgvBuilder {
  public static func build(
    _ request: GatewayOperationRequest,
    catalog: GatewaySchemaCatalog
  ) throws -> [String] {
    guard let operation = catalog.operation(named: request.operation) else {
      throw GatewaySDKError.unknownOperation(name: request.operation)
    }
    guard operation.kind == .command else {
      throw GatewaySDKError.graphQLOperationNeedsDocument(name: operation.name)
    }

    try GatewayVariableBinding.validate(request.variables, against: operation, catalog: catalog)

    var argv = operation.name.split(separator: " ").map(String.init)
    for argument in operation.arguments {
      guard let value = request.variables[argument.name] else { continue }
      argv += try flag(argument.name, value: value)
    }
    return argv
  }

  private static func flag(_ name: String, value: GatewayJSONValue) throws -> [String] {
    switch value {
    case .null:
      // A non-required flag explicitly set to null is simply not passed.
      return []
    case .bool(let flag):
      return flag ? ["--\(name)"] : []
    case .array(let elements):
      var argv: [String] = []
      for element in elements {
        // Booleans inside a list have no bare-flag spelling, so render them as text.
        argv += ["--\(name)", try scalarText(element)]
      }
      return argv
    default:
      return ["--\(name)", try scalarText(value)]
    }
  }

  private static func scalarText(_ value: GatewayJSONValue) throws -> String {
    switch value {
    case .string(let text): return text
    case .int(let number): return String(number)
    case .double(let number): return String(describing: number)
    case .bool(let flag): return flag ? "true" : "false"
    case .null: return "null"
    case .array, .object: return try value.jsonString()
    }
  }
}
