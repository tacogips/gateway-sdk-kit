import Foundation

public struct GatewayResolverContext: Sendable {
  public var environment: [String: String]
  public var requestId: String
  public var userInfo: [String: GatewayJSONValue]

  public init(environment: [String: String] = [:], requestId: String = "", userInfo: [String: GatewayJSONValue] = [:]) {
    self.environment = environment; self.requestId = requestId; self.userInfo = userInfo
  }
}

public protocol GatewayResolverError: Error {
  var code: String { get }
  var message: String { get }
}

public struct GatewayGraphQLRuntime: Sendable {
  public typealias Resolver = @Sendable ([String: GatewayJSONValue], GatewayResolverContext) async throws -> GatewayJSONValue

  private let catalog: GatewaySchemaCatalog
  private let authorizedCatalog: GatewaySchemaCatalog
  private let resolvers: [String: Resolver]

  public init(catalog: GatewaySchemaCatalog, authorized: GatewaySchemaCatalog? = nil, resolvers: [String: Resolver]) throws {
    let problems = Self.check(catalog: catalog, resolvers: resolvers)
    if let problem = problems.first {
      let code = problem.hasPrefix("missing resolver") ? "MISSING_RESOLVER" : "UNKNOWN_RESOLVER"
      let name = problem.split(separator: "'").dropFirst().first.map(String.init) ?? ""
      throw GatewaySDKError.validation(code: code, message: problem, path: name.isEmpty ? [] : [name])
    }
    self.catalog = catalog; self.authorizedCatalog = authorized ?? catalog; self.resolvers = resolvers
  }

  public static func check(catalog: GatewaySchemaCatalog, resolvers: [String: Resolver]) -> [String] {
    var names: Set<String> = []
    var problems: [String] = []
    for operation in catalog.operations where operation.kind == .query || operation.kind == .mutation {
      guard names.insert(operation.name).inserted else { continue }
      if resolvers[operation.name] == nil { problems.append("missing resolver for root field '\(operation.name)'") }
    }
    for key in resolvers.keys where !names.contains(key) { problems.append("resolver '\(key)' matches no catalog root field") }
    return problems.sorted()
  }

  public func printedSchema() -> String { authorizedCatalog.sdl() }

  public func execute(
    document: String,
    variables: [String: GatewayJSONValue] = [:],
    context: GatewayResolverContext
  ) async -> GatewayEnvelope {
    let validated: ValidatedOperation
    do {
      let parsed = try GatewayGraphQLParser.parse(document)
      validated = try GatewayGraphQLValidator(catalog: catalog).validate(parsed, variables: variables)
    } catch let error as GatewaySDKError {
      switch error {
      case .syntax:
        return envelope(data: nil, errors: [.init(message: error.description, code: "SYNTAX")], context: context, exitCode: 2)
      case .validation(let code, let message, let path):
        return envelope(data: nil, errors: [.init(message: message, code: code, path: path.isEmpty ? nil : path)], context: context, exitCode: 2)
      default:
        return envelope(data: nil, errors: [.init(message: error.description, code: "SYNTAX")], context: context, exitCode: 2)
      }
    } catch {
      return envelope(data: nil, errors: [.init(message: "invalid GraphQL document", code: "SYNTAX")], context: context, exitCode: 2)
    }

    let allowed = Set(authorizedCatalog.operations.filter { $0.kind == .query || $0.kind == .mutation }.map { "\($0.kind.rawValue):\($0.name)" })
    let denied = validated.rootFields.filter { !allowed.contains("\($0.operation.kind.rawValue):\($0.name)") }
    if !denied.isEmpty {
      let errors = denied.map { root in
        GatewayEnvelopeError(message: "root field '\(root.name)' is not available to tier '\(authorizedCatalog.tier)'", code: "CAPABILITY_DENIED", path: [root.responseKey])
      }
      return envelope(data: nil, errors: errors, context: context, exitCode: 1)
    }

    let outcomes: [FieldOutcome]
    if validated.operationType == .mutation {
      outcomes = [await resolve(validated.rootFields[0], context: context)]
    } else {
      outcomes = await resolveQueries(validated.rootFields, context: context)
    }
    var data: [String: GatewayJSONValue] = [:]
    var errors: [GatewayEnvelopeError] = []
    for outcome in outcomes {
      data[outcome.key] = outcome.value
      if let error = outcome.error { errors.append(error) }
    }
    return envelope(data: .object(data), errors: errors, context: context, exitCode: errors.isEmpty ? 0 : 1)
  }

  private func resolveQueries(_ roots: [ValidatedOperation.RootField], context: GatewayResolverContext) async -> [FieldOutcome] {
    await withTaskGroup(of: (Int, FieldOutcome).self, returning: [FieldOutcome].self) { group in
      var next = 0
      var outcomes = [FieldOutcome?](repeating: nil, count: roots.count)
      func add(_ index: Int) { group.addTask { (index, await self.resolve(roots[index], context: context)) } }
      while next < min(roots.count, GatewayGraphQLLimits.concurrentQueryResolvers) { add(next); next += 1 }
      while let (index, outcome) = await group.next() {
        outcomes[index] = outcome
        if next < roots.count { add(next); next += 1 }
      }
      return outcomes.compactMap { $0 }
    }
  }

  private func resolve(_ root: ValidatedOperation.RootField, context: GatewayResolverContext) async -> FieldOutcome {
    guard let resolver = resolvers[root.name] else {
      return .init(key: root.responseKey, value: .null, error: .init(message: "resolver failed", code: "RESOLVER_ERROR", path: [root.responseKey]))
    }
    do {
      let result = try await resolver(root.arguments, context)
      switch GatewayGraphQLProjection.project(result, selection: root.selectionSet, type: root.operation.result!, catalog: catalog, path: [root.responseKey]) {
      case .value(let value): return .init(key: root.responseKey, value: value)
      case .failure(let error): return .init(key: root.responseKey, value: .null, error: error)
      }
    } catch let error as any GatewayResolverError {
      return .init(key: root.responseKey, value: .null, error: .init(message: error.message, code: error.code, path: [root.responseKey]))
    } catch {
      return .init(key: root.responseKey, value: .null, error: .init(message: "resolver failed", code: "RESOLVER_ERROR", path: [root.responseKey]))
    }
  }

  private func envelope(data: GatewayJSONValue?, errors: [GatewayEnvelopeError], context: GatewayResolverContext, exitCode: Int32) -> GatewayEnvelope {
    let encodedErrors: [GatewayJSONValue] = errors.map { error in
      var object: [String: GatewayJSONValue] = ["message": .string(error.message)]
      if let code = error.code { object["code"] = .string(code) }
      if let path = error.path { object["path"] = .array(path.map(GatewayJSONValue.string)) }
      return .object(object)
    }
    let raw = (try? GatewayJSONValue.object([
      "data": data ?? .null,
      "errors": .array(encodedErrors),
      "extensions": .object(["requestId": .string(context.requestId)])
    ]).jsonString()) ?? ""
    return .init(data: data, errors: errors, requestId: context.requestId, exitCode: exitCode, rawOutput: raw)
  }
}

private struct FieldOutcome: Sendable {
  var key: String
  var value: GatewayJSONValue
  var error: GatewayEnvelopeError?
}
