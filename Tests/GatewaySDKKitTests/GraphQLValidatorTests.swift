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

  @Test("budgets direct type wrappers and only request materialized defaults")
  func resourcePreflight() throws {
    var deepType: GatewayTypeRef = .named("ID")
    for _ in 0...GatewayGraphQLLimits.depth { deepType = .list(deepType) }
    let deep = GatewayGraphQLDocument(
      operationType: .query,
      variableDefinitions: [.init(name: "unused", type: deepType)],
      selectionSet: [.init(name: "labels", arguments: [.init(name: "accountId", value: .string("a"))], selectionSet: [.init(name: "name")])]
    )
    do {
      _ = try validator.validate(deep)
      Issue.record("expected RESOURCE_LIMIT")
    } catch let error as GatewaySDKError {
      guard case .validation(let code, _, let path) = error else { Issue.record("expected validation error"); return }
      #expect(code == "RESOURCE_LIMIT")
      #expect(path == [])
    }
    var catalog = FixtureCatalogs.runtime
    let defaultValue = GatewayJSONValue.array(Array(repeating: .int(1), count: GatewayGraphQLLimits.containerEntries + 1))
    let unused = GatewayOperation(name: "unused", kind: .query, tier: "reader", arguments: [
      .init(name: "payload", type: .list(.named("Int")), defaultValue: defaultValue)
    ], result: .named("Label"))
    catalog.operations.append(unused)
    let document = try GatewayGraphQLParser.parse(#"{ labels(accountId: "a") { name } }"#)
    #expect(try GatewayGraphQLValidator(catalog: catalog).validate(document).rootFields.count == 1)
  }

  @Test("counts supplied input once while charging only materialized defaults")
  func inputBudgetDoesNotRescanSuppliedValues() throws {
    var catalog = FixtureCatalogs.runtime
    catalog.operations.append(.init(
      name: "inspect",
      kind: .query,
      tier: "reader",
      arguments: [.init(name: "payload", type: .named("JSON"))],
      result: .named("Label")
    ))
    let document = try GatewayGraphQLParser.parse("query($payload: JSON) { inspect(payload: $payload) { name } }")
    var rows = Array(repeating: GatewayJSONValue.array(Array(repeating: .int(1), count: 9)), count: 998)
    rows.append(contentsOf: Array(repeating: .array(Array(repeating: .int(1), count: 8)), count: 2))
    let validated = try GatewayGraphQLValidator(catalog: catalog).validate(
      document,
      variables: ["payload": .array(rows)]
    )
    #expect(validated.rootFields.count == 1)
  }

  @Test("rejects direct-AST duplicates and input container overflow")
  func directAstDefenses() throws {
    let selection = GatewayGraphQLDocument.Selection(
      name: "labels", arguments: [.init(name: "accountId", value: .string("a"))], selectionSet: [.init(name: "name")]
    )
    let duplicateVariable = GatewayGraphQLDocument(
      operationType: .query,
      variableDefinitions: [.init(name: "v", type: .named("ID")), .init(name: "v", type: .named("ID"))],
      selectionSet: [selection]
    )
    try expectDirectCode("DUPLICATE_VARIABLE", duplicateVariable, path: [])
    let duplicateArgument = GatewayGraphQLDocument(operationType: .query, selectionSet: [
      .init(name: "labels", arguments: [.init(name: "accountId", value: .string("a")), .init(name: "accountId", value: .string("b"))], selectionSet: [.init(name: "name")])
    ])
    try expectDirectCode("DUPLICATE_ARGUMENT", duplicateArgument, path: ["labels"])
    for count in [GatewayGraphQLLimits.containerEntries - 1, GatewayGraphQLLimits.containerEntries, GatewayGraphQLLimits.containerEntries + 1] {
      let argument = GatewayGraphQLDocument.Argument(name: "accountId", value: .list(Array(repeating: .string("a"), count: count)))
      let document = GatewayGraphQLDocument(operationType: .query, selectionSet: [
        .init(name: "labels", arguments: [argument], selectionSet: [.init(name: "name")])
      ])
      do {
        _ = try validator.validate(document)
        Issue.record("expected argument or resource result")
      } catch let error as GatewaySDKError {
        guard case .validation(let code, _, let path) = error else { Issue.record("expected validation error"); continue }
        if count > GatewayGraphQLLimits.containerEntries {
          #expect(code == "RESOURCE_LIMIT")
          #expect(path == ["labels"])
        } else {
          #expect(code == "ARGUMENT_TYPE")
        }
      }
    }
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

  private func expectDirectCode(_ expected: String, _ document: GatewayGraphQLDocument, path: [String]) throws {
    do {
      _ = try validator.validate(document)
      Issue.record("expected \(expected)")
    } catch let error as GatewaySDKError {
      guard case .validation(let code, _, let actualPath) = error else { Issue.record("expected validation error"); return }
      #expect(code == expected)
      #expect(actualPath == path)
    }
  }
}
