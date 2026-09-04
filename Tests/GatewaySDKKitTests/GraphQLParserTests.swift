import Testing
@testable import GatewaySDKKit

@Suite("GraphQL parser")
struct GraphQLParserTests {
  private struct PositionCase { let source: String; let line: Int; let column: Int }
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

  @Test("reports exact positions for representative parser failures")
  func reportsExactPositions() {
    let cases = [
      PositionCase(source: "query {\n  __schema\n}", line: 2, column: 3),
      PositionCase(source: "query { a }\nquery { b }", line: 2, column: 1),
      PositionCase(source: "query Q($a: Int, $a: Int) { a }", line: 1, column: 18),
      PositionCase(source: "query { a(x: 1, x: 2) }", line: 1, column: 17)
    ]
    for item in cases {
      do {
        _ = try GatewayGraphQLParser.parse(item.source)
        Issue.record("expected syntax failure")
      }
      catch let error as GatewaySDKError {
        guard case .syntax(_, let actualLine, let actualColumn) = error else { Issue.record("expected syntax error"); continue }
        #expect(actualLine == item.line)
        #expect(actualColumn == item.column)
      } catch { Issue.record("unexpected error \(error)") }
    }
  }

  @Test("enforces byte and token boundaries")
  func enforcesTextBoundaries() throws {
    for bytes in [GatewayGraphQLLimits.documentBytes - 1, GatewayGraphQLLimits.documentBytes] {
      let source = "{ a }#" + String(repeating: "x", count: bytes - 6)
      _ = try GatewayGraphQLParser.parse(source)
    }
    let oversized = "{ a }#" + String(repeating: "x", count: GatewayGraphQLLimits.documentBytes - 5)
    #expect(throws: GatewaySDKError.self) { _ = try GatewayGraphQLParser.parse(oversized) }
    for total in [GatewayGraphQLLimits.tokens - 1, GatewayGraphQLLimits.tokens] {
      let source = "{ a }\n" + String(repeating: "#x\n", count: total - 3)
      _ = try GatewayGraphQLParser.parse(source)
    }
    let overTokens = "{ a }\n" + String(repeating: "#x\n", count: GatewayGraphQLLimits.tokens - 2)
    #expect(throws: GatewaySDKError.self) { _ = try GatewayGraphQLParser.parse(overTokens) }
  }
}
