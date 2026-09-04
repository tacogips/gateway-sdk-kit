import Foundation
import Testing
@testable import GatewaySDKKit

@Suite("GraphQL lexer")
struct GraphQLLexerTests {
  private struct SyntaxCase {
    let source: String
    let message: String
    let line: Int
    let column: Int
  }

  @Test("token kinds and texts on a small document")
  func kindsAndTexts() throws {
    let source = "# lead\nquery Q($a: [Int!]! = 3, $b: Float = -1.5e+2) {\n  f(a: $a, s: \"x\\ny\") { ...F }\n}"
    let tokens = try GraphQLLexer.tokenize(source)
    #expect(tokens.map(\.kind) == [
      .comment, .name, .name, .punctuator, .variable, .punctuator, .punctuator, .name,
      .punctuator, .punctuator, .punctuator, .punctuator, .int, .variable, .punctuator,
      .name, .punctuator, .float, .punctuator, .punctuator, .name, .punctuator, .name,
      .punctuator, .variable, .name, .punctuator, .string, .punctuator, .punctuator,
      .punctuator, .name, .punctuator, .punctuator
    ])
    #expect(tokens[0].text == "# lead")
    #expect(tokens[4].text == "$a")
    #expect(tokens[12].text == "3")
    #expect(tokens[17].text == "-1.5e+2")
    #expect(tokens[27].text == #""x\ny""#)
    #expect(tokens[30].text == "...")
  }

  @Test("every token range points back at its exact source slice")
  func ranges() throws {
    let source = "query Q($a: Int = 1) { f(a: $a) } # tail"
    for token in try GraphQLLexer.tokenize(source) {
      #expect(String(source[token.range]) == token.text)
    }
  }

  @Test("commas, whitespace and a BOM are skipped")
  func skippedCharacters() throws {
    let tokens = try GraphQLLexer.tokenize("\u{FEFF}{ a,\n\t b , c }")
    #expect(tokens.map(\.text) == ["{", "a", "b", "c", "}"])
  }

  @Test("comments run to end of line and are kept as tokens")
  func comments() throws {
    let tokens = try GraphQLLexer.tokenize("{ # not $a code\n  b }")
    #expect(tokens.map(\.kind) == [.punctuator, .comment, .name, .punctuator])
    #expect(tokens[1].text == "# not $a code")
  }

  @Test("strings keep their escapes verbatim in the token text")
  func strings() throws {
    let tokens = try GraphQLLexer.tokenize(#"{ f(a: "q\"uote", b: "back\\slash", c: "é") }"#)
    let strings = tokens.filter { $0.kind == .string }.map(\.text)
    #expect(strings == [#""q\"uote""#, #""back\\slash""#, #""é""#])
  }

  @Test("block strings support the escaped triple quote")
  func blockStrings() throws {
    let source = "{ f(a: \"\"\"line one\n\\\"\"\" still inside\nend\"\"\") }"
    let tokens = try GraphQLLexer.tokenize(source)
    let block = try #require(tokens.first { $0.kind == .blockString })
    #expect(block.text == "\"\"\"line one\n\\\"\"\" still inside\nend\"\"\"")
    #expect(String(source[block.range]) == block.text)
  }

  @Test("ints and floats are distinguished by the grammar")
  func numbers() throws {
    let tokens = try GraphQLLexer.tokenize("{ f(a: 1, b: -2, c: 1.5, d: 1e3, e: -1.5E-2) }")
    let numeric = tokens.filter { $0.kind == .int || $0.kind == .float }
    #expect(numeric.map(\.kind) == [.int, .int, .float, .float, .float])
    #expect(numeric.map(\.text) == ["1", "-2", "1.5", "1e3", "-1.5E-2"])
  }

  @Test("a variable is one token including the dollar sign")
  func variables() throws {
    let tokens = try GraphQLLexer.tokenize("{ f(a: $someVar_1) }")
    let variable = try #require(tokens.first { $0.kind == .variable })
    #expect(variable.text == "$someVar_1")
    #expect(variable.variableName == "someVar_1")
    #expect(tokens[1].variableName == nil)
  }

  @Test("lexer failures report exact syntax messages and source positions")
  func lexerFailures() {
    let cases = [
      SyntaxCase(source: "{ f(a: \"unterminated) }", message: "unterminated string", line: 1, column: 8),
      SyntaxCase(source: "{ f(a: \"\"\"unterminated) }", message: "unterminated block string", line: 1, column: 8),
      SyntaxCase(source: "{ f(a: %) }", message: "unexpected character '%'", line: 1, column: 8),
      SyntaxCase(source: "{ f(a: $) }", message: "expected a variable name", line: 1, column: 8),
      SyntaxCase(source: "{ f(a: 1.) }", message: "expected digits after '.'", line: 1, column: 10),
      SyntaxCase(source: "{ f(a: 1e) }", message: "expected exponent digits", line: 1, column: 10),
      SyntaxCase(source: "{ f(a: -) }", message: "expected digits", line: 1, column: 8),
      SyntaxCase(source: "{ f(a: 01) }", message: "leading zeroes are not allowed", line: 1, column: 8),
      SyntaxCase(source: "{ f(a: -01) }", message: "leading zeroes are not allowed", line: 1, column: 8)
    ]
    for item in cases { expectSyntax(item) }
  }

  @Test("an empty document yields no tokens")
  func empty() throws {
    #expect(try GraphQLLexer.tokenize("").isEmpty)
    #expect(try GraphQLLexer.tokenize("   \n\t ").isEmpty)
  }

  private func expectSyntax(_ item: SyntaxCase) {
    do {
      _ = try GraphQLLexer.tokenize(item.source)
      Issue.record("expected syntax failure")
    } catch let error as GatewaySDKError {
      guard case .syntax(let message, let line, let column) = error else {
        Issue.record("expected syntax error")
        return
      }
      #expect(message == item.message)
      #expect(line == item.line)
      #expect(column == item.column)
    } catch {
      Issue.record("unexpected error \(error)")
    }
  }
}
