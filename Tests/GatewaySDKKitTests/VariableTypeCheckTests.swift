import Foundation
import Testing
@testable import GatewaySDKKit

@Suite("Variable type check")
struct VariableTypeCheckTests {
  /// The gmail fixture plus one input object carrying a JSON-typed field, which the
  /// fixture has no reason to model but the nested-non-finite rules need.
  private let catalog: GatewaySchemaCatalog = {
    var catalog = FixtureCatalogs.gmail
    catalog.types.append(
      GatewayNamedType(
        name: "JSONHolder",
        kind: .inputObject([GatewayArgument(name: "payload", type: .named("JSON"))])
      )
    )
    return catalog
  }()

  private func accepts(_ value: GatewayJSONValue, _ type: String) throws -> Bool {
    GatewayVariableTypeCheck.matches(value, try GatewayTypeRef.parse(type), catalog)
  }

  @Test("null is accepted for optional types and rejected for required ones")
  func nullRules() throws {
    #expect(try accepts(.null, "String"))
    #expect(try accepts(.null, "[String]"))
    #expect(try accepts(.null, "JSON"))
    #expect(try !accepts(.null, "String!"))
    #expect(try !accepts(.null, "[String]!"))
    #expect(try accepts(.array([.null]), "[String]"))
    #expect(try !accepts(.array([.null]), "[String!]"))
  }

  @Test("ID and String accept strings only")
  func stringScalars() throws {
    #expect(try accepts(.string("x"), "ID"))
    #expect(try accepts(.string("x"), "String!"))
    #expect(try !accepts(.int(1), "ID"))
    #expect(try !accepts(.bool(true), "String"))
  }

  @Test("Int accepts ints; Float accepts ints and doubles")
  func numericScalars() throws {
    #expect(try accepts(.int(1), "Int"))
    #expect(try !accepts(.double(1.5), "Int"))
    #expect(try !accepts(.string("1"), "Int"))
    #expect(try accepts(.int(1), "Float"))
    #expect(try accepts(.double(1.5), "Float"))
    #expect(try !accepts(.string("1.5"), "Float"))
  }

  @Test("Boolean accepts bools only")
  func booleanScalar() throws {
    #expect(try accepts(.bool(false), "Boolean"))
    #expect(try !accepts(.int(0), "Boolean"))
    #expect(try !accepts(.string("true"), "Boolean"))
  }

  @Test("JSON accepts anything, including null when optional")
  func jsonScalar() throws {
    #expect(try accepts(.object(["a": .int(1)]), "JSON"))
    #expect(try accepts(.array([.bool(true)]), "JSON!"))
    #expect(try accepts(.string("x"), "JSON"))
    #expect(try accepts(.null, "JSON"))
    #expect(try !accepts(.null, "JSON!"))
  }

  @Test("a custom scalar accepts any non-null value")
  func customScalar() throws {
    #expect(try accepts(.string("2026-09-04T00:00:00Z"), "DateTime"))
    #expect(try accepts(.int(1), "DateTime"))
    #expect(try !accepts(.null, "DateTime!"))
  }

  @Test("enums accept one of their values")
  func enums() throws {
    #expect(try accepts(.string("INBOUND"), "Direction"))
    #expect(try accepts(.string("OUTBOUND"), "Direction!"))
    #expect(try !accepts(.string("SIDEWAYS"), "Direction"))
    #expect(try !accepts(.int(0), "Direction"))
  }

  @Test("lists accept arrays and auto-wrap a single value")
  func lists() throws {
    #expect(try accepts(.array([.string("a"), .string("b")]), "[String!]!"))
    #expect(try accepts(.string("a"), "[String!]!"))
    #expect(try !accepts(.array([.int(1)]), "[String]"))
    #expect(try !accepts(.int(1), "[String]"))
    #expect(try accepts(.array([]), "[String!]!"))
    #expect(try accepts(.array([.array([.string("a")])]), "[[String]]"))
  }

  @Test("input objects check every key and every required field")
  func inputObjects() throws {
    #expect(try accepts(.object(["to": .array([.string("a")])]), "SendMessageInput"))
    #expect(
      try accepts(
        .object(["to": .string("a"), "subject": .string("s"), "direction": .string("INBOUND")]),
        "SendMessageInput!"
      )
    )
    // Unknown key.
    #expect(try !accepts(.object(["to": .array([.string("a")]), "nope": .int(1)]), "SendMessageInput"))
    // Missing required field.
    #expect(try !accepts(.object(["subject": .string("s")]), "SendMessageInput"))
    // Required field explicitly null.
    #expect(try !accepts(.object(["to": .null]), "SendMessageInput"))
    // Wrong type for a present field.
    #expect(try !accepts(.object(["to": .array([.string("a")]), "direction": .string("NOPE")]), "SendMessageInput"))
    // Not an object at all.
    #expect(try !accepts(.string("x"), "SendMessageInput"))
  }

  @Test("an object type used as a variable type never matches")
  func outputObjectsRejected() throws {
    #expect(try !accepts(.object(["id": .string("x")]), "Thread"))
  }

  @Test("an unknown named type never matches")
  func unknownNamedType() throws {
    #expect(try !accepts(.string("x"), "Nope"))
    #expect(try accepts(.null, "Nope"))
  }

  @Test("a non-finite double matches no type, not even JSON")
  func nonFiniteDoublesRejected() throws {
    for number in [Double.infinity, -.infinity, .nan] {
      #expect(try !accepts(.double(number), "Float"))
      #expect(try !accepts(.double(number), "JSON"))
      #expect(try !accepts(.double(number), "[Float]"))
      #expect(try !accepts(.array([.double(number)]), "[Float]"))
    }
    #expect(try accepts(.double(1.5), "Float"))
  }

  @Test("the non-finite rejection reaches nested values, including under JSON and custom scalars")
  func nonFiniteDoublesRejectedWhenNested() throws {
    // JSON and custom scalars accept without descending into the value, so the scan has
    // to be a whole-value walk or an `inf` buried in an object or array slips through
    // validation and is rendered bare by the non-throwing literal renderer.
    for number in [Double.infinity, -.infinity, .nan] {
      for type in ["JSON", "DateTime"] {
        #expect(try !accepts(.object(["x": .double(number)]), type))
        #expect(try !accepts(.array([.double(number)]), type))
        // Buried two levels down.
        #expect(try !accepts(.object(["a": .array([.object(["b": .double(number)])])]), type))
      }
      // Through an input object whose field is JSON-typed.
      #expect(try !accepts(.object(["payload": .array([.double(number)])]), "JSONHolder"))
    }
    // The same shapes with finite doubles are still accepted.
    #expect(try accepts(.object(["x": .double(1.5)]), "JSON"))
    #expect(try accepts(.object(["a": .array([.object(["b": .double(2)])])]), "DateTime"))
    #expect(try accepts(.object(["payload": .array([.double(3.5)])]), "JSONHolder"))
  }

  @Test("containsNonFiniteDouble walks arrays and objects and ignores other cases")
  func nonFiniteScan() {
    #expect(GatewayVariableTypeCheck.containsNonFiniteDouble(.double(.infinity)))
    #expect(GatewayVariableTypeCheck.containsNonFiniteDouble(.array([.int(1), .double(.nan)])))
    #expect(GatewayVariableTypeCheck.containsNonFiniteDouble(.object(["k": .array([.double(-.infinity)])])))
    #expect(!GatewayVariableTypeCheck.containsNonFiniteDouble(.object(["k": .array([.double(1)])])))
    #expect(!GatewayVariableTypeCheck.containsNonFiniteDouble(.null))
    #expect(!GatewayVariableTypeCheck.containsNonFiniteDouble(.string("inf")))
    #expect(!GatewayVariableTypeCheck.containsNonFiniteDouble(.bool(true)))
    #expect(!GatewayVariableTypeCheck.containsNonFiniteDouble(.int(1)))
  }

  @Test("check throws variableTypeMismatch naming the outermost variable")
  func mismatchError() {
    #expect {
      try GatewayVariableTypeCheck.check(
        .int(1),
        against: .nonNull(.named("ID")),
        name: "accountId",
        catalog: catalog
      )
    } throws: { error in
      error as? GatewaySDKError == .variableTypeMismatch(name: "accountId", expected: "ID!", actual: "int")
    }

    #expect {
      try GatewayVariableTypeCheck.check(
        .object(["to": .array([.string("a")]), "nope": .int(1)]),
        against: .named("SendMessageInput"),
        name: "input",
        catalog: catalog
      )
    } throws: { error in
      error as? GatewaySDKError
        == .variableTypeMismatch(name: "input", expected: "SendMessageInput", actual: "object")
    }
  }

  @Test("the document builder surfaces the same mismatch for every rule")
  func throughTheBuilder() {
    let builder = GatewayDocumentBuilder(catalog: catalog)
    #expect {
      _ = try builder.build(
        GatewayOperationRequest(operation: "threads", variables: ["accountId": .string("a"), "first": .string("20")])
      )
    } throws: { error in
      error as? GatewaySDKError == .variableTypeMismatch(name: "first", expected: "Int", actual: "string")
    }
  }
}
