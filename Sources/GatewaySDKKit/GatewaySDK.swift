import Foundation

/// The façade every gateway ships on top of this kit.
///
/// There is deliberately no associated type and no static catalog requirement: tiered
/// gateways build the façade inside their per-tier module and carry the catalog as an
/// instance value, so linking the kit never widens a tier.
public protocol GatewaySDK: Sendable {
  /// e.g. `"gmail-gateway"`.
  var provider: String { get }
  /// e.g. `"reader"`.
  var tier: String { get }
  var catalog: GatewaySchemaCatalog { get }

  /// Runs a document (or, for command gateways, a JSON-encoded argv array).
  ///
  /// `environment` is the only environment the call may observe.
  func execute(
    document: String,
    variables: [String: GatewayJSONValue],
    environment: [String: String]
  ) async -> GatewayEnvelope

  func invoke(_ request: GatewayOperationRequest, environment: [String: String]) async -> GatewayEnvelope
  func schemaSDL() -> String
  func searchSchema(
    _ pattern: String,
    options: GatewaySchemaSearch.Options
  ) throws -> [GatewaySchemaSearch.Match]
}

extension GatewaySDK {
  public func schemaSDL() -> String {
    catalog.sdl()
  }

  public func searchSchema(
    _ pattern: String,
    options: GatewaySchemaSearch.Options = .init()
  ) throws -> [GatewaySchemaSearch.Match] {
    try GatewaySchemaSearch(catalog: catalog).search(pattern, options: options)
  }

  /// Builds the request and hands it to `execute`.
  ///
  /// Commands take the argv path and arrive at `execute` as a compact JSON array in
  /// `document` with no variables; queries and mutations arrive as a GraphQL document
  /// plus its variables. A builder error becomes an envelope with exit code 2 rather
  /// than a thrown error, so callers have one result shape.
  public func invoke(
    _ request: GatewayOperationRequest,
    environment: [String: String] = [:]
  ) async -> GatewayEnvelope {
    do {
      if catalog.operation(named: request.operation)?.kind == .command {
        let argv = try GatewayArgvBuilder.build(request, catalog: catalog)
        let document = try GatewayJSONValue.array(argv.map { .string($0) }).jsonString()
        return await execute(document: document, variables: [:], environment: environment)
      }
      let built = try GatewayDocumentBuilder(catalog: catalog).build(request)
      return await execute(
        document: built.document,
        variables: built.variables,
        environment: environment
      )
    } catch {
      return GatewayEnvelope.failure(error, exitCode: 2)
    }
  }
}
