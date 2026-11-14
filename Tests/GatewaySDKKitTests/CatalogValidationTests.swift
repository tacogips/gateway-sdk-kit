import Foundation
import Testing
@testable import GatewaySDKKit

@Suite("Catalog model and validation")
struct CatalogValidationTests {
  @Test("both fixture catalogs decode and validate clean")
  func fixturesAreValid() {
    #expect(FixtureCatalogs.gmail.provider == "gmail-gateway")
    #expect(FixtureCatalogs.gmail.tier == "reader")
    #expect(FixtureCatalogs.gmail.validate() == [])
    #expect(FixtureCatalogs.documents.provider == "google-documents-gateway")
    #expect(FixtureCatalogs.documents.tier == "writer")
    #expect(FixtureCatalogs.documents.validate() == [])
  }

  @Test("a whole catalog survives an encode/decode round trip")
  func wireFormatRoundTrip() throws {
    for catalog in [FixtureCatalogs.gmail, FixtureCatalogs.documents] {
      let data = try JSONEncoder().encode(catalog)
      #expect(try JSONDecoder().decode(GatewaySchemaCatalog.self, from: data) == catalog)
    }
  }

  @Test("lookups find operations and types")
  func lookups() {
    let catalog = FixtureCatalogs.gmail
    #expect(catalog.operation(named: "threads")?.kind == .query)
    #expect(catalog.operation(named: "nope") == nil)
    #expect(catalog.namedType("Thread")?.objectFields?.count == 3)
    #expect(catalog.namedType("Direction")?.enumValues == ["INBOUND", "OUTBOUND"])
    #expect(catalog.namedType("SendMessageInput")?.inputFields?.count == 3)
    #expect(catalog.namedType("DateTime")?.objectFields == nil)
    #expect(catalog.operations(of: .query).map(\.name) == ["threads", "thread"])
    #expect(catalog.operations(of: .mutation).map(\.name) == ["sendMessage"])
    #expect(catalog.operations(of: .command).isEmpty)
    #expect(FixtureCatalogs.documents.operations(of: .command).count == 3)
  }

  @Test("builtin scalars need no named type entry")
  func builtins() {
    #expect(GatewaySchemaCatalog.builtinScalars == ["ID", "String", "Int", "Float", "Boolean", "JSON"])
  }

  @Test("definition kinds cover the seven catalog shapes")
  func definitionKinds() {
    #expect(GatewayDefinitionKind.allCases.map(\.rawValue) == [
      "query", "mutation", "command", "object", "inputObject", "enumeration", "scalar"
    ])
    #expect(GatewayOperation.Kind.query.definitionKind == .query)
    #expect(GatewayOperation.Kind.mutation.definitionKind == .mutation)
    #expect(GatewayOperation.Kind.command.definitionKind == .command)
    #expect(GatewayNamedType.Kind.scalar.definitionKind == .scalar)
    #expect(GatewayNamedType.Kind.object([]).definitionKind == .object)
    #expect(GatewayNamedType.Kind.inputObject([]).definitionKind == .inputObject)
    #expect(GatewayNamedType.Kind.enumeration([]).definitionKind == .enumeration)
  }

  // MARK: - Negative cases, one per validation rule

  @Test("unknown operation argument type")
  func unknownArgumentType() {
    let catalog = GatewaySchemaCatalog(
      provider: "p",
      tier: "t",
      operations: [
        GatewayOperation(
          name: "op",
          kind: .query,
          tier: "t",
          arguments: [GatewayArgument(name: "arg", type: .named("Nope"))],
          result: .named("Int")
        )
      ]
    )
    #expect(catalog.validate() == [
      GatewaySchemaProblem(path: "operation.op.arguments.arg", message: "unknown type 'Nope'")
    ])
  }

  @Test("unknown operation result type")
  func unknownResultType() {
    let catalog = GatewaySchemaCatalog(
      provider: "p",
      tier: "t",
      operations: [GatewayOperation(name: "op", kind: .query, tier: "t", result: .named("Nope"))]
    )
    #expect(catalog.validate() == [
      GatewaySchemaProblem(path: "operation.op.result", message: "unknown type 'Nope'")
    ])
  }

  @Test("unknown object field type and unknown field argument type")
  func unknownFieldTypes() {
    let catalog = GatewaySchemaCatalog(
      provider: "p",
      tier: "t",
      types: [
        GatewayNamedType(
          name: "Obj",
          kind: .object([
            GatewayField(
              name: "f",
              type: .named("MissingField"),
              arguments: [GatewayArgument(name: "a", type: .named("MissingArg"))]
            )
          ])
        )
      ]
    )
    #expect(catalog.validate() == [
      GatewaySchemaProblem(path: "type.Obj.fields.f", message: "unknown type 'MissingField'"),
      GatewaySchemaProblem(path: "type.Obj.fields.f.arguments.a", message: "unknown type 'MissingArg'")
    ])
  }

  @Test("unknown input object field type")
  func unknownInputFieldType() {
    let catalog = GatewaySchemaCatalog(
      provider: "p",
      tier: "t",
      types: [
        GatewayNamedType(name: "In", kind: .inputObject([GatewayArgument(name: "f", type: .named("Nope"))]))
      ]
    )
    #expect(catalog.validate() == [
      GatewaySchemaProblem(path: "type.In.fields.f", message: "unknown type 'Nope'")
    ])
  }

  @Test("duplicate operation names")
  func duplicateOperations() {
    let operation = GatewayOperation(name: "op", kind: .query, tier: "t", result: .named("Int"))
    let catalog = GatewaySchemaCatalog(provider: "p", tier: "t", operations: [operation, operation])
    #expect(catalog.validate() == [
      GatewaySchemaProblem(path: "operation.op", message: "duplicate operation name 'op'")
    ])
  }

  @Test("duplicate type names")
  func duplicateTypes() {
    let type = GatewayNamedType(name: "Obj", kind: .object([GatewayField(name: "f", type: .named("Int"))]))
    let catalog = GatewaySchemaCatalog(provider: "p", tier: "t", types: [type, type])
    #expect(catalog.validate() == [
      GatewaySchemaProblem(path: "type.Obj", message: "duplicate type name 'Obj'")
    ])
  }

  @Test("required argument with a default value, wherever arguments appear")
  func requiredArgumentWithDefault() {
    let catalog = GatewaySchemaCatalog(
      provider: "p",
      tier: "t",
      operations: [
        GatewayOperation(
          name: "op",
          kind: .query,
          tier: "t",
          arguments: [
            GatewayArgument(name: "a", type: .named("Int"), isRequired: true, defaultValue: .int(1))
          ],
          result: .named("Int")
        )
      ],
      types: [
        GatewayNamedType(
          name: "Obj",
          kind: .object([
            GatewayField(
              name: "f",
              type: .named("Int"),
              // Requiredness taken from the type's outer non-null, not just the flag.
              arguments: [GatewayArgument(name: "b", type: .nonNull(.named("Int")), defaultValue: .int(2))]
            )
          ])
        ),
        GatewayNamedType(
          name: "In",
          kind: .inputObject([
            GatewayArgument(name: "c", type: .named("Int"), isRequired: true, defaultValue: .null)
          ])
        )
      ]
    )
    #expect(catalog.validate() == [
      GatewaySchemaProblem(
        path: "operation.op.arguments.a",
        message: "required argument must not have a default value"
      ),
      GatewaySchemaProblem(
        path: "type.Obj.fields.f.arguments.b",
        message: "required argument must not have a default value"
      ),
      GatewaySchemaProblem(
        path: "type.In.fields.c",
        message: "required argument must not have a default value"
      )
    ])
  }

  @Test("query and mutation need a result; command does not")
  func missingResult() {
    let catalog = GatewaySchemaCatalog(
      provider: "p",
      tier: "t",
      operations: [
        GatewayOperation(name: "q", kind: .query, tier: "t"),
        GatewayOperation(name: "m", kind: .mutation, tier: "t"),
        GatewayOperation(name: "c", kind: .command, tier: "t"),
        GatewayOperation(name: "c2", kind: .command, tier: "t", result: .named("Int"))
      ]
    )
    #expect(catalog.validate() == [
      GatewaySchemaProblem(path: "operation.q.result", message: "operation kind 'query' requires a result type"),
      GatewaySchemaProblem(path: "operation.m.result", message: "operation kind 'mutation' requires a result type")
    ])
  }

  @Test("empty enum and empty object are problems, empty input object is not")
  func emptyDefinitions() {
    let catalog = GatewaySchemaCatalog(
      provider: "p",
      tier: "t",
      types: [
        GatewayNamedType(name: "E", kind: .enumeration([])),
        GatewayNamedType(name: "O", kind: .object([])),
        GatewayNamedType(name: "I", kind: .inputObject([])),
        GatewayNamedType(name: "S", kind: .scalar)
      ]
    )
    #expect(catalog.validate() == [
      GatewaySchemaProblem(path: "type.E", message: "enum type has no values"),
      GatewaySchemaProblem(path: "type.O", message: "object type has no fields")
    ])
  }

  @Test("isRequired disagreeing with the type's non-null is not itself a problem")
  func requirednessDisagreementAllowed() {
    let catalog = GatewaySchemaCatalog(
      provider: "p",
      tier: "t",
      operations: [
        GatewayOperation(
          name: "op",
          kind: .query,
          tier: "t",
          arguments: [GatewayArgument(name: "a", type: .named("Int"), isRequired: true)],
          result: .named("Int")
        )
      ]
    )
    #expect(catalog.validate() == [])
  }
}
