import Foundation

extension GatewaySchemaCatalog {
  /// Prints the whole catalog as SDL in a stable order.
  ///
  /// Order: custom scalars, enums, input objects, objects (each group sorted by name),
  /// then `type Query`, `type Mutation`, and `type Command` in catalog operation order.
  /// Root types with no operations are omitted. Definitions are separated by one blank
  /// line and the output ends with a newline.
  public func sdl() -> String {
    var blocks: [String] = []

    for type in types.filter({ $0.kind.definitionKind == .scalar }).sorted(by: byName) {
      blocks.append(Self.scalarBlock(type))
    }
    for type in types.filter({ $0.kind.definitionKind == .enumeration }).sorted(by: byName) {
      blocks.append(Self.enumBlock(type))
    }
    for type in types.filter({ $0.kind.definitionKind == .inputObject }).sorted(by: byName) {
      blocks.append(Self.inputObjectBlock(type))
    }
    for type in types.filter({ $0.kind.definitionKind == .object }).sorted(by: byName) {
      blocks.append(Self.objectBlock(type))
    }
    for kind in [GatewayOperation.Kind.query, .mutation, .command] {
      let matching = operations(of: kind)
      guard !matching.isEmpty else { continue }
      blocks.append(Self.rootTypeBlock(named: Self.rootTypeName(for: kind), fields: matching))
    }

    guard !blocks.isEmpty else { return "" }
    return blocks.joined(separator: "\n\n") + "\n"
  }

  /// Prints exactly one definition, as used by search match payloads.
  ///
  /// Operation kinds print wrapped in their root type so the fragment is valid SDL on
  /// its own. Returns `nil` when no definition of that kind carries the name. The
  /// fragment has no trailing newline.
  public func sdlFragment(for kind: GatewayDefinitionKind, name: String) -> String? {
    switch kind {
    case .query, .mutation, .command:
      guard let operation = operations.first(where: { $0.name == name && $0.kind.definitionKind == kind })
      else { return nil }
      return Self.rootTypeBlock(named: Self.rootTypeName(for: operation.kind), fields: [operation])
    case .scalar, .object, .inputObject, .enumeration:
      guard let type = types.first(where: { $0.name == name && $0.kind.definitionKind == kind })
      else { return nil }
      switch type.kind {
      case .scalar: return Self.scalarBlock(type)
      case .enumeration: return Self.enumBlock(type)
      case .inputObject: return Self.inputObjectBlock(type)
      case .object: return Self.objectBlock(type)
      }
    }
  }

  private func byName(_ lhs: GatewayNamedType, _ rhs: GatewayNamedType) -> Bool {
    lhs.name < rhs.name
  }

  static func rootTypeName(for kind: GatewayOperation.Kind) -> String {
    switch kind {
    case .query: return "Query"
    case .mutation: return "Mutation"
    case .command: return "Command"
    }
  }

  // MARK: - Blocks

  private static func scalarBlock(_ type: GatewayNamedType) -> String {
    description(type.description, indent: "") + "scalar \(sanitized(type.name))"
  }

  private static func enumBlock(_ type: GatewayNamedType) -> String {
    let values = type.enumValues ?? []
    var out = description(type.description, indent: "") + "enum \(sanitized(type.name)) {\n"
    for value in values {
      out += "  \(sanitized(value))\n"
    }
    out += "}"
    return out
  }

  private static func inputObjectBlock(_ type: GatewayNamedType) -> String {
    let fields = type.inputFields ?? []
    var out = description(type.description, indent: "") + "input \(sanitized(type.name)) {\n"
    for field in fields {
      out += description(field.description, indent: "  ")
      out += "  \(sanitized(field.name)): \(field.type.graphQLString)\n"
    }
    out += "}"
    return out
  }

  private static func objectBlock(_ type: GatewayNamedType) -> String {
    let fields = type.objectFields ?? []
    var out = description(type.description, indent: "") + "type \(sanitized(type.name)) {\n"
    for field in fields {
      out += description(field.description, indent: "  ")
      out += "  \(sanitized(field.name))\(argumentList(field.arguments)): \(field.type.graphQLString)\n"
    }
    out += "}"
    return out
  }

  private static func rootTypeBlock(named name: String, fields: [GatewayOperation]) -> String {
    var out = "type \(name) {\n"
    for operation in fields {
      out += description(operation.summary.isEmpty ? nil : operation.summary, indent: "  ")
      // Commands return opaque JSON unless the catalog pins a richer result type.
      let result = operation.result?.graphQLString ?? "JSON"
      out += "  \(sanitized(operation.name))\(argumentList(operation.arguments)): \(result)\n"
    }
    out += "}"
    return out
  }

  private static func argumentList(_ arguments: [GatewayArgument]) -> String {
    guard !arguments.isEmpty else { return "" }
    let rendered = arguments.map { "\(sanitized($0.name)): \($0.type.graphQLString)" }
    return "(" + rendered.joined(separator: ", ") + ")"
  }

  private static func description(_ text: String?, indent: String) -> String {
    guard let text, !text.isEmpty else { return "" }
    var out = "\(indent)\"\"\"\n"
    for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
      out += line.isEmpty ? "\n" : "\(indent)\(line)\n"
    }
    out += "\(indent)\"\"\"\n"
    return out
  }

  /// Maps characters that are illegal in a GraphQL name to `_`.
  ///
  /// Command catalogs carry names like `"values get"` and flags like `page-size`; the
  /// catalog keeps them verbatim and only SDL output is sanitized.
  static func sanitized(_ name: String) -> String {
    var out = ""
    out.unicodeScalars.reserveCapacity(name.unicodeScalars.count)
    for scalar in name.unicodeScalars {
      switch scalar {
      case "A"..."Z", "a"..."z", "0"..."9", "_":
        out.unicodeScalars.append(scalar)
      default:
        out.unicodeScalars.append("_")
      }
    }
    return out
  }
}
