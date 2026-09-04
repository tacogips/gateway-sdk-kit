import Foundation

extension GatewayEnvelopeError: Error {}

enum GatewayGraphQLProjection {
  static func project(
    _ value: GatewayJSONValue,
    selection: [GatewayGraphQLDocument.Selection],
    type: GatewayTypeRef,
    catalog: GatewaySchemaCatalog,
    path: [String]
  ) -> Result<GatewayJSONValue, GatewayEnvelopeError> {
    if let message = budgetError(value) {
      return .failure(.init(message: message, code: "RESOLVER_SHAPE", path: path))
    }
    return projectValue(value, selection: selection, type: type, catalog: catalog, path: path)
  }

  private static func projectValue(
    _ value: GatewayJSONValue,
    selection: [GatewayGraphQLDocument.Selection],
    type: GatewayTypeRef,
    catalog: GatewaySchemaCatalog,
    path: [String]
  ) -> Result<GatewayJSONValue, GatewayEnvelopeError> {
    if case .null = value { return .success(.null) }
    if case .nonNull(let inner) = type { return projectValue(value, selection: selection, type: inner, catalog: catalog, path: path) }
    if case .list(let element) = type {
      guard case .array(let values) = value else { return shape("expected list result", path) }
      var projected: [GatewayJSONValue] = []
      for member in values {
        switch projectValue(member, selection: selection, type: element, catalog: catalog, path: path) {
        case .success(let value): projected.append(value)
        case .failure(let error): return .failure(error)
        }
      }
      return .success(.array(projected))
    }
    guard case .object(let fields) = catalog.namedType(type.namedTypeName)?.kind else { return .success(value) }
    guard case .object(let object) = value else { return shape("expected object result", path) }
    let schema = Dictionary(fields.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
    var projected: [String: GatewayJSONValue] = [:]
    for selected in selection {
      let childPath = path + [selected.responseKey]
      guard let field = schema[selected.name] else { return shape("unknown projected field '\(selected.name)'", childPath) }
      guard let member = object[selected.name] else { projected[selected.responseKey] = .null; continue }
      switch projectValue(member, selection: selected.selectionSet, type: field.type, catalog: catalog, path: childPath) {
      case .success(let value): projected[selected.responseKey] = value
      case .failure(let error): return .failure(error)
      }
    }
    return .success(.object(projected))
  }

  private static func shape(_ message: String, _ path: [String]) -> Result<GatewayJSONValue, GatewayEnvelopeError> {
    .failure(.init(message: message, code: "RESOLVER_SHAPE", path: path))
  }

  private static func budgetError(_ root: GatewayJSONValue) -> String? {
    var stack: [(GatewayJSONValue, Int)] = [(root, 1)]
    var nodes = 0
    while let (value, depth) = stack.popLast() {
      if depth > GatewayGraphQLLimits.depth { return "resolver result exceeds depth maximum \(GatewayGraphQLLimits.depth)" }
      nodes += 1
      if nodes > GatewayGraphQLLimits.resolverResultNodes { return "resolver result exceeds resultNodes maximum \(GatewayGraphQLLimits.resolverResultNodes)" }
      switch value {
      case .double(let number) where !number.isFinite: return "resolver result has a non-finite number"
      case .array(let values):
        if values.count > GatewayGraphQLLimits.containerEntries { return "resolver result exceeds containerEntries maximum \(GatewayGraphQLLimits.containerEntries)" }
        stack.append(contentsOf: values.map { ($0, depth + 1) })
      case .object(let values):
        if values.count > GatewayGraphQLLimits.containerEntries { return "resolver result exceeds containerEntries maximum \(GatewayGraphQLLimits.containerEntries)" }
        stack.append(contentsOf: values.values.map { ($0, depth + 1) })
      default: break
      }
    }
    return nil
  }
}
