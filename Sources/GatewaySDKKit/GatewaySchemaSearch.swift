import Foundation

/// Regex search over a catalog's definitions.
///
/// Matching is "contains" (`firstMatch`) against definition names, argument and field
/// names, enum values, and summary/description prose; exact whole-name matches sort
/// first so `"threads"` beats `"listThreads"`.
public struct GatewaySchemaSearch: Sendable {
  public struct Options: Sendable {
    public var kinds: Set<GatewayDefinitionKind>
    /// Pull in the argument and result types of matched operations.
    public var includeReferencedTypes: Bool
    public var limit: Int?

    public init(
      kinds: Set<GatewayDefinitionKind> = [.query, .mutation, .command, .object, .inputObject, .enumeration],
      includeReferencedTypes: Bool = false,
      limit: Int? = nil
    ) {
      self.kinds = kinds
      self.includeReferencedTypes = includeReferencedTypes
      self.limit = limit
    }
  }

  public struct Match: Codable, Sendable, Equatable {
    public var kind: GatewayDefinitionKind
    public var name: String
    /// The operation's tier, or `nil` for types.
    public var tier: String?
    /// What matched: `"name"`, `"argument:accountId"`, `"field:subject"`,
    /// `"value:ROWS"`, `"summary"`, or `"referenced-by:<operation>"`.
    public var matchedOn: [String]
    /// The SDL fragment of exactly this definition.
    public var sdl: String

    public init(
      kind: GatewayDefinitionKind,
      name: String,
      tier: String? = nil,
      matchedOn: [String] = [],
      sdl: String = ""
    ) {
      self.kind = kind
      self.name = name
      self.tier = tier
      self.matchedOn = matchedOn
      self.sdl = sdl
    }
  }

  private let catalog: GatewaySchemaCatalog

  public init(catalog: GatewaySchemaCatalog) {
    self.catalog = catalog
  }

  public func search(_ pattern: String, options: Options = .init()) throws -> [Match] {
    try GatewaySchemaSearchPattern.validate(pattern)

    let regex: Regex<AnyRegexOutput>
    do {
      regex = try Regex(pattern)
    } catch {
      throw GatewaySDKError.invalidPattern(String(describing: error))
    }

    var direct: [(match: Match, isExact: Bool)] = []
    var matchedOperations: [GatewayOperation] = []

    for operation in catalog.operations {
      let kind = operation.kind.definitionKind
      guard options.kinds.contains(kind) else { continue }
      let labels = labels(for: operation, regex: regex)
      guard !labels.isEmpty else { continue }
      matchedOperations.append(operation)
      direct.append(
        (
          Match(
            kind: kind,
            name: operation.name,
            tier: operation.tier,
            matchedOn: labels,
            sdl: catalog.sdlFragment(for: kind, name: operation.name) ?? ""
          ),
          isExact(regex, operation.name)
        )
      )
    }

    for type in catalog.types {
      let kind = type.kind.definitionKind
      guard options.kinds.contains(kind) else { continue }
      let labels = labels(for: type, regex: regex)
      guard !labels.isEmpty else { continue }
      direct.append(
        (
          Match(
            kind: kind,
            name: type.name,
            tier: nil,
            matchedOn: labels,
            sdl: catalog.sdlFragment(for: kind, name: type.name) ?? ""
          ),
          isExact(regex, type.name)
        )
      )
    }

    var results = direct
      .sorted { lhs, rhs in
        if lhs.isExact != rhs.isExact { return lhs.isExact }
        if lhs.match.kind.order != rhs.match.kind.order {
          return lhs.match.kind.order < rhs.match.kind.order
        }
        return lhs.match.name < rhs.match.name
      }
      .map(\.match)

    if options.includeReferencedTypes {
      results += referencedTypes(for: matchedOperations, excluding: results)
    }

    if let limit = options.limit, results.count > limit {
      results = Array(results.prefix(limit))
    }
    return results
  }

  // MARK: - Label collection

  private func labels(for operation: GatewayOperation, regex: Regex<AnyRegexOutput>) -> [String] {
    var labels: [String] = []
    var summaryMatched = false
    if contains(regex, operation.name) { labels.append("name") }
    for argument in operation.arguments {
      if contains(regex, argument.name) { labels.append("argument:\(argument.name)") }
      if let text = argument.description, contains(regex, text) { summaryMatched = true }
    }
    if !operation.summary.isEmpty, contains(regex, operation.summary) { summaryMatched = true }
    if summaryMatched { labels.append("summary") }
    return labels
  }

  private func labels(for type: GatewayNamedType, regex: Regex<AnyRegexOutput>) -> [String] {
    var labels: [String] = []
    var summaryMatched = false
    if contains(regex, type.name) { labels.append("name") }
    if let text = type.description, contains(regex, text) { summaryMatched = true }
    switch type.kind {
    case .scalar:
      break
    case .object(let fields):
      for field in fields {
        if contains(regex, field.name) { labels.append("field:\(field.name)") }
        if let text = field.description, contains(regex, text) { summaryMatched = true }
        for argument in field.arguments {
          if contains(regex, argument.name) { labels.append("argument:\(argument.name)") }
          if let text = argument.description, contains(regex, text) { summaryMatched = true }
        }
      }
    case .inputObject(let fields):
      for field in fields {
        if contains(regex, field.name) { labels.append("field:\(field.name)") }
        if let text = field.description, contains(regex, text) { summaryMatched = true }
      }
    case .enumeration(let values):
      for value in values where contains(regex, value) {
        labels.append("value:\(value)")
      }
    }
    if summaryMatched { labels.append("summary") }
    return labels
  }

  // MARK: - Referenced types

  /// Argument types (transitively through input objects) and the result type plus one
  /// level of its fields' named types, for every matched operation.
  ///
  /// These additions bypass `options.kinds` on purpose: they exist so a caller can hand
  /// the whole reachable shape to a model without a second round trip.
  private func referencedTypes(
    for operations: [GatewayOperation],
    excluding present: [Match]
  ) -> [Match] {
    var labels: [String: Set<String>] = [:]
    var order: [String] = []

    func note(_ typeName: String, operation: String) {
      guard !GatewaySchemaCatalog.builtinScalars.contains(typeName) else { return }
      guard catalog.namedType(typeName) != nil else { return }
      if labels[typeName] == nil {
        labels[typeName] = []
        order.append(typeName)
      }
      labels[typeName]?.insert("referenced-by:\(operation)")
    }

    for operation in operations {
      var pending = operation.arguments.map(\.type.namedTypeName)
      var visited: Set<String> = []
      while let name = pending.popLast() {
        guard visited.insert(name).inserted else { continue }
        note(name, operation: operation.name)
        if let inputFields = catalog.namedType(name)?.inputFields {
          pending += inputFields.map(\.type.namedTypeName)
        }
      }
      if let result = operation.result {
        let resultName = result.namedTypeName
        note(resultName, operation: operation.name)
        for field in catalog.namedType(resultName)?.objectFields ?? [] {
          note(field.type.namedTypeName, operation: operation.name)
        }
      }
    }

    let alreadyPresent = Set(present.map { "\($0.kind.rawValue)|\($0.name)" })
    var additions: [Match] = []
    for name in order {
      guard let type = catalog.namedType(name) else { continue }
      let kind = type.kind.definitionKind
      guard !alreadyPresent.contains("\(kind.rawValue)|\(name)") else { continue }
      additions.append(
        Match(
          kind: kind,
          name: name,
          tier: nil,
          matchedOn: (labels[name] ?? []).sorted(),
          sdl: catalog.sdlFragment(for: kind, name: name) ?? ""
        )
      )
    }
    return additions.sorted { lhs, rhs in
      if lhs.kind.order != rhs.kind.order { return lhs.kind.order < rhs.kind.order }
      return lhs.name < rhs.name
    }
  }

  // MARK: - Matching primitives

  private func contains(_ regex: Regex<AnyRegexOutput>, _ text: String) -> Bool {
    (try? regex.firstMatch(in: text)).flatMap { $0 } != nil
  }

  private func isExact(_ regex: Regex<AnyRegexOutput>, _ name: String) -> Bool {
    (try? regex.wholeMatch(in: name)).flatMap { $0 } != nil
  }
}
