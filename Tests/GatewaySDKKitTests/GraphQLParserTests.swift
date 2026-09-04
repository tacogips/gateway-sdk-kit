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
      } catch let error as GatewaySDKError {
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

  @Test("accepts every supported operation and literal form")
  func acceptsGrammarMatrix() throws {
    let sources = [
      "{ f }",
      "query Named { f }",
      "mutation Named { f }",
      "query($x: Int = -1, $y: Float = 1.25e2, $z: String = \"x\", $b: Boolean = true, $n: ID = null, $e: Direction = INBOUND, $l: [Int] = [1, 2], $o: Input = {key: 1}) { a: f(value: $x) { b { c { d } } } }",
      "\u{FEFF}query { # comment\n f(a: 1, b: -2.5E-1, c: \"\\u0041\", d: \"\"\"\\n  line\\n    indented\\n\"\"\") }"
    ]
    for source in sources { _ = try GatewayGraphQLParser.parse(source) }
  }

  @Test("rejects every unsupported construct at its precise source location")
  func rejectsUnsupportedConstructMatrix() {
    let cases = [
      PositionCase(source: "\nfragment Part on T { f }", line: 2, column: 1),
      PositionCase(source: "\n{ ...Part }", line: 2, column: 3),
      PositionCase(source: "\n{ ... on T { f } }", line: 2, column: 3),
      PositionCase(source: "\nquery @skip(if: true) { f }", line: 2, column: 7),
      PositionCase(source: "\n{ f @skip(if: true) }", line: 2, column: 5),
      PositionCase(source: "\nsubscription { f }", line: 2, column: 1),
      PositionCase(source: "\n{ f }\nquery { g }", line: 3, column: 1),
      PositionCase(source: "\n{ __schema }", line: 2, column: 3),
      PositionCase(source: "\n{ a { __schema } }", line: 2, column: 7),
      PositionCase(source: "\n{ __type }", line: 2, column: 3),
      PositionCase(source: "\n{ a { __type } }", line: 2, column: 7),
      PositionCase(source: "\n{ __typename }", line: 2, column: 3),
      PositionCase(source: "\n{ a { __typename } }", line: 2, column: 7),
      PositionCase(source: "\n{}", line: 2, column: 1),
      PositionCase(source: "\n{ f( }", line: 2, column: 6),
      PositionCase(source: "\n{ f", line: 2, column: 1),
      PositionCase(source: "\n{ f } trailing", line: 2, column: 7),
      PositionCase(source: "\nquery Q() { f }", line: 2, column: 9),
      PositionCase(source: "\nquery($x: Int = $y) { f }", line: 2, column: 17),
      PositionCase(source: "\n{ f(a: 9223372036854775808) }", line: 2, column: 8),
      PositionCase(source: "\n{ f(a: \"\\q\") }", line: 2, column: 8),
      PositionCase(source: "\n{ f(a: {x: 1, x: 2}) }", line: 2, column: 15)
    ]
    for item in cases { expectSyntax(item.source, line: item.line, column: item.column) }
  }

  @Test("reports exact lexer-originated syntax locations")
  func reportsLexerFailures() {
    let cases = [
      PositionCase(source: "\n{ f(a: ?) }", line: 2, column: 8),
      PositionCase(source: "\nquery($) { f }", line: 2, column: 7),
      PositionCase(source: "\n{ f(a: 1.) }", line: 2, column: 10),
      PositionCase(source: "\n{ f(a: 1e) }", line: 2, column: 10),
      PositionCase(source: "\n{ f(a: \"unterminated) }", line: 2, column: 8),
      PositionCase(source: "\n{ f(a: \"\"\"unterminated) }", line: 2, column: 8)
    ]
    for item in cases { expectSyntax(item.source, line: item.line, column: item.column) }
  }

  @Test("accepts resource maxima and rejects the first over-limit token")
  func parserResourceBoundaryMatrix() throws {
    for depth in [31, 32] { _ = try GatewayGraphQLParser.parse(nestedDocument(depth: depth)) }
    expectSyntax(nestedDocument(depth: 33), line: 1, column: 129)

    for count in [999, 1_000] { _ = try GatewayGraphQLParser.parse(selectionDocument(count: count)) }
    #expect(throws: GatewaySDKError.self) { _ = try GatewayGraphQLParser.parse(selectionDocument(count: 1_001)) }

    for count in [63, 64] { _ = try GatewayGraphQLParser.parse(rootDocument(count: count)) }
    #expect(throws: GatewaySDKError.self) { _ = try GatewayGraphQLParser.parse(rootDocument(count: 65)) }

    for count in [999, 1_000] {
      _ = try GatewayGraphQLParser.parse(listDocument(count: count))
      _ = try GatewayGraphQLParser.parse(objectDocument(count: count))
    }
    #expect(throws: GatewaySDKError.self) { _ = try GatewayGraphQLParser.parse(listDocument(count: 1_001)) }
    #expect(throws: GatewaySDKError.self) { _ = try GatewayGraphQLParser.parse(objectDocument(count: 1_001)) }

    for nodes in [9_999, 10_000] { _ = try GatewayGraphQLParser.parse(nodeDocument(nodes: nodes)) }
    #expect(throws: GatewaySDKError.self) { _ = try GatewayGraphQLParser.parse(nodeDocument(nodes: 10_001)) }
  }

  private func expectSyntax(_ source: String, line: Int, column: Int) {
    do {
      _ = try GatewayGraphQLParser.parse(source)
      Issue.record("expected syntax failure")
    } catch let error as GatewaySDKError {
      guard case .syntax(_, let actualLine, let actualColumn) = error else {
        Issue.record("expected syntax error")
        return
      }
      #expect(actualLine == line)
      #expect(actualColumn == column)
    } catch {
      Issue.record("unexpected error \(error)")
    }
  }

  private func nestedDocument(depth: Int) -> String {
    "{ " + String(repeating: "f { ", count: depth - 1) + "f" + String(repeating: " }", count: depth - 1) + " }"
  }

  private func selectionDocument(count: Int) -> String {
    "{ f { " + String(repeating: "x ", count: count - 1) + "} }"
  }

  private func rootDocument(count: Int) -> String { "{ " + String(repeating: "f ", count: count) + "}" }

  private func listDocument(count: Int) -> String {
    "{ f(a: [" + String(repeating: "1 ", count: count) + "]) }"
  }

  private func objectDocument(count: Int) -> String {
    let values = (0..<count).map { "k\($0): 1" }.joined(separator: " ")
    return "{ f(a: {\(values)}) }"
  }

  private func nodeDocument(nodes: Int) -> String {
    var remaining = nodes
    var arguments: [String] = []
    var index = 0
    while remaining > 0 {
      let values = min(999, remaining - 1)
      if values <= 0 { arguments.append("a\(index): 1"); break }
      arguments.append("a\(index): [" + String(repeating: "1 ", count: values) + "]")
      remaining -= values + 1
      index += 1
    }
    return "{ f(\(arguments.joined(separator: " "))) }"
  }
}
