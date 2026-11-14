import Foundation

public struct GatewayGraphQLDocument: Sendable, Equatable {
  public enum OperationType: String, Sendable, Equatable { case query, mutation }

  public struct VariableDefinition: Sendable, Equatable {
    public var name: String
    public var type: GatewayTypeRef
    public var defaultValue: GraphQLValue?

    public init(name: String, type: GatewayTypeRef, defaultValue: GraphQLValue? = nil) {
      self.name = name
      self.type = type
      self.defaultValue = defaultValue
    }
  }

  public struct Argument: Sendable, Equatable {
    public var name: String
    public var value: GraphQLValue

    public init(name: String, value: GraphQLValue) {
      self.name = name
      self.value = value
    }
  }

  public struct Selection: Sendable, Equatable {
    public var alias: String?
    public var name: String
    public var arguments: [Argument]
    public var selectionSet: [Selection]
    public var responseKey: String { alias ?? name }

    public init(alias: String? = nil, name: String, arguments: [Argument] = [], selectionSet: [Selection] = []) {
      self.alias = alias
      self.name = name
      self.arguments = arguments
      self.selectionSet = selectionSet
    }
  }

  public var operationType: OperationType
  public var name: String?
  public var variableDefinitions: [VariableDefinition]
  public var selectionSet: [Selection]

  public init(
    operationType: OperationType,
    name: String? = nil,
    variableDefinitions: [VariableDefinition] = [],
    selectionSet: [Selection]
  ) {
    self.operationType = operationType
    self.name = name
    self.variableDefinitions = variableDefinitions
    self.selectionSet = selectionSet
  }
}

public indirect enum GraphQLValue: Sendable, Equatable {
  case int(Int64), float(Double), string(String), bool(Bool), null
  case enumValue(String), variable(String)
  case list([GraphQLValue])
  case object([(name: String, value: GraphQLValue)])

  public static func == (lhs: GraphQLValue, rhs: GraphQLValue) -> Bool {
    switch (lhs, rhs) {
    case (.int(let a), .int(let b)): return a == b
    case (.float(let a), .float(let b)): return a == b
    case (.string(let a), .string(let b)): return a == b
    case (.bool(let a), .bool(let b)): return a == b
    case (.enumValue(let a), .enumValue(let b)): return a == b
    case (.variable(let a), .variable(let b)): return a == b
    case (.null, .null): return true
    case (.list(let a), .list(let b)): return a == b
    case (.object(let a), .object(let b)):
      return a.count == b.count && zip(a, b).allSatisfy { $0.name == $1.name && $0.value == $1.value }
    default: return false
    }
  }
}
