import Foundation
import Testing
@testable import GatewaySDKKit

/// A minimal conformance that implements only the four required members and records
/// what the default `invoke` handed to `execute`.
private final class RecordingSDK: GatewaySDK, @unchecked Sendable {
  struct Call: Equatable {
    var document: String
    var variables: [String: GatewayJSONValue]
    var environment: [String: String]
  }

  let provider: String
  let tier: String
  let catalog: GatewaySchemaCatalog
  private(set) var calls: [Call] = []
  var response = GatewayEnvelope(data: .object(["ok": .bool(true)]), exitCode: 0, rawOutput: "{}")

  init(catalog: GatewaySchemaCatalog, provider: String = "test-gateway", tier: String = "reader") {
    self.catalog = catalog
    self.provider = provider
    self.tier = tier
  }

  func execute(
    document: String,
    variables: [String: GatewayJSONValue],
    environment: [String: String]
  ) async -> GatewayEnvelope {
    calls.append(Call(document: document, variables: variables, environment: environment))
    return response
  }
}

/// A conformer that overrides both defaulted members, used to prove the one-argument
/// convenience spellings dispatch through the witness table rather than shadowing the
/// override with an extension default argument.
private struct OverridingSDK: GatewaySDK {
  let provider = "overriding-gateway"
  let tier = "reader"
  let catalog: GatewaySchemaCatalog

  func execute(
    document: String,
    variables: [String: GatewayJSONValue],
    environment: [String: String]
  ) async -> GatewayEnvelope {
    GatewayEnvelope(rawOutput: "unused")
  }

  func invoke(_ request: GatewayOperationRequest, environment: [String: String]) async -> GatewayEnvelope {
    GatewayEnvelope(data: .string("overridden invoke"), rawOutput: "overridden")
  }

  func searchSchema(
    _ pattern: String,
    options: GatewaySchemaSearch.Options
  ) throws -> [GatewaySchemaSearch.Match] {
    [GatewaySchemaSearch.Match(kind: .query, name: "overridden search")]
  }
}

@Suite("GatewaySDK protocol")
struct GatewaySDKProtocolTests {
  @Test("the default invoke sends the built document and variables")
  func invokeBuildsDocument() async {
    let sdk = RecordingSDK(catalog: FixtureCatalogs.gmail)
    let envelope = await sdk.invoke(
      GatewayOperationRequest(
        operation: "threads",
        variables: ["accountId": .string("a"), "first": .int(2)],
        selection: .fields(["totalCount"])
      ),
      environment: ["GMAIL_TOKEN": "t"]
    )
    #expect(envelope == sdk.response)
    #expect(sdk.calls.count == 1)
    #expect(
      sdk.calls[0].document == """
        query Threads($accountId: ID!, $first: Int) {
          threads(accountId: $accountId, first: $first) {
            totalCount
          }
        }
        """
    )
    #expect(sdk.calls[0].variables == ["accountId": .string("a"), "first": .int(2)])
    #expect(sdk.calls[0].environment == ["GMAIL_TOKEN": "t"])
  }

  @Test("the default invoke sends a command as a compact JSON argv array with no variables")
  func invokeBuildsArgv() async {
    let sdk = RecordingSDK(catalog: FixtureCatalogs.documents, provider: "google-documents-gateway", tier: "writer")
    _ = await sdk.invoke(
      GatewayOperationRequest(
        operation: "files delete",
        variables: ["file-id": .string("f-1"), "confirm": .bool(true)]
      )
    )
    #expect(sdk.calls[0].document == #"["files","delete","--file-id","f-1","--confirm"]"#)
    #expect(sdk.calls[0].variables.isEmpty)
    #expect(sdk.calls[0].environment.isEmpty)
  }

  @Test("a builder error becomes a failure envelope with exit code 2 and no execute call")
  func invokeSurfacesBuilderErrors() async {
    let sdk = RecordingSDK(catalog: FixtureCatalogs.gmail)
    let envelope = await sdk.invoke(GatewayOperationRequest(operation: "nope"))
    #expect(envelope.exitCode == 2)
    #expect(envelope.errors == [GatewayEnvelopeError(message: "unknown operation 'nope'")])
    #expect(envelope.data == nil)
    #expect(sdk.calls.isEmpty)

    let missing = await sdk.invoke(GatewayOperationRequest(operation: "threads"))
    #expect(missing.exitCode == 2)
    #expect(missing.errors == [GatewayEnvelopeError(message: "operation 'threads' requires variable 'accountId'")])
    #expect(sdk.calls.isEmpty)
  }

  @Test("an argv builder error also becomes a failure envelope")
  func invokeSurfacesArgvErrors() async {
    let sdk = RecordingSDK(catalog: FixtureCatalogs.documents)
    let envelope = await sdk.invoke(GatewayOperationRequest(operation: "values get"))
    #expect(envelope.exitCode == 2)
    #expect(
      envelope.errors == [
        GatewayEnvelopeError(message: "operation 'values get' requires variable 'spreadsheet-id'")
      ]
    )
    #expect(sdk.calls.isEmpty)
  }

  @Test("schemaSDL delegates to the catalog")
  func schemaSDLDefault() {
    let sdk = RecordingSDK(catalog: FixtureCatalogs.gmail)
    #expect(sdk.schemaSDL() == FixtureCatalogs.gmail.sdl())
  }

  @Test("searchSchema delegates to GatewaySchemaSearch")
  func searchSchemaDefault() throws {
    let sdk = RecordingSDK(catalog: FixtureCatalogs.gmail)
    let expected = try GatewaySchemaSearch(catalog: FixtureCatalogs.gmail).search("thread")
    #expect(try sdk.searchSchema("thread") == expected)
    #expect(try sdk.searchSchema("thread", options: .init(limit: 1)).count == 1)
    #expect(throws: GatewaySDKError.self) {
      _ = try sdk.searchSchema("[")
    }
    #expect {
      _ = try sdk.searchSchema("(.+)+Z")
    } throws: { error in
      error as? GatewaySDKError == .invalidPattern("search pattern does not support unbounded quantifiers")
    }
  }

  @Test("the one-argument conveniences honour a conformer's override")
  func conveniencesDispatchThroughTheWitness() async throws {
    let sdk = OverridingSDK(catalog: FixtureCatalogs.gmail)

    // Both spellings must reach the override, not the extension default.
    #expect(await sdk.invoke(GatewayOperationRequest(operation: "threads")).data == .string("overridden invoke"))
    #expect(
      await sdk.invoke(GatewayOperationRequest(operation: "threads"), environment: [:]).data
        == .string("overridden invoke")
    )
    #expect(try sdk.searchSchema("anything").map(\.name) == ["overridden search"])
    #expect(try sdk.searchSchema("anything", options: .init()).map(\.name) == ["overridden search"])
  }

  @Test("provider, tier and catalog are carried as instance values")
  func identity() {
    let sdk = RecordingSDK(catalog: FixtureCatalogs.gmail)
    #expect(sdk.provider == "test-gateway")
    #expect(sdk.tier == "reader")
    #expect(sdk.catalog == FixtureCatalogs.gmail)
  }
}
