import Testing
@testable import GatewaySDKKit

@Suite("GraphQL parser")
struct GraphQLParserTests {
  @Test("parses variables, literals, aliases and nested selections")
  func parsesDocument() throws {
    let document = try GatewayGraphQLParser.parse(#"query Q($id: ID!, $limit: Int = 2) { t: threads(input: {accountId: $id, limit: $limit}) { edges { node { id } } } }"#)
    #expect(document.operationType == .query)
    #expect(document.name == "Q")
    #expect(document.variableDefinitions.count == 2)
    #expect(document.selectionSet[0].responseKey == "t")
  }

  @Test("rejects introspection with a positioned syntax error")
  func rejectsIntrospection() {
    #expect(throws: GatewaySDKError.self) { _ = try GatewayGraphQLParser.parse("{ __typename }") }
  }
}
