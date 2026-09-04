import Foundation
import Testing
@testable import GatewaySDKKit

@Suite("GatewayTypeRef")
struct TypeRefTests {
  @Test(
    "parse and graphQLString round trip",
    arguments: ["ID", "ID!", "[Int]", "[Int]!", "[Foo!]!", "[[X]!]", "[[X!]!]!"]
  )
  func roundTrip(_ spelling: String) throws {
    #expect(try GatewayTypeRef.parse(spelling).graphQLString == spelling)
  }

  @Test("parse builds the expected structure")
  func structure() throws {
    #expect(try GatewayTypeRef.parse("ID") == .named("ID"))
    #expect(try GatewayTypeRef.parse("ID!") == .nonNull(.named("ID")))
    #expect(try GatewayTypeRef.parse("[Int]") == .list(.named("Int")))
    #expect(try GatewayTypeRef.parse("[Foo!]!") == .nonNull(.list(.nonNull(.named("Foo")))))
    #expect(try GatewayTypeRef.parse("[[X]!]") == .list(.nonNull(.list(.named("X")))))
  }

  @Test("parse tolerates surrounding whitespace")
  func whitespace() throws {
    #expect(try GatewayTypeRef.parse(" [ Foo ! ] ! ") == .nonNull(.list(.nonNull(.named("Foo")))))
  }

  @Test("helpers report name, requiredness and listness")
  func helpers() throws {
    let ref = try GatewayTypeRef.parse("[Foo!]!")
    #expect(ref.namedTypeName == "Foo")
    #expect(ref.isRequired)
    #expect(ref.isList)
    #expect(ref.unwrappingNonNull == .list(.nonNull(.named("Foo"))))
    #expect(ref.listElementType == .nonNull(.named("Foo")))

    let plain = try GatewayTypeRef.parse("Int")
    #expect(plain.namedTypeName == "Int")
    #expect(!plain.isRequired)
    #expect(!plain.isList)
    #expect(plain.unwrappingNonNull == plain)
    #expect(plain.listElementType == nil)

    #expect(try GatewayTypeRef.parse("[Int]").isList)
    #expect(try !GatewayTypeRef.parse("[Int]").isRequired)
  }

  @Test(
    "malformed spellings throw invalidTypeReference",
    arguments: ["", "[", "]", "[Foo", "Foo]", "[]", "Foo Bar", "!", "1Foo", "Foo!!"]
  )
  func malformed(_ spelling: String) {
    #expect(throws: GatewaySDKError.self) {
      _ = try GatewayTypeRef.parse(spelling)
    }
  }

  @Test("Codable uses the GraphQL spelling as a single JSON string")
  func codable() throws {
    let ref = GatewayTypeRef.nonNull(.list(.nonNull(.named("Foo"))))
    let data = try JSONEncoder().encode(ref)
    #expect(String(bytes: data, encoding: .utf8) == "\"[Foo!]!\"")
    #expect(try JSONDecoder().decode(GatewayTypeRef.self, from: data) == ref)
  }

  @Test("decoding an invalid spelling surfaces a DecodingError")
  func codableFailure() {
    let data = Data("\"[Foo\"".utf8)
    #expect(throws: DecodingError.self) {
      _ = try JSONDecoder().decode(GatewayTypeRef.self, from: data)
    }
  }
}
