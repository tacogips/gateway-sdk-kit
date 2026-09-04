import Foundation
import Testing
@testable import GatewaySDKKit

@Suite("Argv builder")
struct ArgvBuilderTests {
  private let catalog = FixtureCatalogs.documents

  private func build(
    _ operation: String,
    _ variables: [String: GatewayJSONValue],
    selection: GatewaySelection = .default
  ) throws -> [String] {
    try GatewayArgvBuilder.build(
      GatewayOperationRequest(operation: operation, variables: variables, selection: selection),
      catalog: catalog
    )
  }

  @Test("the command name splits on spaces and flags follow in catalog order")
  func commandNameAndOrder() throws {
    #expect(
      try build(
        "values get",
        [
          "range": .string("Sheet1!A1:B2"),
          "spreadsheet-id": .string("sheet-1"),
          "major-dimension": .string("ROWS")
        ]
      ) == [
        "values", "get",
        "--spreadsheet-id", "sheet-1",
        "--range", "Sheet1!A1:B2",
        "--major-dimension", "ROWS"
      ]
    )
  }

  @Test("boolean true becomes a bare flag and false is omitted entirely")
  func booleanFlags() throws {
    #expect(
      try build("files delete", ["file-id": .string("f-1"), "confirm": .bool(true)])
        == ["files", "delete", "--file-id", "f-1", "--confirm"]
    )
    #expect(
      try build("files delete", ["file-id": .string("f-1"), "confirm": .bool(false)])
        == ["files", "delete", "--file-id", "f-1"]
    )
  }

  @Test("a list repeats the flag once per element")
  func listFlags() throws {
    #expect(
      try build("files list", ["fields": .array([.string("id"), .string("name")])])
        == ["files", "list", "--fields", "id", "--fields", "name"]
    )
    #expect(try build("files list", ["fields": .array([])]) == ["files", "list"])
    // A single value against a list type is coerced, so the flag appears once.
    #expect(try build("files list", ["fields": .string("id")]) == ["files", "list", "--fields", "id"])
  }

  @Test("an object flag renders as compact sorted-key JSON")
  func objectFlags() throws {
    #expect(
      try build(
        "values get",
        [
          "spreadsheet-id": .string("s"),
          "range": .string("A1"),
          "value-input": .object(["values": .array([.string("a")]), "majorDimension": .string("ROWS")])
        ]
      ) == [
        "values", "get",
        "--spreadsheet-id", "s",
        "--range", "A1",
        "--value-input", #"{"majorDimension":"ROWS","values":["a"]}"#
      ]
    )
  }

  @Test("numbers render in decimal and an explicit null omits the flag")
  func numberAndNullFlags() throws {
    #expect(
      try build("files list", ["page-size": .int(20), "query": .null])
        == ["files", "list", "--page-size", "20"]
    )
  }

  @Test("selection is ignored for commands")
  func selectionIgnored() throws {
    let flags = try build("files delete", ["file-id": .string("f")], selection: .raw("{ nonsense"))
    #expect(flags == ["files", "delete", "--file-id", "f"])
    #expect(try build("files delete", ["file-id": .string("f")], selection: .fields(["nope"])) == flags)
  }

  @Test("unknown operation")
  func unknownOperation() {
    #expect {
      _ = try build("nope", [:])
    } throws: { error in
      error as? GatewaySDKError == .unknownOperation(name: "nope")
    }
  }

  @Test("a GraphQL operation must go through the document builder")
  func graphQLNeedsDocument() {
    #expect {
      _ = try GatewayArgvBuilder.build(
        GatewayOperationRequest(operation: "threads"),
        catalog: FixtureCatalogs.gmail
      )
    } throws: { error in
      error as? GatewaySDKError == .graphQLOperationNeedsDocument(name: "threads")
    }
  }

  @Test("unknown flag")
  func unknownVariable() {
    #expect {
      _ = try build("files delete", ["file-id": .string("f"), "bogus": .int(1)])
    } throws: { error in
      error as? GatewaySDKError == .unknownVariable(operation: "files delete", name: "bogus")
    }
  }

  @Test("a required flag must be supplied with a non-null value")
  func missingRequiredFlag() {
    #expect {
      _ = try build("values get", ["range": .string("A1")])
    } throws: { error in
      error as? GatewaySDKError == .missingRequiredVariable(operation: "values get", name: "spreadsheet-id")
    }
    #expect {
      _ = try build("values get", ["spreadsheet-id": .null, "range": .string("A1")])
    } throws: { error in
      error as? GatewaySDKError == .missingRequiredVariable(operation: "values get", name: "spreadsheet-id")
    }
  }

  @Test("flag values are type-checked")
  func typeChecked() {
    #expect {
      _ = try build("files list", ["page-size": .string("20")])
    } throws: { error in
      error as? GatewaySDKError == .variableTypeMismatch(name: "page-size", expected: "Int", actual: "string")
    }
    #expect {
      _ = try build("values get", ["spreadsheet-id": .string("s"), "range": .string("A1"), "major-dimension": .string("DIAGONAL")])
    } throws: { error in
      error as? GatewaySDKError
        == .variableTypeMismatch(name: "major-dimension", expected: "Dimension", actual: "string")
    }
  }
}
