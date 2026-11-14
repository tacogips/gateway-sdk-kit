import Foundation
import Testing
@testable import GatewaySDKKit

/// Drives every public entry point that consumes catalog-supplied names through one
/// deliberately malformed catalog.
///
/// A catalog is runtime JSON shipped by five separate gateways, so duplicate names are
/// data this kit must survive, not a programmer error. Five name-keyed lookups used
/// `Dictionary(uniqueKeysWithValues:)`, which *traps* on a duplicate — an uncatchable
/// crash that bypasses the whole throwing-`GatewaySDKError` contract and takes the
/// process down. A trap cannot be caught in Swift, so a per-site test would not have
/// helped: the first crash ends the run. This suite exists to cover the class, so a new
/// name-keyed lookup added anywhere is exercised by it automatically.
@Suite("Hostile catalog")
struct HostileCatalogTests {
  /// Duplicates in every position the model allows: operation names and arguments,
  /// command flags, object fields, object-field arguments, input-object fields, and enum values.
  static let duplicated = GatewaySchemaCatalog(
    provider: "hostile",
    tier: "reader",
    operations: [
      GatewayOperation(
        name: "dup",
        kind: .query,
        tier: "reader",
        arguments: [
          GatewayArgument(name: "arg", type: .named("Int")),
          GatewayArgument(name: "arg", type: .named("Int"))
        ],
        result: .named("DupObject")
      ),
      GatewayOperation(
        name: "dup",
        kind: .query,
        tier: "reader",
        arguments: [GatewayArgument(name: "ignoredSecondDefinition", type: .named("String"))],
        result: .named("DupObject")
      ),
      GatewayOperation(
        name: "dup cmd",
        kind: .command,
        tier: "reader",
        arguments: [
          GatewayArgument(name: "flag", type: .named("Int")),
          GatewayArgument(name: "flag", type: .named("Int"))
        ]
      ),
      GatewayOperation(
        name: "takesInput",
        kind: .query,
        tier: "reader",
        arguments: [GatewayArgument(name: "input", type: .named("DupInput"))],
        result: .named("DupObject")
      )
    ],
    types: [
      GatewayNamedType(
        name: "DupObject",
        kind: .object([
          GatewayField(name: "field", type: .named("Int")),
          GatewayField(
            name: "field",
            type: .named("String"),
            arguments: [
              GatewayArgument(name: "sameArg", type: .named("Int")),
              GatewayArgument(name: "sameArg", type: .named("Int"))
            ]
          )
        ])
      ),
      GatewayNamedType(
        name: "DupInput",
        kind: .inputObject([
          GatewayArgument(name: "member", type: .named("Int")),
          GatewayArgument(name: "member", type: .named("Int"))
        ])
      ),
      GatewayNamedType(name: "DupEnum", kind: .enumeration(["SAME", "SAME"]))
    ]
  )

  // MARK: - Every catalog-consuming entry point

  @Test("the variable type check survives duplicate input-object field names")
  func typeCheckDoesNotTrap() {
    let catalog = Self.duplicated
    // Returning either verdict is fine; trapping is not.
    _ = GatewayVariableTypeCheck.matches(.object(["member": .int(1)]), .named("DupInput"), catalog)
    _ = GatewayVariableTypeCheck.matches(.object(["absent": .int(1)]), .named("DupInput"), catalog)
    #expect(throws: Never.self) {
      try? GatewayVariableTypeCheck.check(
        .object(["member": .int(1)]),
        against: .named("DupInput"),
        name: "input",
        catalog: catalog
      )
    }
  }

  @Test("the document builder survives duplicate argument names")
  func documentBuilderDoesNotTrap() {
    let builder = GatewayDocumentBuilder(catalog: Self.duplicated)
    // Each call either returns a document or throws a GatewaySDKError; neither traps.
    for variables: [String: GatewayJSONValue] in [[:], ["arg": .int(1)], ["nope": .int(1)]] {
      let request = GatewayOperationRequest(operation: "dup", variables: variables)
      #expect(throws: Never.self) {
        do {
          _ = try builder.build(request)
        } catch is GatewaySDKError {
          // Expected shape of failure.
        }
      }
    }
  }

  @Test("the argv builder survives duplicate flag names")
  func argvBuilderDoesNotTrap() {
    for variables: [String: GatewayJSONValue] in [[:], ["flag": .int(1)], ["nope": .int(1)]] {
      let request = GatewayOperationRequest(operation: "dup cmd", variables: variables)
      #expect(throws: Never.self) {
        do {
          _ = try GatewayArgvBuilder.build(request, catalog: Self.duplicated)
        } catch is GatewaySDKError {
          // Expected shape of failure.
        }
      }
    }
  }

  @Test("the SDL printer and fragment printer survive a duplicated catalog")
  func sdlDoesNotTrap() {
    #expect(!Self.duplicated.sdl().isEmpty)
    #expect(Self.duplicated.sdlFragment(for: .object, name: "DupObject") != nil)
    #expect(Self.duplicated.sdlFragment(for: .inputObject, name: "DupInput") != nil)
    #expect(Self.duplicated.sdlFragment(for: .enumeration, name: "DupEnum") != nil)
    #expect(Self.duplicated.sdlFragment(for: .query, name: "dup") != nil)
  }

  @Test("schema search survives a duplicated catalog, including referenced-type expansion")
  func searchDoesNotTrap() throws {
    let search = GatewaySchemaSearch(catalog: Self.duplicated)
    #expect(try !search.search("dup", options: .init(includeReferencedTypes: true)).isEmpty)
    #expect(try !search.search("SAME", options: .init(kinds: [.enumeration])).isEmpty)
    #expect(try !search.search("member").isEmpty)
  }

  @Test("the selection planner and a raw selection survive a duplicated catalog")
  func selectionDoesNotTrap() {
    _ = GatewaySelectionPlanner.defaultSelection(of: "DupObject", catalog: Self.duplicated)
    let builder = GatewayDocumentBuilder(catalog: Self.duplicated)
    #expect(throws: Never.self) {
      do {
        _ = try builder.build(
          GatewayOperationRequest(operation: "dup", selection: .raw("{ field }"))
        )
        _ = try builder.build(
          GatewayOperationRequest(operation: "dup", selection: .fields(["field"]))
        )
      } catch is GatewaySDKError {}
    }
  }

  @Test("GatewaySDK.invoke survives a duplicated catalog on both the document and argv paths")
  func invokeDoesNotTrap() async {
    let sdk = HostileSDK(catalog: Self.duplicated)
    // invoke never throws; a builder error becomes a failure envelope.
    _ = await sdk.invoke(GatewayOperationRequest(operation: "dup", variables: ["arg": .int(1)]))
    _ = await sdk.invoke(GatewayOperationRequest(operation: "dup cmd", variables: ["flag": .int(1)]))
    #expect(!sdk.catalog.provider.isEmpty)
  }

  // MARK: - validate() reports the duplicates rather than passing them

  @Test("validate reports every duplicate name with its dotted path")
  func validateReportsDuplicates() {
    let problems = Self.duplicated.validate()
    let duplicates = problems.filter { $0.message.hasPrefix("duplicate ") }
    // One assertion per position the fixture carries, so the header comment above is
    // checkable rather than aspirational. Round 6 asserted five of six and left the
    // enum-value case unread, which is how the gap survived a round.
    #expect(duplicates.contains(
      GatewaySchemaProblem(path: "operation.dup.arguments.arg", message: "duplicate argument name 'arg'")
    ))
    #expect(duplicates.contains(
      GatewaySchemaProblem(path: "operation.dup", message: "duplicate operation name 'dup'")
    ))
    #expect(duplicates.contains(
      GatewaySchemaProblem(path: "operation.dup cmd.arguments.flag", message: "duplicate argument name 'flag'")
    ))
    #expect(duplicates.contains(
      GatewaySchemaProblem(path: "type.DupObject.fields.field", message: "duplicate field name 'field'")
    ))
    #expect(duplicates.contains(
      GatewaySchemaProblem(
        path: "type.DupObject.fields.field.arguments.sameArg",
        message: "duplicate argument name 'sameArg'"
      )
    ))
    #expect(duplicates.contains(
      GatewaySchemaProblem(path: "type.DupInput.fields.member", message: "duplicate field name 'member'")
    ))
    #expect(duplicates.contains(
      GatewaySchemaProblem(path: "type.DupEnum.values.SAME", message: "duplicate enum value name 'SAME'")
    ))
    #expect(duplicates.count == 7)
  }

  @Test("a clean catalog reports no duplicate problems")
  func cleanCatalogsHaveNoDuplicates() {
    for catalog in [FixtureCatalogs.gmail, FixtureCatalogs.documents] {
      #expect(catalog.validate() == [])
    }
  }

  @Test("the GraphQL runtime survives duplicated catalog names")
  func runtimeDoesNotTrap() async throws {
    let document = try GatewayGraphQLParser.parse("{ dup(arg: 1) { field } }")
    let validated = try GatewayGraphQLValidator(catalog: Self.duplicated).validate(document)
    #expect(validated.rootFields == [
      .init(
        responseKey: "dup",
        name: "dup",
        arguments: ["arg": .int(1)],
        selectionSet: [.init(name: "field")],
        operation: Self.duplicated.operations[0]
      )
    ])
    let runtime = try GatewayGraphQLRuntime(
      catalog: Self.duplicated,
      resolvers: [
        "dup": { _, _ in .object(["field": .int(1)]) },
        "takesInput": { _, _ in .object(["field": .int(1)]) }
      ]
    )
    let duplicateOperationEnvelope = await runtime.execute(document: "{ dup(arg: 1) { field } }", context: .init())
    #expect(duplicateOperationEnvelope.exitCode == 0)
    #expect(duplicateOperationEnvelope.data == .object(["dup": .object(["field": .int(1)])]))
    let envelope = await runtime.execute(document: "{ takesInput(input: {member: 1}) { field } }", context: .init())
    #expect(envelope.exitCode == 0)
    #expect(envelope.data == .object(["takesInput": .object(["field": .int(1)])]))
  }
}

/// A conformer used only to drive `invoke`'s two paths over a hostile catalog.
private struct HostileSDK: GatewaySDK {
  let provider = "hostile-gateway"
  let tier = "reader"
  let catalog: GatewaySchemaCatalog

  func execute(
    document: String,
    variables: [String: GatewayJSONValue],
    environment: [String: String]
  ) async -> GatewayEnvelope {
    GatewayEnvelope(rawOutput: document)
  }
}
