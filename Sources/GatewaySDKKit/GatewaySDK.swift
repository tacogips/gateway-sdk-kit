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

  /// Override this two-argument form to customise invocation; the one-argument
  /// convenience below forwards to it.
  func invoke(_ request: GatewayOperationRequest, environment: [String: String]) async -> GatewayEnvelope
  func schemaSDL() -> String
  /// Override this two-argument form to customise search; the one-argument convenience
  /// below forwards to it.
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
    options: GatewaySchemaSearch.Options
  ) throws -> [GatewaySchemaSearch.Match] {
    try GatewaySchemaSearch(catalog: catalog).search(pattern, options: options)
  }

  /// Searches with default options.
  ///
  /// Deliberately a separate one-argument overload rather than a default argument on
  /// the witness above: a default argument would make `sdk.searchSchema("x")` resolve
  /// statically to this extension's body, silently skipping a conformer's override.
  /// Forwarding through `self` dispatches via the witness table instead.
  public func searchSchema(_ pattern: String) throws -> [GatewaySchemaSearch.Match] {
    try searchSchema(pattern, options: .init())
  }

  /// Builds the request and hands it to `execute`.
  ///
  /// Commands take the argv path and arrive at `execute` as a compact JSON array in
  /// `document` with no variables; queries and mutations arrive as a GraphQL document
  /// plus its variables. A builder error becomes an envelope with exit code 2 rather
  /// than a thrown error, so callers have one result shape.
  public func invoke(
    _ request: GatewayOperationRequest,
    environment: [String: String]
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

  /// Invokes with an empty environment. A separate overload for the same reason as
  /// `searchSchema(_:)` above: it must dispatch through the witness, not shadow it.
  public func invoke(_ request: GatewayOperationRequest) async -> GatewayEnvelope {
    await invoke(request, environment: [:])
  }
}
