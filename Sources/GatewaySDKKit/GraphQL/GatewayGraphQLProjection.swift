import Foundation

enum GatewayProjectionResult {
  case value(GatewayJSONValue)
  case failure(GatewayEnvelopeError)
}

enum GatewayGraphQLProjection {
  private struct BudgetNode {
    let value: GatewayJSONValue
    let selections: [GatewayGraphQLDocument.Selection]
    let type: GatewayTypeRef
    let depth: Int
    let path: [String]
  }

  static func project(_ value: GatewayJSONValue, selection: [GatewayGraphQLDocument.Selection], type: GatewayTypeRef, catalog: GatewaySchemaCatalog, path: [String]) -> GatewayProjectionResult {
    if let error = budgetError(value, selection: selection, type: type, catalog: catalog, path: path) { return .failure(error) }
    return projectValue(value, selection: selection, type: type, catalog: catalog, path: path)
  }

  private static func projectValue(_ value: GatewayJSONValue, selection: [GatewayGraphQLDocument.Selection], type: GatewayTypeRef, catalog: GatewaySchemaCatalog, path: [String]) -> GatewayProjectionResult {
    if case .null = value { return .value(.null) }
    if case .nonNull(let inner) = type { return projectValue(value, selection: selection, type: inner, catalog: catalog, path: path) }
    if case .list(let element) = type {
      guard case .array(let values) = value else { return shape("expected list result", path) }
      var projected: [GatewayJSONValue] = []
      for member in values {
        switch projectValue(member, selection: selection, type: element, catalog: catalog, path: path) {
        case .value(let child): projected.append(child)
        case .failure(let error): return .failure(error)
        }
      }
      return .value(.array(projected))
    }
    guard case .object(let fields) = catalog.namedType(type.namedTypeName)?.kind else { return .value(value) }
    guard case .object(let object) = value else { return shape("expected object result", path) }
    let schema = Dictionary(fields.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
    var projected: [String: GatewayJSONValue] = [:]
    for selected in selection {
      let childPath = path + [selected.responseKey]
      guard let field = schema[selected.name] else { return shape("unknown projected field '\(selected.name)'", childPath) }
      guard let member = object[selected.name] else { projected[selected.responseKey] = .null; continue }
      switch projectValue(member, selection: selected.selectionSet, type: field.type, catalog: catalog, path: childPath) {
      case .value(let child): projected[selected.responseKey] = child
      case .failure(let error): return .failure(error)
      }
    }
    return .value(.object(projected))
  }

  private static func shape(_ message: String, _ path: [String]) -> GatewayProjectionResult {
    .failure(.init(message: message, code: "RESOLVER_SHAPE", path: path))
  }

  private static func budgetError(_ root: GatewayJSONValue, selection: [GatewayGraphQLDocument.Selection], type: GatewayTypeRef, catalog: GatewaySchemaCatalog, path: [String]) -> GatewayEnvelopeError? {
    var stack = [BudgetNode(value: root, selections: selection, type: type, depth: 1, path: path)]
    var nodes = 0
    while let node = stack.popLast() {
      let value = node.value
      let selections = node.selections
      let currentType = node.type
      let depth = node.depth
      let currentPath = node.path
      if depth > GatewayGraphQLLimits.depth { return resource("depth", GatewayGraphQLLimits.depth, currentPath) }
      nodes += 1
      if nodes > GatewayGraphQLLimits.resolverResultNodes { return resource("resolverResultNodes", GatewayGraphQLLimits.resolverResultNodes, currentPath) }
      switch value {
      case .double(let number) where !number.isFinite:
        return .init(message: "resolver result has a non-finite number", code: "RESOLVER_SHAPE", path: currentPath)
      case .array(let values):
        if values.count > GatewayGraphQLLimits.containerEntries { return resource("containerEntries", GatewayGraphQLLimits.containerEntries, currentPath) }
        let element = currentType.listElementType ?? currentType
        for member in values {
          stack.append(.init(value: member, selections: selections, type: element, depth: depth + 1, path: currentPath))
        }
      case .object(let object):
        if object.count > GatewayGraphQLLimits.containerEntries { return resource("containerEntries", GatewayGraphQLLimits.containerEntries, currentPath) }
        let unwrapped = currentType.unwrappingNonNull
        guard case .object(let fields) = catalog.namedType(unwrapped.namedTypeName)?.kind else {
          for member in object.values {
            stack.append(.init(value: member, selections: [], type: unwrapped, depth: depth + 1, path: currentPath))
          }
          continue
        }
        let schema = Dictionary(fields.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        let selected = Dictionary(selections.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        for (name, member) in object {
          if let field = schema[name], let child = selected[name] {
            stack.append(.init(value: member, selections: child.selectionSet, type: field.type, depth: depth + 1, path: currentPath + [child.responseKey]))
          } else {
            stack.append(.init(value: member, selections: [], type: unwrapped, depth: depth + 1, path: currentPath))
          }
        }
      default: break
      }
    }
    return nil
  }

  private static func resource(_ name: String, _ maximum: Int, _ path: [String]) -> GatewayEnvelopeError {
    .init(message: "resolver result exceeds \(name) maximum \(maximum)", code: "RESOLVER_SHAPE", path: path)
  }
}
