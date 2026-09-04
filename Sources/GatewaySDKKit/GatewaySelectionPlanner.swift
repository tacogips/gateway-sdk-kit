import Foundation

/// One node of a generated selection set.
struct GatewaySelectionNode: Equatable {
  var name: String
  var children: [GatewaySelectionNode] = []
}

/// Builds selection sets: the depth-limited default selection, and the tree implied by
/// a list of dot paths.
enum GatewaySelectionPlanner {
  /// Object fields may open selections at levels 1...3; a field that would open level 4
  /// is omitted, as is any object whose own fields were all skipped.
  static let maxDepth = 3

  // MARK: - Default selection

  static func defaultSelection(
    of typeName: String,
    catalog: GatewaySchemaCatalog,
    level: Int = 0,
    path: Set<String> = []
  ) -> [GatewaySelectionNode] {
    guard let fields = catalog.namedType(typeName)?.objectFields else { return [] }
    var walked = path
    walked.insert(typeName)

    var nodes: [GatewaySelectionNode] = []
    for field in fields {
      // A field the caller cannot invoke without arguments is not safe to auto-select.
      guard !hasRequiredArgument(field) else { continue }
      let fieldTypeName = field.type.namedTypeName
      if isLeafType(fieldTypeName, catalog: catalog) {
        nodes.append(GatewaySelectionNode(name: field.name))
        continue
      }
      guard level < maxDepth, !walked.contains(fieldTypeName) else { continue }
      let children = defaultSelection(
        of: fieldTypeName,
        catalog: catalog,
        level: level + 1,
        path: walked
      )
      guard !children.isEmpty else { continue }
      nodes.append(GatewaySelectionNode(name: field.name, children: children))
    }
    return nodes
  }

  // MARK: - Dot paths

  static func selection(
    forPaths paths: [String],
    of typeName: String,
    catalog: GatewaySchemaCatalog
  ) throws -> [GatewaySelectionNode] {
    var roots: [GatewaySelectionNode] = []
    for path in paths {
      let segments = path.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
      guard !segments.isEmpty, !segments.contains(where: \.isEmpty) else {
        throw GatewaySDKError.invalidSelectionPath(path: path)
      }
      try insert(segments[...], into: &roots, ownerTypeName: typeName, catalog: catalog, path: path)
    }
    // A path may stop on an object field; expand those to that object's default selection.
    return try expandObjectLeaves(roots, ownerTypeName: typeName, catalog: catalog, walked: [])
  }

  private static func insert(
    _ segments: ArraySlice<String>,
    into nodes: inout [GatewaySelectionNode],
    ownerTypeName: String,
    catalog: GatewaySchemaCatalog,
    path: String
  ) throws {
    guard let segment = segments.first else { return }
    guard let owner = catalog.namedType(ownerTypeName)?.objectFields,
      let field = owner.first(where: { $0.name == segment }),
      !hasRequiredArgument(field)
    else {
      throw GatewaySDKError.invalidSelectionPath(path: path)
    }

    let rest = segments.dropFirst()
    let fieldTypeName = field.type.namedTypeName
    if !rest.isEmpty, isLeafType(fieldTypeName, catalog: catalog) {
      throw GatewaySDKError.invalidSelectionPath(path: path)
    }

    let index: Int
    if let existing = nodes.firstIndex(where: { $0.name == segment }) {
      index = existing
    } else {
      nodes.append(GatewaySelectionNode(name: segment))
      index = nodes.count - 1
    }
    try insert(
      rest,
      into: &nodes[index].children,
      ownerTypeName: fieldTypeName,
      catalog: catalog,
      path: path
    )
  }

  private static func expandObjectLeaves(
    _ nodes: [GatewaySelectionNode],
    ownerTypeName: String,
    catalog: GatewaySchemaCatalog,
    walked: Set<String>
  ) throws -> [GatewaySelectionNode] {
    var visited = walked
    visited.insert(ownerTypeName)
    let fields = catalog.namedType(ownerTypeName)?.objectFields ?? []

    var result: [GatewaySelectionNode] = []
    for node in nodes {
      guard let field = fields.first(where: { $0.name == node.name }) else { continue }
      let fieldTypeName = field.type.namedTypeName
      if isLeafType(fieldTypeName, catalog: catalog) {
        result.append(GatewaySelectionNode(name: node.name))
        continue
      }
      if node.children.isEmpty {
        // Depth is recounted from here, with the types already walked kept on the path
        // so an object leaf cannot reopen a cycle the caller already descended.
        let children = defaultSelection(
          of: fieldTypeName,
          catalog: catalog,
          level: 0,
          path: visited
        )
        result.append(GatewaySelectionNode(name: node.name, children: children))
      } else {
        let children = try expandObjectLeaves(
          node.children,
          ownerTypeName: fieldTypeName,
          catalog: catalog,
          walked: visited
        )
        result.append(GatewaySelectionNode(name: node.name, children: children))
      }
    }
    return result
  }

  // MARK: - Helpers

  static func hasRequiredArgument(_ field: GatewayField) -> Bool {
    field.arguments.contains { $0.isRequired || $0.type.isRequired }
  }

  /// Scalars (builtin and custom) and enums are leaves; unknown names are treated as
  /// leaves so a slightly stale catalog degrades to a plain field rather than throwing.
  static func isLeafType(_ name: String, catalog: GatewaySchemaCatalog) -> Bool {
    if GatewaySchemaCatalog.builtinScalars.contains(name) { return true }
    guard let named = catalog.namedType(name) else { return true }
    switch named.kind {
    case .object: return false
    case .scalar, .enumeration, .inputObject: return true
    }
  }

  // MARK: - Rendering

  /// Renders first-level entries one per line at `indent`; nested levels render inline
  /// on a single line, as `field { a b c { d } }`.
  static func render(_ nodes: [GatewaySelectionNode], indent: String) -> [String] {
    nodes.map { node in
      node.children.isEmpty ? "\(indent)\(node.name)" : "\(indent)\(renderInline(node))"
    }
  }

  static func renderInline(_ node: GatewaySelectionNode) -> String {
    guard !node.children.isEmpty else { return node.name }
    let inner = node.children.map(renderInline).joined(separator: " ")
    return "\(node.name) { \(inner) }"
  }
}
