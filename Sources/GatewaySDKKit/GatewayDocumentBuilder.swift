import Foundation

/// A call to one catalog operation.
public struct GatewayOperationRequest: Sendable, Equatable {
  public var operation: String
  public var variables: [String: GatewayJSONValue]
  public var selection: GatewaySelection

  public init(
    operation: String,
    variables: [String: GatewayJSONValue] = [:],
    selection: GatewaySelection = .default
  ) {
    self.operation = operation
    self.variables = variables
    self.selection = selection
  }
}

/// How to select the result of a GraphQL operation.
public enum GatewaySelection: Sendable, Equatable {
  /// Generated from the result type: depth 3, cycle stop, required-argument fields skipped.
  case `default`
  /// Dot paths such as `["id", "subject", "messages.from.address"]`.
  case fields([String])
  /// A selection set such as `"{ id subject }"`, used verbatim.
  case raw(String)
}

/// A rendered GraphQL document and the variables to send alongside it.
public struct GatewayBuiltDocument: Sendable, Equatable {
  public var document: String
  public var variables: [String: GatewayJSONValue]

  public init(document: String, variables: [String: GatewayJSONValue]) {
    self.document = document
    self.variables = variables
  }
}

/// Turns an operation request into a GraphQL document with a proper variable
/// declaration list.
///
/// Variables are always passed as GraphQL variables, never inlined, so the gateway
/// keeps its own validation. Catalog default values are not injected: the gateway
/// applies its own defaults for arguments the caller omits.
public struct GatewayDocumentBuilder: Sendable {
  private let catalog: GatewaySchemaCatalog

  public init(catalog: GatewaySchemaCatalog) {
    self.catalog = catalog
  }

  public func build(_ request: GatewayOperationRequest) throws -> GatewayBuiltDocument {
    guard let operation = catalog.operation(named: request.operation) else {
      throw GatewaySDKError.unknownOperation(name: request.operation)
    }
    guard operation.kind != .command else {
      throw GatewaySDKError.commandOperationNeedsArgv(name: operation.name)
    }

    try GatewayVariableBinding.validate(
      request.variables,
      against: operation,
      catalog: catalog
    )
    let supplied = operation.arguments.filter { request.variables[$0.name] != nil }

    var lines: [String] = []
    let declarations = supplied.map { "$\($0.name): \($0.type.graphQLString)" }
    let header = declarations.isEmpty ? "" : "(" + declarations.joined(separator: ", ") + ")"
    lines.append("\(operation.kind.rawValue) \(Self.upperCamelCased(operation.name))\(header) {")

    let arguments = supplied.map { "\($0.name): $\($0.name)" }
    let call = arguments.isEmpty ? operation.name : "\(operation.name)(\(arguments.joined(separator: ", ")))"

    switch try selectionBody(for: operation, selection: request.selection) {
    case .none:
      lines.append("  \(call)")
    case .raw(let text):
      lines.append("  \(call) \(text)")
    case .nodes(let nodes):
      lines.append("  \(call) {")
      lines += GatewaySelectionPlanner.render(nodes, indent: "    ")
      lines.append("  }")
    }
    lines.append("}")

    return GatewayBuiltDocument(document: lines.joined(separator: "\n"), variables: request.variables)
  }

  private enum SelectionBody {
    case none
    case raw(String)
    case nodes([GatewaySelectionNode])
  }

  private func selectionBody(
    for operation: GatewayOperation,
    selection: GatewaySelection
  ) throws -> SelectionBody {
    if case .raw(let text) = selection {
      let trimmed = text.drop { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r" }
      guard trimmed.first == "{" else {
        throw GatewaySDKError.invalidSelectionPath(path: text)
      }
      return .raw(String(trimmed))
    }

    guard let result = operation.result else { return .none }
    let resultTypeName = result.namedTypeName
    guard !GatewaySelectionPlanner.isLeafType(resultTypeName, catalog: catalog) else { return .none }

    switch selection {
    case .default:
      let nodes = GatewaySelectionPlanner.defaultSelection(of: resultTypeName, catalog: catalog)
      return nodes.isEmpty ? .none : .nodes(nodes)
    case .fields(let paths):
      let nodes = try GatewaySelectionPlanner.selection(
        forPaths: paths,
        of: resultTypeName,
        catalog: catalog
      )
      return nodes.isEmpty ? .none : .nodes(nodes)
    case .raw:
      return .none
    }
  }

  /// `sendMessage` -> `SendMessage`, `values get` -> `ValuesGet`.
  static func upperCamelCased(_ name: String) -> String {
    let fragments = name.split(whereSeparator: { $0 == " " || $0 == "-" || $0 == "_" })
    return fragments.map { fragment in
      guard let first = fragment.first else { return "" }
      return String(first).uppercased() + fragment.dropFirst()
    }
    .joined()
  }
}

/// Variable validation shared by the document builder and the argv builder.
enum GatewayVariableBinding {
  static func validate(
    _ variables: [String: GatewayJSONValue],
    against operation: GatewayOperation,
    catalog: GatewaySchemaCatalog
  ) throws {
    let declared = Dictionary(uniqueKeysWithValues: operation.arguments.map { ($0.name, $0) })
    for name in variables.keys.sorted() where declared[name] == nil {
      throw GatewaySDKError.unknownVariable(operation: operation.name, name: name)
    }
    for argument in operation.arguments {
      let isRequired = argument.isRequired || argument.type.isRequired
      guard isRequired, argument.defaultValue == nil else { continue }
      guard let value = variables[argument.name], !value.isNull else {
        throw GatewaySDKError.missingRequiredVariable(operation: operation.name, name: argument.name)
      }
    }
    for argument in operation.arguments {
      guard let value = variables[argument.name] else { continue }
      try GatewayVariableTypeCheck.check(
        value,
        against: argument.type,
        name: argument.name,
        catalog: catalog
      )
    }
  }
}
