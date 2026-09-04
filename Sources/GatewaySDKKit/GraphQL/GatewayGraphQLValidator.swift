import Foundation

public struct ValidatedOperation: Sendable, Equatable {
  public struct RootField: Sendable, Equatable {
    public var responseKey: String
    public var name: String
    public var arguments: [String: GatewayJSONValue]
    public var selectionSet: [GatewayGraphQLDocument.Selection]
    public var operation: GatewayOperation

    public init(responseKey: String, name: String, arguments: [String: GatewayJSONValue], selectionSet: [GatewayGraphQLDocument.Selection], operation: GatewayOperation) {
      self.responseKey = responseKey; self.name = name; self.arguments = arguments
      self.selectionSet = selectionSet; self.operation = operation
    }
  }

  public var operationType: GatewayGraphQLDocument.OperationType
  public var name: String?
  public var rootFields: [RootField]

  public init(operationType: GatewayGraphQLDocument.OperationType, name: String? = nil, rootFields: [RootField]) {
    self.operationType = operationType; self.name = name; self.rootFields = rootFields
  }
}

public struct GatewayGraphQLValidator: Sendable {
  public let catalog: GatewaySchemaCatalog
  public init(catalog: GatewaySchemaCatalog) { self.catalog = catalog }

  public func validate(
    _ document: GatewayGraphQLDocument,
    variables: [String: GatewayJSONValue] = [:]
  ) throws -> ValidatedOperation {
    var inputNodes = try GatewayGraphQLBudget.validate(document: document, variables: variables)
    try directAstChecks(document)
    let kind: GatewayOperation.Kind = document.operationType == .query ? .query : .mutation
    let operations = firstWins(catalog.operations(of: kind), key: \GatewayOperation.name)
    var roots: [(GatewayGraphQLDocument.Selection, GatewayOperation)] = []
    for selection in document.selectionSet {
      guard let operation = operations[selection.name] else {
        throw error("UNKNOWN_FIELD", "unknown root field '\(selection.name)'", [selection.responseKey])
      }
      roots.append((selection, operation))
    }
    if document.operationType == .mutation, roots.count > 1 {
      throw error("MULTIPLE_MUTATIONS", "mutations must select exactly one root field", [])
    }
    for (selection, _) in roots { try nestedArgumentCheck(selection, path: [selection.responseKey], isRoot: true) }

    let definitions = firstWins(document.variableDefinitions, key: \GatewayGraphQLDocument.VariableDefinition.name)
    for supplied in variables.keys.sorted() where definitions[supplied] == nil {
      throw error("UNKNOWN_VARIABLE", "unknown variable '\(supplied)'", [])
    }
    let usages = collectVariableUsages(document.selectionSet)
    for definition in document.variableDefinitions where !usages.contains(definition.name) {
      throw error("UNUSED_VARIABLE", "variable '\(definition.name)' is not used", [])
    }
    for name in usages.sorted() where definitions[name] == nil {
      throw error("UNDECLARED_VARIABLE", "variable '\(name)' is not declared", [])
    }
    for definition in document.variableDefinitions {
      if variables[definition.name] == nil, definition.defaultValue == nil, definition.type.isRequired {
        throw error("MISSING_VARIABLE", "missing required variable '\(definition.name)'", [])
      }
      if let supplied = variables[definition.name], !GatewayVariableTypeCheck.matches(supplied, definition.type, catalog) {
        throw error("VARIABLE_TYPE", "variable '\(definition.name)' does not match \(definition.type.graphQLString)", [])
      }
    }

    var validated: [ValidatedOperation.RootField] = []
    for (selection, operation) in roots {
      let path = [selection.responseKey]
      var materializedDefaults: [GatewayJSONValue] = []
      let arguments = try rootArguments(
        selection,
        operation: operation,
        definitions: definitions,
        variables: variables,
        materializedDefaults: &materializedDefaults,
        path: path
      )
      inputNodes = try GatewayGraphQLBudget.validateMaterializedDefaults(
        materializedDefaults,
        startingNodes: inputNodes,
        path: path
      )
      guard let result = operation.result else { throw error("UNKNOWN_FIELD", "root field '\(selection.name)' has no GraphQL result", path) }
      try selectionCheck(selection.selectionSet, type: result, path: path)
      validated.append(.init(responseKey: selection.responseKey, name: selection.name, arguments: arguments, selectionSet: selection.selectionSet, operation: operation))
    }
    return .init(operationType: document.operationType, name: document.name, rootFields: validated)
  }

  private func rootArguments(
    _ selection: GatewayGraphQLDocument.Selection,
    operation: GatewayOperation,
    definitions: [String: GatewayGraphQLDocument.VariableDefinition],
    variables: [String: GatewayJSONValue],
    materializedDefaults: inout [GatewayJSONValue],
    path: [String]
  ) throws -> [String: GatewayJSONValue] {
    let schema = firstWins(operation.arguments, key: \GatewayArgument.name)
    let supplied = firstWins(selection.arguments, key: \GatewayGraphQLDocument.Argument.name)
    for argument in selection.arguments where schema[argument.name] == nil {
      throw error("UNKNOWN_ARGUMENT", "unknown argument '\(argument.name)'", path)
    }
    var output: [String: GatewayJSONValue] = [:]
    for argument in operation.arguments {
      guard let field = schema[argument.name], field.name == argument.name else { continue }
      let value: GatewayJSONValue?
      if let provided = supplied[argument.name] {
        try variableCompatibility(provided.value, expected: argument.type, definitions: definitions, path: path)
        value = try coerce(
          provided.value,
          target: argument.type,
          definitions: definitions,
          variables: variables,
          materializedDefaults: &materializedDefaults,
          path: path
        )
      } else {
        value = argument.defaultValue.map {
          let materialized = materialize($0, target: argument.type)
          materializedDefaults.append(materialized)
          return materialized
        }
      }
      if let value {
        guard GatewayVariableTypeCheck.matches(value, argument.type, catalog) else {
          throw error("ARGUMENT_TYPE", "argument '\(argument.name)' does not match \(argument.type.graphQLString)", path)
        }
        output[argument.name] = value
      } else if argument.isRequired || argument.type.isRequired {
        throw error("MISSING_ARGUMENT", "missing required argument '\(argument.name)'", path)
      }
    }
    return output
  }

  private func variableCompatibility(
    _ value: GraphQLValue,
    expected: GatewayTypeRef,
    definitions: [String: GatewayGraphQLDocument.VariableDefinition],
    path: [String]
  ) throws {
    switch value {
    case .variable(let name):
      guard let definition = definitions[name] else { return }
      let compatible = definition.type == expected || (!expected.isRequired && definition.type.unwrappingNonNull == expected)
      guard compatible else { throw error("VARIABLE_TYPE", "variable '\(name)' cannot feed \(expected.graphQLString)", path) }
    case .list(let values): for child in values { try variableCompatibility(child, expected: expected.listElementType ?? expected, definitions: definitions, path: path) }
    case .object(let values):
      guard case .inputObject(let fields) = catalog.namedType(expected.namedTypeName)?.kind else {
        for (_, child) in values { try variableCompatibility(child, expected: expected, definitions: definitions, path: path) }
        return
      }
      let fieldsByName = firstWins(fields, key: \GatewayArgument.name)
      for (name, child) in values {
        if let field = fieldsByName[name] {
          try variableCompatibility(child, expected: field.type, definitions: definitions, path: path)
        }
      }
    default: break
    }
  }

  private func coerce(
    _ value: GraphQLValue,
    target: GatewayTypeRef,
    definitions: [String: GatewayGraphQLDocument.VariableDefinition],
    variables: [String: GatewayJSONValue],
    materializedDefaults: inout [GatewayJSONValue],
    path: [String]
  ) throws -> GatewayJSONValue? {
    if case .variable(let name) = value {
      if let supplied = variables[name] {
        return materialize(supplied, target: target, materializedDefaults: &materializedDefaults)
      }
      if let defaultValue = definitions[name]?.defaultValue {
        return try coerce(
          defaultValue,
          target: target,
          definitions: definitions,
          variables: variables,
          materializedDefaults: &materializedDefaults,
          path: path
        )
      }
      return nil
    }
    let result: GatewayJSONValue
    switch value {
    case .int(let number): result = .int(Int(number))
    case .float(let number): result = .double(number)
    case .string(let text):
      if case .enumeration = catalog.namedType(target.namedTypeName)?.kind {
        throw error("ARGUMENT_TYPE", "string literal is not valid for enum \(target.namedTypeName)", path)
      }
      result = .string(text)
    case .bool(let flag): result = .bool(flag)
    case .null: result = .null
    case .enumValue(let text):
      guard case .enumeration(let values) = catalog.namedType(target.namedTypeName)?.kind, values.contains(text) else {
        throw error("ARGUMENT_TYPE", "'\(text)' is not a value of enum \(target.namedTypeName)", path)
      }
      result = .string(text)
    case .list(let values):
      let element = target.listElementType ?? target
      result = .array(try values.compactMap {
        try coerce(
          $0,
          target: element,
          definitions: definitions,
          variables: variables,
          materializedDefaults: &materializedDefaults,
          path: path
        )
      })
    case .object(let members):
      guard case .inputObject(let fields) = catalog.namedType(target.namedTypeName)?.kind else {
        throw error("ARGUMENT_TYPE", "object is not valid for \(target.namedTypeName)", path)
      }
      let schema = firstWins(fields, key: \GatewayArgument.name)
      var output: [String: GatewayJSONValue] = [:]
      for (name, member) in members {
        guard let field = schema[name] else { throw error("ARGUMENT_TYPE", "unknown input field '\(name)' on \(target.namedTypeName)", path) }
        if let coerced = try coerce(
          member,
          target: field.type,
          definitions: definitions,
          variables: variables,
          materializedDefaults: &materializedDefaults,
          path: path
        ) { output[name] = coerced }
      }
      for field in fields where output[field.name] == nil {
        if let defaultValue = field.defaultValue {
          let materialized = materialize(defaultValue, target: field.type)
          materializedDefaults.append(materialized)
          output[field.name] = materialized
        }
      }
      result = .object(output)
    case .variable: return nil
    }
    return materialize(result, target: target, materializedDefaults: &materializedDefaults)
  }

  private func materialize(_ value: GatewayJSONValue, target: GatewayTypeRef) -> GatewayJSONValue {
    var ignoredDefaults: [GatewayJSONValue] = []
    return materialize(value, target: target, materializedDefaults: &ignoredDefaults)
  }

  private func materialize(
    _ value: GatewayJSONValue,
    target: GatewayTypeRef,
    materializedDefaults: inout [GatewayJSONValue]
  ) -> GatewayJSONValue {
    if case .null = value { return value }
    if case .nonNull(let inner) = target {
      return materialize(value, target: inner, materializedDefaults: &materializedDefaults)
    }
    if case .list(let element) = target {
      if case .array(let members) = value {
        return .array(members.map { materialize($0, target: element, materializedDefaults: &materializedDefaults) })
      }
      return .array([materialize(value, target: element, materializedDefaults: &materializedDefaults)])
    }
    if target.namedTypeName == "Float", case .int(let number) = value { return .double(Double(number)) }
    if case .inputObject(let fields) = catalog.namedType(target.namedTypeName)?.kind, case .object(let members) = value {
      var rebuilt: [String: GatewayJSONValue] = [:]
      for field in fields {
        if let member = members[field.name] {
          rebuilt[field.name] = materialize(member, target: field.type, materializedDefaults: &materializedDefaults)
        } else if let defaultValue = field.defaultValue {
          let materialized = materialize(defaultValue, target: field.type)
          materializedDefaults.append(materialized)
          rebuilt[field.name] = materialized
        }
      }
      return .object(rebuilt)
    }
    return value
  }

  private func selectionCheck(_ selections: [GatewayGraphQLDocument.Selection], type: GatewayTypeRef, path: [String]) throws {
    let name = type.namedTypeName
    guard case .object(let fields) = catalog.namedType(name)?.kind else {
      guard selections.isEmpty else { throw error("INVALID_SELECTION", "leaf type '\(name)' cannot have a selection", path) }
      return
    }
    guard !selections.isEmpty else { throw error("INVALID_SELECTION", "object type '\(name)' requires a selection", path) }
    var responseKeys: Set<String> = []
    let byName = firstWins(fields, key: \GatewayField.name)
    for selection in selections {
      guard responseKeys.insert(selection.responseKey).inserted else { throw error("DUPLICATE_ALIAS", "duplicate response key '\(selection.responseKey)'", path + [selection.responseKey]) }
      guard let field = byName[selection.name] else { throw error("INVALID_SELECTION", "unknown field '\(selection.name)' on \(name)", path + [selection.responseKey]) }
      try selectionCheck(selection.selectionSet, type: field.type, path: path + [selection.responseKey])
    }
  }

  private func nestedArgumentCheck(_ selection: GatewayGraphQLDocument.Selection, path: [String], isRoot: Bool) throws {
    if !isRoot, !selection.arguments.isEmpty { throw error("INVALID_SELECTION", "nested field arguments are not supported", path) }
    for child in selection.selectionSet { try nestedArgumentCheck(child, path: path + [child.responseKey], isRoot: false) }
  }

  private func collectVariableUsages(_ selections: [GatewayGraphQLDocument.Selection]) -> Set<String> {
    var names: Set<String> = []
    func visit(_ value: GraphQLValue) {
      switch value {
      case .variable(let name): names.insert(name)
      case .list(let values): values.forEach(visit)
      case .object(let values): values.forEach { visit($0.value) }
      default: break
      }
    }
    func fields(_ entries: [GatewayGraphQLDocument.Selection]) {
      for selection in entries {
        selection.arguments.forEach { visit($0.value) }
        fields(selection.selectionSet)
      }
    }
    fields(selections)
    return names
  }

  private func directAstChecks(_ document: GatewayGraphQLDocument) throws {
    var variables: Set<String> = []
    for definition in document.variableDefinitions where !variables.insert(definition.name).inserted { throw error("DUPLICATE_VARIABLE", "duplicate variable '\(definition.name)'", []) }
    func check(_ selection: GatewayGraphQLDocument.Selection, _ path: [String]) throws {
      var names: Set<String> = []
      for argument in selection.arguments where !names.insert(argument.name).inserted { throw error("DUPLICATE_ARGUMENT", "duplicate argument '\(argument.name)'", path) }
      for child in selection.selectionSet { try check(child, path + [child.responseKey]) }
    }
    var rootResponseKeys: Set<String> = []
    for selection in document.selectionSet {
      guard rootResponseKeys.insert(selection.responseKey).inserted else {
        throw error("DUPLICATE_ALIAS", "duplicate response key '\(selection.responseKey)'", [selection.responseKey])
      }
      try check(selection, [selection.responseKey])
    }
  }

  private func error(_ code: String, _ message: String, _ path: [String]) -> GatewaySDKError { .validation(code: code, message: message, path: path) }
}

private enum GatewayGraphQLBudget {
  static func validate(document: GatewayGraphQLDocument, variables: [String: GatewayJSONValue]) throws -> Int {
    var selections = 0; var inputNodes = 0
    func walkValue(_ value: GraphQLValue, depth: Int, path: [String]) throws {
      guard depth <= GatewayGraphQLLimits.depth else { throw limit("depth", path) }
      inputNodes += 1; guard inputNodes <= GatewayGraphQLLimits.inputValueNodes else { throw limit("inputValueNodes", path) }
      switch value {
      case .list(let values):
        try container(values.count, path: path)
        for child in values { try walkValue(child, depth: depth + 1, path: path) }
      case .object(let values):
        try container(values.count, path: path)
        for (_, child) in values { try walkValue(child, depth: depth + 1, path: path) }
      default: break
      }
    }
    func fields(_ values: [GatewayGraphQLDocument.Selection], depth: Int, path: [String], root: Bool) throws {
      guard depth <= GatewayGraphQLLimits.depth else { throw limit("depth", path) }
      if root && values.count > GatewayGraphQLLimits.rootFields { throw limit("rootFields", path) }
      for selection in values {
        selections += 1
        guard selections <= GatewayGraphQLLimits.selections else {
          throw limit("selections", path + [selection.responseKey])
        }
        for argument in selection.arguments { try walkValue(argument.value, depth: depth, path: path + [selection.responseKey]) }
        try fields(selection.selectionSet, depth: depth + 1, path: path + [selection.responseKey], root: false)
      }
    }
    try fields(document.selectionSet, depth: 1, path: [], root: true)
    for definition in document.variableDefinitions { try typeDepth(definition.type) }
    for definition in document.variableDefinitions {
      if let defaultValue = definition.defaultValue { try walkValue(defaultValue, depth: 1, path: []) }
    }
    for value in variables.values { try json(value, depth: 1, nodes: &inputNodes, path: []) }
    return inputNodes
  }
  static func validateMaterializedDefaults(_ values: [GatewayJSONValue], startingNodes: Int, path: [String]) throws -> Int {
    var nodes = startingNodes
    for value in values { try json(value, depth: 1, nodes: &nodes, path: path) }
    return nodes
  }
  private static func typeDepth(_ type: GatewayTypeRef) throws {
    var stack: [(GatewayTypeRef, Int)] = [(type, 1)]
    while let (current, depth) = stack.popLast() {
      guard depth <= GatewayGraphQLLimits.depth else { throw limit("depth") }
      switch current {
      case .named: break
      case .list(let inner), .nonNull(let inner): stack.append((inner, depth + 1))
      }
    }
  }
  private static func container(_ count: Int, path: [String]) throws { guard count <= GatewayGraphQLLimits.containerEntries else { throw limit("containerEntries", path) } }
  private static func json(_ value: GatewayJSONValue, depth: Int, nodes: inout Int, path: [String]) throws {
    guard depth <= GatewayGraphQLLimits.depth else { throw limit("depth", path) }
    nodes += 1
    guard nodes <= GatewayGraphQLLimits.inputValueNodes else { throw limit("inputValueNodes", path) }
    switch value {
    case .array(let values):
      try container(values.count, path: path)
      for child in values { try json(child, depth: depth + 1, nodes: &nodes, path: path) }
    case .object(let values):
      try container(values.count, path: path)
      for child in values.values { try json(child, depth: depth + 1, nodes: &nodes, path: path) }
    default: break
    }
  }
  private static func limit(_ name: String, _ path: [String] = []) -> GatewaySDKError {
    let limits: [String: Int] = [
      "depth": GatewayGraphQLLimits.depth,
      "selections": GatewayGraphQLLimits.selections,
      "rootFields": GatewayGraphQLLimits.rootFields,
      "containerEntries": GatewayGraphQLLimits.containerEntries,
      "inputValueNodes": GatewayGraphQLLimits.inputValueNodes
    ]
    return .validation(
      code: "RESOURCE_LIMIT",
      message: GatewayGraphQLLimits.message(name, limits[name] ?? 0),
      path: path
    )
  }
}

private func firstWins<Value, Key: Hashable>(_ values: [Value], key: (Value) -> Key) -> [Key: Value] {
  Dictionary(values.map { (key($0), $0) }, uniquingKeysWith: { first, _ in first })
}
