import Testing
@testable import GatewaySDKKit

@Suite("GraphQL validator")
struct GraphQLValidatorTests {
  private let validator = GatewayGraphQLValidator(catalog: FixtureCatalogs.runtime)

  @Test("coerces nested input variables and applies input defaults")
  func coercesInput() throws {
    let document = try GatewayGraphQLParser.parse(#"query Q($id: ID!, $limit: Int) { threads(input: {accountId: $id, limit: $limit, direction: INBOUND}) { totalCount } }"#)
    let validated = try validator.validate(document, variables: ["id": .string("a1")])
    #expect(validated.rootFields[0].arguments == ["input": .object(["accountId": .string("a1"), "direction": .string("INBOUND"), "limit": .int(25)])])
  }

  @Test("reports each stable validation code")
  func stableCodes() throws {
    try expectCode("UNKNOWN_FIELD", "{ missing { id } }")
    try expectCode("UNKNOWN_ARGUMENT", #"{ labels(accountId: "a", extra: 1) { name } }"#)
    try expectCode("MISSING_ARGUMENT", "{ labels { name } }")
    try expectCode("ARGUMENT_TYPE", "{ labels(accountId: 1) { name } }")
    try expectCode("UNKNOWN_VARIABLE", #"{ labels(accountId: "a") { name } }"#, variables: ["extra": .string("x")])
    try expectCode("UNUSED_VARIABLE", #"query($id: ID) { labels(accountId: "a") { name } }"#)
    try expectCode("UNDECLARED_VARIABLE", "{ labels(accountId: $id) { name } }")
    try expectCode("MISSING_VARIABLE", "query($id: ID!) { labels(accountId: $id) { name } }")
    try expectCode("VARIABLE_TYPE", "query($id: Int) { labels(accountId: $id) { name } }")
    try expectCode("INVALID_SELECTION", #"{ labels(accountId: "a") { name { x } } }"#)
    try expectCode("MULTIPLE_MUTATIONS", #"mutation { first: sendMessage(input: {accountId: "a", to: ["b"], body: "x"}) { messageId } second: sendMessage(input: {accountId: "a", to: ["b"], body: "x"}) { messageId } }"#)
    try expectCode("DUPLICATE_ALIAS", #"{ x: labels(accountId: "a") { name } x: labels(accountId: "a") { name } }"#)
  }

  @Test("validates enum and input object fields")
  func inputObjectValidation() throws {
    try expectCode("ARGUMENT_TYPE", #"{ threads(input: {accountId: "a", direction: SIDEWAYS}) { totalCount } }"#)
    try expectCode("ARGUMENT_TYPE", #"{ threads(input: {accountId: "a", unknown: "x"}) { totalCount } }"#)
    try expectCode("ARGUMENT_TYPE", #"{ threads(input: {query: "x"}) { totalCount } }"#)
  }

  private func expectCode(_ expected: String, _ source: String, variables: [String: GatewayJSONValue] = [:]) throws {
    let document = try GatewayGraphQLParser.parse(source)
    do {
      _ = try validator.validate(document, variables: variables)
      Issue.record("expected \(expected)")
    } catch let error as GatewaySDKError {
      guard case .validation(let actual, _, _) = error else { Issue.record("expected validation error"); return }
      #expect(actual == expected)
    }
  }
}
