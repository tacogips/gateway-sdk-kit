import Testing
@testable import GatewaySDKKit

@Suite("GraphQL parser")
struct GraphQLParserTests {
  private struct SyntaxCase { let source: String; let message: String; let line: Int; let column: Int }
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
    expectSyntax("{ __typename }", message: "introspection is not supported", line: 1, column: 3)
    expectSyntax("{ alias: __typename }", message: "introspection is not supported", line: 1, column: 10)
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

  @Test("decodes every named escape and block-string indentation exactly")
  func decodesEscapeAndBlockStringMatrix() throws {
    let document = try GatewayGraphQLParser.parse(#"""
      { f(quoted: "\"\\\/\b\f\n\r\t\u0041", block: """
        first
          second
        third
      """) }
      """#)
    let arguments = document.selectionSet[0].arguments
    guard case .string(let quoted)? = arguments.first(where: { $0.name == "quoted" })?.value,
      case .string(let block)? = arguments.first(where: { $0.name == "block" })?.value else {
      Issue.record("expected decoded string arguments")
      return
    }
    #expect(quoted == "\"\\/\u{08}\u{0C}\n\r\tA")
    #expect(block == "first\n  second\nthird")

    let firstLine = try GatewayGraphQLParser.parse("{ f(block: \"\"\"  first\n    second\n  third\n \n\t\n\"\"\") }")
    guard case .string(let preserved)? = firstLine.selectionSet[0].arguments.first?.value else {
      Issue.record("expected block string")
      return
    }
    #expect(preserved == "  first\n  second\nthird")

    for lineTerminator in ["\r\n", "\r"] {
      let source = "{ f(block: \"\"\"  first\(lineTerminator)    second\(lineTerminator)  third\(lineTerminator)\(lineTerminator)\"\"\") }"
      let normalized = try GatewayGraphQLParser.parse(source)
      guard case .string(let value)? = normalized.selectionSet[0].arguments.first?.value else {
        Issue.record("expected normalized block string")
        continue
      }
      #expect(value == "  first\n  second\nthird")
    }
  }

  @Test("rejects unsupported operations with positions")
  func rejectsUnsupportedOperations() {
    let cases = [
      SyntaxCase(source: "subscription S { labels(accountId: \"a\") { name } }", message: "subscriptions are not supported", line: 1, column: 1),
      SyntaxCase(source: "query { labels @skip(if: true) { name } }", message: "directives are not supported", line: 1, column: 16),
      SyntaxCase(source: "query { ...Part }", message: "fragments are not supported", line: 1, column: 9),
      SyntaxCase(source: "query { labels(accountId: \"a\") { name } } fragment Part on Label { name }", message: "fragments are not supported", line: 1, column: 43)
    ]
    for item in cases { expectSyntax(item.source, message: item.message, line: item.line, column: item.column) }
  }

  @Test("rejects malformed unicode surrogates")
  func rejectsMalformedSurrogates() {
    for source in [#"{ labels(accountId: "\uD83D") { name } }"#, #"{ labels(accountId: "\uDE00") { name } }"#] {
      expectSyntax(source, message: "invalid string escape", line: 1, column: 21)
    }
  }

  @Test("reports exact positions for representative parser failures")
  func reportsExactPositions() {
    let cases = [
      SyntaxCase(source: "query {\n  __schema\n}", message: "introspection is not supported", line: 2, column: 3),
      SyntaxCase(source: "query { a }\nquery { b }", message: "multiple operations are not supported", line: 2, column: 1),
      SyntaxCase(source: "query Q($a: Int, $a: Int) { a }", message: "duplicate variable declaration 'a'", line: 1, column: 18),
      SyntaxCase(source: "query { a(x: 1, x: 2) }", message: "duplicate argument 'x'", line: 1, column: 17),
      SyntaxCase(source: "\n{ f { g(a: 1, a: 2) } }", message: "duplicate argument 'a'", line: 2, column: 15)
    ]
    for item in cases { expectSyntax(item.source, message: item.message, line: item.line, column: item.column) }
  }

  @Test("enforces byte and token boundaries")
  func enforcesTextBoundaries() throws {
    for bytes in [GatewayGraphQLLimits.documentBytes - 1, GatewayGraphQLLimits.documentBytes] {
      let source = "{ a }#" + String(repeating: "x", count: bytes - 6)
      _ = try GatewayGraphQLParser.parse(source)
    }
    let oversized = "{ a }#" + String(repeating: "x", count: GatewayGraphQLLimits.documentBytes - 5)
    expectSyntax(
      oversized,
      message: GatewayGraphQLLimits.message("documentBytes", GatewayGraphQLLimits.documentBytes),
      line: 1,
      column: 1
    )
    for total in [GatewayGraphQLLimits.tokens - 1, GatewayGraphQLLimits.tokens] {
      let source = "{ a }\n" + String(repeating: "#x\n", count: total - 3)
      _ = try GatewayGraphQLParser.parse(source)
    }
    let overTokens = "{ a }\n" + String(repeating: "#x\n", count: GatewayGraphQLLimits.tokens - 2)
    expectSyntax(
      overTokens,
      message: GatewayGraphQLLimits.message("tokens", GatewayGraphQLLimits.tokens),
      line: 19_999,
      column: 1
    )
  }

  @Test("accepts every supported operation and literal form")
  func acceptsGrammarMatrix() throws {
    let sources = [
      "{ f }",
      "{ fragment }",
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
      SyntaxCase(source: "\nfragment Part on T { f }", message: "fragments are not supported", line: 2, column: 1),
      SyntaxCase(source: "\n{ ...Part }", message: "fragments are not supported", line: 2, column: 3),
      SyntaxCase(source: "\n{ ... on T { f } }", message: "fragments are not supported", line: 2, column: 3),
      SyntaxCase(source: "\nquery @skip(if: true) { f }", message: "directives are not supported", line: 2, column: 7),
      SyntaxCase(source: "\n{ f @skip(if: true) }", message: "directives are not supported", line: 2, column: 5),
      SyntaxCase(source: "\nsubscription { f }", message: "subscriptions are not supported", line: 2, column: 1),
      SyntaxCase(source: "\n{ f }\nquery { g }", message: "multiple operations are not supported", line: 3, column: 1),
      SyntaxCase(source: "\n{ __schema }", message: "introspection is not supported", line: 2, column: 3),
      SyntaxCase(source: "\n{ a { __schema } }", message: "introspection is not supported", line: 2, column: 7),
      SyntaxCase(source: "\n{ __type }", message: "introspection is not supported", line: 2, column: 3),
      SyntaxCase(source: "\n{ a { __type } }", message: "introspection is not supported", line: 2, column: 7),
      SyntaxCase(source: "\n{ __typename }", message: "introspection is not supported", line: 2, column: 3),
      SyntaxCase(source: "\n{ a { __typename } }", message: "introspection is not supported", line: 2, column: 7),
      SyntaxCase(source: "\n{}", message: "empty selection set", line: 2, column: 1),
      SyntaxCase(source: "\n{ f( }", message: "unexpected token '}'", line: 2, column: 6),
      SyntaxCase(source: "\n{ f", message: "unterminated selection set", line: 2, column: 1),
      SyntaxCase(source: "\n{ f } trailing", message: "trailing tokens after operation", line: 2, column: 7),
      SyntaxCase(source: "\nquery Q() { f }", message: "empty variable definitions", line: 2, column: 9),
      SyntaxCase(source: "\nquery($x: Int = $y) { f }", message: "variables are not allowed in defaults", line: 2, column: 17),
      SyntaxCase(source: "\n{ f(a: 9223372036854775808) }", message: "integer literal overflow", line: 2, column: 8),
      SyntaxCase(source: "\n{ f(a: \"\\q\") }", message: "invalid string escape", line: 2, column: 8),
      SyntaxCase(source: "\n{ f(a: {x: 1, x: 2}) }", message: "duplicate object key 'x'", line: 2, column: 15)
    ]
    for item in cases { expectSyntax(item.source, message: item.message, line: item.line, column: item.column) }
  }

  @Test("reports exact lexer-originated syntax locations")
  func reportsLexerFailures() {
    let cases = [
      SyntaxCase(source: "\n{ f(a: ?) }", message: "unexpected character '?'", line: 2, column: 8),
      SyntaxCase(source: "\nquery($) { f }", message: "expected a variable name", line: 2, column: 7),
      SyntaxCase(source: "\nquery($1: Int) { f }", message: "expected a variable name", line: 2, column: 7),
      SyntaxCase(source: "\n{ f(a: 1.) }", message: "expected digits after '.'", line: 2, column: 10),
      SyntaxCase(source: "\n{ f(a: 1e) }", message: "expected exponent digits", line: 2, column: 10),
      SyntaxCase(source: "\n{ f(a: 01) }", message: "leading zeroes are not allowed", line: 2, column: 8),
      SyntaxCase(source: "\n{ f(a: -01) }", message: "leading zeroes are not allowed", line: 2, column: 8),
      SyntaxCase(source: "\n{ f(a: 1true) }", message: "invalid number/name boundary", line: 2, column: 9),
      SyntaxCase(source: "\n{ f(a: -1true) }", message: "invalid number/name boundary", line: 2, column: 10),
      SyntaxCase(source: "\n{ f(a: [1true]) }", message: "invalid number/name boundary", line: 2, column: 10),
      SyntaxCase(source: "\n{ f(a: \"unterminated) }", message: "unterminated string", line: 2, column: 8),
      SyntaxCase(source: "\n{ f(a: \"\"\"unterminated) }", message: "unterminated block string", line: 2, column: 8)
    ]
    for item in cases { expectSyntax(item.source, message: item.message, line: item.line, column: item.column) }
  }

  @Test("accepts CRLF documents and aliases that begin with double underscores")
  func crlfAndDoubleUnderscoreAlias() throws {
    let document = try GatewayGraphQLParser.parse("# comment\r\n{ __result: fragment }\r\n")
    #expect(document.selectionSet == [.init(alias: "__result", name: "fragment")])
  }

  @Test("reports raw string controls at their CRLF source position")
  func rawControlPosition() {
    expectSyntax(
      "{\r\n  f(a: \"x\ty\")\r\n}",
      message: "raw control character in string",
      line: 2,
      column: 10
    )
    expectSyntax(
      "{\r\n  f(a: \"x" + "\\" + "\t" + "y\")\r\n}",
      message: "raw control character in string",
      line: 2,
      column: 11
    )
  }

  @Test("accepts resource maxima and rejects the first over-limit token")
  func parserResourceBoundaryMatrix() throws {
    for depth in [31, 32] { _ = try GatewayGraphQLParser.parse(nestedDocument(depth: depth)) }
    expectSyntax(nestedDocument(depth: 33), message: GatewayGraphQLLimits.message("depth", GatewayGraphQLLimits.depth), line: 1, column: 129)

    for wrappers in [30, 31] { _ = try GatewayGraphQLParser.parse(literalDepthDocument(wrappers: wrappers)) }
    let overLiteralDepth = literalDepthDocument(wrappers: 32, leaf: "OVERFLOW")
    expectSyntax(
      overLiteralDepth,
      message: GatewayGraphQLLimits.message("depth", GatewayGraphQLLimits.depth),
      line: 1,
      column: column(of: "OVERFLOW", in: overLiteralDepth)
    )

    for count in [999, 1_000] { _ = try GatewayGraphQLParser.parse(selectionDocument(count: count)) }
    let overSelections = selectionDocument(count: 1_001)
    expectSyntax(overSelections, message: GatewayGraphQLLimits.message("selections", GatewayGraphQLLimits.selections), line: 1, column: column(of: "OVERFLOW", in: overSelections))

    for count in [63, 64] { _ = try GatewayGraphQLParser.parse(rootDocument(count: count)) }
    let overRoots = rootDocument(count: 65)
    expectSyntax(overRoots, message: GatewayGraphQLLimits.message("rootFields", GatewayGraphQLLimits.rootFields), line: 1, column: column(of: "OVERFLOW", in: overRoots))

    for count in [999, 1_000] {
      _ = try GatewayGraphQLParser.parse(listDocument(count: count))
      _ = try GatewayGraphQLParser.parse(objectDocument(count: count))
    }
    let overList = listDocument(count: 1_001)
    expectSyntax(overList, message: GatewayGraphQLLimits.message("containerEntries", GatewayGraphQLLimits.containerEntries), line: 1, column: column(of: "OVERFLOW", in: overList))
    let overObject = objectDocument(count: 1_001)
    expectSyntax(overObject, message: GatewayGraphQLLimits.message("containerEntries", GatewayGraphQLLimits.containerEntries), line: 1, column: column(of: "OVERFLOW", in: overObject))

    for nodes in [9_999, 10_000] { _ = try GatewayGraphQLParser.parse(nodeDocument(nodes: nodes)) }
    let overNodes = nodeDocument(nodes: 10_001)
    expectSyntax(overNodes, message: GatewayGraphQLLimits.message("inputValueNodes", GatewayGraphQLLimits.inputValueNodes), line: 1, column: column(of: "OVERFLOW", in: overNodes))
  }

  private func expectSyntax(_ source: String, message: String, line: Int, column: Int) {
    do {
      _ = try GatewayGraphQLParser.parse(source)
      Issue.record("expected syntax failure")
    } catch let error as GatewaySDKError {
      guard case .syntax(let actualMessage, let actualLine, let actualColumn) = error else {
        Issue.record("expected syntax error")
        return
      }
      #expect(actualMessage == message)
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
    let names = (0..<count - 1).map { index in count > GatewayGraphQLLimits.selections && index == count - 2 ? "OVERFLOW" : "x" }
    return "{ f { " + names.joined(separator: " ") + "} }"
  }

  private func rootDocument(count: Int) -> String {
    let fields = (0..<count).map { index in count > GatewayGraphQLLimits.rootFields && index == count - 1 ? "OVERFLOW: f" : "f" }
    return "{ " + fields.joined(separator: " ") + " }"
  }

  private func listDocument(count: Int) -> String {
    let values = (0..<count).map { index in count > GatewayGraphQLLimits.containerEntries && index == count - 1 ? "OVERFLOW" : "1" }
    return "{ f(a: [" + values.joined(separator: " ") + "]) }"
  }

  private func literalDepthDocument(wrappers: Int, leaf: String = "1") -> String {
    "{ f(a: " + String(repeating: "[", count: wrappers) + leaf + String(repeating: "]", count: wrappers) + ") }"
  }

  private func objectDocument(count: Int) -> String {
    let values = (0..<count).map { index in
      let key = count > GatewayGraphQLLimits.containerEntries && index == count - 1 ? "OVERFLOW" : "k\(index)"
      return "\(key): 1"
    }.joined(separator: " ")
    return "{ f(a: {\(values)}) }"
  }

  private func nodeDocument(nodes: Int) -> String {
    var remaining = nodes
    var arguments: [String] = []
    var index = 0
    while remaining > 0 {
      let values = min(999, remaining - 1)
      if values <= 0 {
        arguments.append("a\(index): \(nodes > GatewayGraphQLLimits.inputValueNodes ? "OVERFLOW" : "1")")
        break
      }
      arguments.append("a\(index): [" + String(repeating: "1 ", count: values) + "]")
      remaining -= values + 1
      index += 1
    }
    return "{ f(\(arguments.joined(separator: " "))) }"
  }

  private func column(of marker: String, in source: String) -> Int {
    guard let range = source.range(of: marker) else { Issue.record("missing marker \(marker)"); return 0 }
    return source.distance(from: source.startIndex, to: range.lowerBound) + 1
  }
}
