import Foundation

/// The kind of a single catalog definition, used by search and by `sdlFragment`.
public enum GatewayDefinitionKind: String, Codable, Sendable, CaseIterable, Equatable, Hashable {
  case query
  case mutation
  case command
  case object
  case inputObject
  case enumeration
  case scalar

  /// Stable ordering used by search results and SDL grouping.
  var order: Int {
    switch self {
    case .query: return 0
    case .mutation: return 1
    case .command: return 2
    case .object: return 3
    case .inputObject: return 4
    case .enumeration: return 5
    case .scalar: return 6
    }
  }
}

/// An argument of an operation, an object field, or an input object.
///
/// For command operations `name` is the flag name without the leading `--`.
public struct GatewayArgument: Codable, Sendable, Equatable {
  public var name: String
  public var type: GatewayTypeRef
  public var isRequired: Bool
  public var defaultValue: GatewayJSONValue?
  public var description: String?

  public init(
    name: String,
    type: GatewayTypeRef,
    isRequired: Bool = false,
    defaultValue: GatewayJSONValue? = nil,
    description: String? = nil
  ) {
    self.name = name
    self.type = type
    self.isRequired = isRequired
    self.defaultValue = defaultValue
    self.description = description
  }
}

/// A field of an object type.
public struct GatewayField: Codable, Sendable, Equatable {
  public var name: String
  public var type: GatewayTypeRef
  public var arguments: [GatewayArgument]
  public var description: String?

  public init(
    name: String,
    type: GatewayTypeRef,
    arguments: [GatewayArgument] = [],
    description: String? = nil
  ) {
    self.name = name
    self.type = type
    self.arguments = arguments
    self.description = description
  }
}

/// Wire keys for `GatewayNamedType.Kind`, kept at file scope so the nested type stays
/// shallow enough for the lint rules.
private enum NamedTypeKindCodingKeys: String, CodingKey {
  case kind
  case fields
  case inputFields
  case values
}

private enum NamedTypeKindDiscriminator: String, Codable {
  case scalar
  case object
  case inputObject
  case enumeration
}

/// A named type in the catalog: an object, input object, enum, or custom scalar.
public struct GatewayNamedType: Codable, Sendable, Equatable {
  /// The kind-specific payload.
  ///
  /// Wire format: a discriminated object keyed by `kind`, e.g.
  /// `{"kind":"object","fields":[...]}` or `{"kind":"scalar"}`.
  public enum Kind: Codable, Sendable, Equatable {
    case scalar
    case object([GatewayField])
    case inputObject([GatewayArgument])
    case enumeration([String])

    public init(from decoder: Decoder) throws {
      let container = try decoder.container(keyedBy: NamedTypeKindCodingKeys.self)
      switch try container.decode(NamedTypeKindDiscriminator.self, forKey: .kind) {
      case .scalar:
        self = .scalar
      case .object:
        self = .object(try container.decode([GatewayField].self, forKey: .fields))
      case .inputObject:
        self = .inputObject(try container.decode([GatewayArgument].self, forKey: .inputFields))
      case .enumeration:
        self = .enumeration(try container.decode([String].self, forKey: .values))
      }
    }

    public func encode(to encoder: Encoder) throws {
      var container = encoder.container(keyedBy: NamedTypeKindCodingKeys.self)
      switch self {
      case .scalar:
        try container.encode(NamedTypeKindDiscriminator.scalar, forKey: .kind)
      case .object(let fields):
        try container.encode(NamedTypeKindDiscriminator.object, forKey: .kind)
        try container.encode(fields, forKey: .fields)
      case .inputObject(let inputFields):
        try container.encode(NamedTypeKindDiscriminator.inputObject, forKey: .kind)
        try container.encode(inputFields, forKey: .inputFields)
      case .enumeration(let values):
        try container.encode(NamedTypeKindDiscriminator.enumeration, forKey: .kind)
        try container.encode(values, forKey: .values)
      }
    }

    /// The definition kind this named type reports to search and SDL fragments.
    public var definitionKind: GatewayDefinitionKind {
      switch self {
      case .scalar: return .scalar
      case .object: return .object
      case .inputObject: return .inputObject
      case .enumeration: return .enumeration
      }
    }
  }

  public var name: String
  public var kind: Kind
  public var description: String?

  public init(name: String, kind: Kind, description: String? = nil) {
    self.name = name
    self.kind = kind
    self.description = description
  }

  /// The object's fields, or `nil` when the type is not an object.
  public var objectFields: [GatewayField]? {
    if case .object(let fields) = kind { return fields }
    return nil
  }

  /// The input object's fields, or `nil` when the type is not an input object.
  public var inputFields: [GatewayArgument]? {
    if case .inputObject(let fields) = kind { return fields }
    return nil
  }

  /// The enum's values, or `nil` when the type is not an enum.
  public var enumValues: [String]? {
    if case .enumeration(let values) = kind { return values }
    return nil
  }
}

/// One callable operation: a GraphQL root field, or a CLI subcommand.
public struct GatewayOperation: Codable, Sendable, Equatable {
  public enum Kind: String, Codable, Sendable, Equatable {
    case query
    case mutation
    case command

    /// The matching definition kind.
    public var definitionKind: GatewayDefinitionKind {
      switch self {
      case .query: return .query
      case .mutation: return .mutation
      case .command: return .command
      }
    }
  }

  /// The GraphQL root field name, or the full command name such as `"files list"`.
  public var name: String
  public var kind: Kind
  /// The lowest tier that may run this operation.
  public var tier: String
  public var arguments: [GatewayArgument]
  /// `nil` for commands, which return opaque JSON.
  public var result: GatewayTypeRef?
  public var summary: String
  public var isDestructive: Bool
  public var domain: String?

  public init(
    name: String,
    kind: Kind,
    tier: String,
    arguments: [GatewayArgument] = [],
    result: GatewayTypeRef? = nil,
    summary: String = "",
    isDestructive: Bool = false,
    domain: String? = nil
  ) {
    self.name = name
    self.kind = kind
    self.tier = tier
    self.arguments = arguments
    self.result = result
    self.summary = summary
    self.isDestructive = isDestructive
    self.domain = domain
  }
}

/// The neutral, gateway-independent schema description.
public struct GatewaySchemaCatalog: Codable, Sendable, Equatable {
  /// e.g. `"gmail-gateway"`.
  public var provider: String
  /// e.g. `"reader"`.
  public var tier: String
  public var operations: [GatewayOperation]
  public var types: [GatewayNamedType]

  public init(
    provider: String,
    tier: String,
    operations: [GatewayOperation] = [],
    types: [GatewayNamedType] = []
  ) {
    self.provider = provider
    self.tier = tier
    self.operations = operations
    self.types = types
  }

  /// Scalars that never need a `GatewayNamedType` entry.
  public static let builtinScalars: Set<String> = ["ID", "String", "Int", "Float", "Boolean", "JSON"]

  // MARK: - Lookups

  /// Catalogs are small (tens of definitions), so linear scans keep the model free of
  /// derived indexes that would have to stay in sync with `Codable`.
  public func namedType(_ name: String) -> GatewayNamedType? {
    types.first { $0.name == name }
  }

  public func operation(named name: String) -> GatewayOperation? {
    operations.first { $0.name == name }
  }

  public func operations(of kind: GatewayOperation.Kind) -> [GatewayOperation] {
    operations.filter { $0.kind == kind }
  }
}
