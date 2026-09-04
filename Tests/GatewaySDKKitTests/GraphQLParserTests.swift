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

  @Test("decodes escapes, surrogate pairs, comments, and block strings")
  func decodesStrings() throws {
    let document = try GatewayGraphQLParser.parse("""
      # a comment
      query { threads(input: {accountId: \"a\\uD83D\\uDE00\", query: \"\"\"
        first line
          second line
        \"\"\"}) { totalCount } }
      """)
    guard case .object(let input) = document.selectionSet[0].arguments[0].value,
      case .string(let identifier)? = input.first(where: { $0.name == "accountId" })?.value,
      case .string(let query)? = input.first(where: { $0.name == "query" })?.value else {
      Issue.record("expected decoded object literal")
      return
    }
    #expect(identifier == "a😀")
    #expect(query.contains("first line"))
  }

  @Test("rejects unsupported operations with positions")
  func rejectsUnsupportedOperations() {
    let sources = [
      "subscription S { labels(accountId: \"a\") { name } }", "query { labels @skip(if: true) { name } }",
      "query { ...Part }", "query { labels(accountId: \"a\") { name } } fragment Part on Label { name }"
    ]
    for source in sources {
      do {
        _ = try GatewayGraphQLParser.parse(source)
        Issue.record("expected syntax failure for \(source)")
      } catch let error as GatewaySDKError {
        guard case .syntax(_, let line, let column) = error else { Issue.record("expected syntax error"); continue }
        #expect(line >= 1)
        #expect(column >= 1)
      } catch { Issue.record("unexpected error \(error)") }
    }
  }

  @Test("rejects malformed unicode surrogates")
  func rejectsMalformedSurrogates() {
    for source in [#"{ labels(accountId: "\uD83D") { name } }"#, #"{ labels(accountId: "\uDE00") { name } }"#] {
      #expect(throws: GatewaySDKError.self) { _ = try GatewayGraphQLParser.parse(source) }
    }
  }
}
