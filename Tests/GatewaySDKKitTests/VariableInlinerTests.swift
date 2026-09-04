import Foundation
import Testing
@testable import GatewaySDKKit

@Suite("Variable inliner")
struct VariableInlinerTests {
  private let inliner = GraphQLVariableInliner(catalog: FixtureCatalogs.gmail)

  // MARK: - Anonymous documents

  @Test("an anonymous document with no variables passes through byte-identical")
  func anonymousPassthrough() throws {
    let document = "{\n  threads {  # keep   this\n    totalCount\n  }\n}\n"
    #expect(try inliner.inline(document: document, variables: [:]) == document)
  }

  @Test("an anonymous document that uses a variable is rejected")
  func anonymousWithVariable() {
    #expect {
      _ = try inliner.inline(document: "{ threads(first: $n) { totalCount } }", variables: [:])
    } throws: { error in
      error as? GatewaySDKError == .undeclaredVariable(name: "n")
    }
  }

  @Test("supplying variables to an anonymous document is rejected")
  func anonymousWithSuppliedVariables() {
    #expect {
      _ = try inliner.inline(
        document: "{ threads { totalCount } }",
        variables: ["z": .int(1), "a": .int(2)]
      )
    } throws: { error in
      error as? GatewaySDKError == .unknownVariable(operation: "(anonymous)", name: "a")
    }
  }

  // MARK: - Rewrite

  @Test("the definition parenthesis is removed and every use is replaced")
  func basicRewrite() throws {
    let document = "query Threads($accountId: ID!, $first: Int) {\n  threads(accountId: $accountId, first: $first) {\n    totalCount\n  }\n}"
    let result = try inliner.inline(
      document: document,
      variables: ["accountId": .string("acct-1"), "first": .int(20)]
    )
    #expect(
      result == "query Threads {\n  threads(accountId: \"acct-1\", first: 20) {\n    totalCount\n  }\n}"
    )
  }

  @Test("a mutation header and a repeated use are handled")
  func mutationRewrite() throws {
    let document = "mutation M($id: ID!) { a(id: $id) { x } b(id: $id) { y } }"
    let result = try inliner.inline(document: document, variables: ["id": .string("i")])
    #expect(result == "mutation M { a(id: \"i\") { x } b(id: \"i\") { y } }")
  }

  @Test("an anonymous but keyword-led operation keeps its shape")
  func unnamedQuery() throws {
    let result = try inliner.inline(document: "query ($n: Int) { f(n: $n) }", variables: ["n": .int(1)])
    #expect(result == "query  { f(n: 1) }")
  }

  // MARK: - Validation rules

  @Test("a declared but unused variable is rejected")
  func declaredUnused() {
    #expect {
      _ = try inliner.inline(document: "query Q($a: Int) { f }", variables: ["a": .int(1)])
    } throws: { error in
      error as? GatewaySDKError == .unusedVariable(operation: "Q", name: "a")
    }
  }

  @Test("a used but undeclared variable is rejected")
  func usedUndeclared() {
    #expect {
      _ = try inliner.inline(document: "query Q($a: Int) { f(a: $a, b: $b) }", variables: ["a": .int(1)])
    } throws: { error in
      error as? GatewaySDKError == .undeclaredVariable(name: "b")
    }
  }

  @Test("an unknown supplied variable is rejected")
  func unknownSupplied() {
    #expect {
      _ = try inliner.inline(document: "query Q($a: Int) { f(a: $a) }", variables: ["a": .int(1), "z": .int(2)])
    } throws: { error in
      error as? GatewaySDKError == .unknownVariable(operation: "Q", name: "z")
    }
  }

  @Test("a required variable with no value and no default is rejected")
  func missingRequired() {
    #expect {
      _ = try inliner.inline(document: "query Q($a: Int!) { f(a: $a) }", variables: [:])
    } throws: { error in
      error as? GatewaySDKError == .missingRequiredVariable(operation: "Q", name: "a")
    }
    #expect {
      _ = try inliner.inline(document: "query Q($a: Int!) { f(a: $a) }", variables: ["a": .null])
    } throws: { error in
      error as? GatewaySDKError == .missingRequiredVariable(operation: "Q", name: "a")
    }
  }

  @Test("a required variable with a default may be omitted")
  func requiredWithDefault() throws {
    let result = try inliner.inline(document: "query Q($a: Int! = 7) { f(a: $a) }", variables: [:])
    #expect(result == "query Q { f(a: 7) }")
  }

  @Test("supplied values are type-checked against the declared type")
  func typeChecked() {
    #expect {
      _ = try inliner.inline(document: "query Q($a: Int) { f(a: $a) }", variables: ["a": .string("1")])
    } throws: { error in
      error as? GatewaySDKError == .variableTypeMismatch(name: "a", expected: "Int", actual: "string")
    }
    #expect {
      _ = try inliner.inline(
        document: "query Q($d: Direction) { f(d: $d) }",
        variables: ["d": .string("SIDEWAYS")]
      )
    } throws: { error in
      error as? GatewaySDKError == .variableTypeMismatch(name: "d", expected: "Direction", actual: "string")
    }
    #expect {
      _ = try inliner.inline(
        document: "query Q($i: SendMessageInput!) { f(i: $i) }",
        variables: ["i": .object(["nope": .int(1)])]
      )
    } throws: { error in
      error as? GatewaySDKError
        == .variableTypeMismatch(name: "i", expected: "SendMessageInput!", actual: "object")
    }
  }

  @Test("a document that is neither an operation nor an anonymous selection set is rejected")
  func malformedHeaders() {
    for document in ["subscription S($a: Int) { f(a: $a) }", "fragment F on T { x }", "", "   # only a comment"] {
      #expect(throws: GatewaySDKError.self) {
        _ = try inliner.inline(document: document, variables: [:])
      }
    }
  }

  @Test("a duplicate declaration and a non-constant default are rejected")
  func malformedDefinitions() {
    #expect(throws: GatewaySDKError.self) {
      _ = try inliner.inline(document: "query Q($a: Int, $a: Int) { f(a: $a) }", variables: [:])
    }
    #expect(throws: GatewaySDKError.self) {
      _ = try inliner.inline(document: "query Q($a: Int = $b) { f(a: $a) }", variables: [:])
    }
    #expect(throws: GatewaySDKError.self) {
      _ = try inliner.inline(document: "query Q($a Int) { f(a: $a) }", variables: [:])
    }
  }

  // MARK: - Literal rendering

  @Test("strings escape quotes, backslashes, control characters and keep non-ASCII raw")
  func stringLiterals() throws {
    let value = GatewayJSONValue.string("a\"b\\c\nd\te\u{0001}f_\u{3042}_x")
    let result = try inliner.inline(
      document: "query Q($s: String) { f(s: $s) }",
      variables: ["s": value]
    )
    #expect(result == #"query Q { f(s: "a\"b\\c\nd\te\u0001f_あ_x") }"#)
  }

  @Test("enum-typed strings render bare while plain strings stay quoted")
  func enumLiterals() throws {
    #expect(
      try inliner.inline(
        document: "query Q($d: Direction) { f(d: $d) }",
        variables: ["d": .string("INBOUND")]
      ) == "query Q { f(d: INBOUND) }"
    )
    #expect(
      try inliner.inline(
        document: "query Q($s: String) { f(s: $s) }",
        variables: ["s": .string("INBOUND")]
      ) == #"query Q { f(s: "INBOUND") }"#
    )
  }

  @Test("an enum value coerced against a list-of-enum type still renders bare")
  func enumInListLiterals() throws {
    // GatewayVariableTypeCheck accepts a single value against a list type (GraphQL's
    // single-value coercion), so the renderer has to look through the list wrapper too.
    #expect(
      try inliner.inline(
        document: "query Q($d: [Direction!]) { f(d: $d) }",
        variables: ["d": .string("INBOUND")]
      ) == "query Q { f(d: INBOUND) }"
    )
    #expect(
      try inliner.inline(
        document: "query Q($d: [Direction!]!) { f(d: $d) }",
        variables: ["d": .array([.string("INBOUND"), .string("OUTBOUND")])]
      ) == "query Q { f(d: [INBOUND, OUTBOUND]) }"
    )
    // A list of plain strings is unaffected.
    #expect(
      try inliner.inline(
        document: "query Q($s: [String!]) { f(s: $s) }",
        variables: ["s": .string("INBOUND")]
      ) == #"query Q { f(s: "INBOUND") }"#
    )
  }

  @Test("an input object coerced against a list-of-input type keeps its field types")
  func inputObjectInListLiterals() throws {
    #expect(
      try inliner.inline(
        document: "query Q($i: [SendMessageInput!]) { f(i: $i) }",
        variables: ["i": .object(["to": .array([.string("a")]), "direction": .string("INBOUND")])]
      ) == #"query Q { f(i: {direction: INBOUND, to: ["a"]}) }"#
    )
  }

  @Test("a nullable variable with no supplied value and no default inlines to null")
  func unsuppliedNullableInlinesNull() throws {
    // The splice can replace `$a` but cannot delete the surrounding `a: $a` pair, so an
    // omitted variable becomes an explicit null rather than an absent argument. Pinned
    // here because it is a documented semantic difference from GraphQL variables.
    #expect(
      try inliner.inline(document: "query Q($a: Int) { f(a: $a) }", variables: [:])
        == "query Q { f(a: null) }"
    )
  }

  @Test("a non-finite double is rejected before it can render as inf")
  func nonFiniteDoubleRejected() {
    for value in [GatewayJSONValue.double(.infinity), .double(-.infinity), .double(.nan)] {
      #expect(throws: GatewaySDKError.self) {
        _ = try inliner.inline(document: "query Q($f: Float) { f(f: $f) }", variables: ["f": value])
      }
    }
  }

  @Test("a non-finite double nested under a JSON or custom-scalar variable is rejected too")
  func nestedNonFiniteDoubleRejected() throws {
    // JSON and custom scalars accept any shape without descending, so these only fail if
    // the non-finite scan walks the whole value.
    let nested: [GatewayJSONValue] = [
      .object(["x": .double(.infinity)]),
      .array([.double(.nan)]),
      .object(["a": .array([.object(["b": .double(-.infinity)])])])
    ]
    for value in nested {
      for declaration in ["$j: JSON", "$j: DateTime"] {
        #expect(throws: GatewaySDKError.self) {
          _ = try inliner.inline(
            document: "query Q(\(declaration)) { f(j: $j) }",
            variables: ["j": value]
          )
        }
      }
    }
    // An input object whose field is JSON-typed, carrying [inf].
    let holderCatalog = {
      var catalog = FixtureCatalogs.gmail
      catalog.types.append(
        GatewayNamedType(
          name: "JSONHolder",
          kind: .inputObject([GatewayArgument(name: "payload", type: .named("JSON"))])
        )
      )
      return catalog
    }()
    #expect(throws: GatewaySDKError.self) {
      _ = try GraphQLVariableInliner(catalog: holderCatalog).inline(
        document: "query Q($inp: JSONHolder) { f(inp: $inp) }",
        variables: ["inp": .object(["payload": .array([.double(.infinity)])])]
      )
    }
    // The same shapes with finite doubles still inline.
    #expect(
      try GraphQLVariableInliner(catalog: holderCatalog).inline(
        document: "query Q($inp: JSONHolder) { f(inp: $inp) }",
        variables: ["inp": .object(["payload": .array([.double(1.5)])])]
      ) == "query Q { f(inp: {payload: [1.5]}) }"
    )
  }

  @Test("a float default that overflows to infinity is rejected as malformed")
  func overflowingFloatDefaultRejected() throws {
    // Double("1e999") is +inf, and defaults are never type-checked, so this is the one
    // non-finite that validation cannot catch; the parser has to.
    #expect {
      _ = try inliner.inline(document: "query Q($f: Float = 1e999) { f(f: $f) }", variables: [:])
    } throws: { error in
      error as? GatewaySDKError
        == .malformedDocument("float default '1e999' is not a finite number")
    }
    // A finite float default is unaffected.
    #expect(
      try inliner.inline(document: "query Q($f: Float = 1.5e2) { f(f: $f) }", variables: [:])
        == "query Q { f(f: 150.0) }"
    )
  }

  @Test("numbers, booleans and null render as GraphQL literals")
  func scalarLiterals() throws {
    #expect(
      try inliner.inline(
        document: "query Q($i: Int, $f: Float, $b: Boolean, $n: String) { g(i: $i, f: $f, b: $b, n: $n) }",
        variables: ["i": .int(-3), "f": .double(1.5), "b": .bool(false), "n": .null]
      ) == "query Q { g(i: -3, f: 1.5, b: false, n: null) }"
    )
  }

  @Test("lists render with the element type and objects with bare sorted keys")
  func compositeLiterals() throws {
    #expect(
      try inliner.inline(
        document: "query Q($t: [String!]!) { f(t: $t) }",
        variables: ["t": .array([.string("a"), .string("b")])]
      ) == #"query Q { f(t: ["a", "b"]) }"#
    )
    #expect(
      try inliner.inline(
        document: "query Q($i: SendMessageInput!) { f(i: $i) }",
        variables: [
          "i": .object([
            "to": .array([.string("x@example.com")]),
            "direction": .string("OUTBOUND"),
            "subject": .string("hi")
          ])
        ]
        // `direction` resolves to the enum and renders bare; keys are sorted.
      ) == #"query Q { f(i: {direction: OUTBOUND, subject: "hi", to: ["x@example.com"]}) }"#
    )
  }

  @Test("defaults are applied and supplied values override them")
  func defaults() throws {
    let document = "query Q($a: Int = 1, $d: Direction = INBOUND, $s: String = \"x\") { f(a: $a, d: $d, s: $s) }"
    #expect(
      try inliner.inline(document: document, variables: [:])
        == #"query Q { f(a: 1, d: INBOUND, s: "x") }"#
    )
    #expect(
      try inliner.inline(document: document, variables: ["a": .int(9), "d": .string("OUTBOUND")])
        == #"query Q { f(a: 9, d: OUTBOUND, s: "x") }"#
    )
  }

  @Test("list and object defaults parse and render")
  func compositeDefaults() throws {
    #expect(
      try inliner.inline(
        document: "query Q($t: [String!] = [\"a\", \"b\"], $o: SendMessageInput = {to: [\"c\"]}) { f(t: $t, o: $o) }",
        variables: [:]
      ) == #"query Q { f(t: ["a", "b"], o: {to: ["c"]}) }"#
    )
  }

  // MARK: - Byte preservation

  @Test("dollar-looking text inside strings, block strings and comments is untouched")
  func dollarsInInertTokens() throws {
    let document = """
      query Q($a: Int) {
        # a comment mentioning $a and $missing
        f(a: $a, s: "a literal $a", b: \"\"\"
        block $a text
        \"\"\")
      }
      """
    let result = try inliner.inline(document: document, variables: ["a": .int(1)])
    let expected = """
      query Q {
        # a comment mentioning $a and $missing
        f(a: 1, s: "a literal $a", b: \"\"\"
        block $a text
        \"\"\")
      }
      """
    #expect(result == expected)
  }

  @Test("whitespace, comments and layout survive the rewrite byte for byte")
  func fullDocumentBytePreservation() throws {
    let document = """
      # leading comment

      query    Threads (   $accountId :  ID!  ,
                           $first : Int  = 10 )   {

        # inner comment
        threads( accountId :  $accountId ,   first: $first  )   {
          totalCount     # trailing comment
          pageInfo {   hasNextPage
                       endCursor }
        }
      }
      """
    let result = try inliner.inline(document: document, variables: ["accountId": .string("a")])
    let expected = """
      # leading comment

      query    Threads    {

        # inner comment
        threads( accountId :  "a" ,   first: 10  )   {
          totalCount     # trailing comment
          pageInfo {   hasNextPage
                       endCursor }
        }
      }
      """
    #expect(result == expected)
    // Every span that holds no variable token survives byte for byte.
    let tail = try #require(document.range(of: "totalCount     # trailing comment"))
    #expect(result.hasSuffix(String(document[tail.lowerBound...])))
    #expect(result.hasPrefix("# leading comment\n\nquery    Threads"))
  }

  @Test("the literal renderer is usable directly")
  func rendererIsPublic() {
    let catalog = FixtureCatalogs.gmail
    #expect(GraphQLLiteralRenderer.render(.string("ROWS"), as: nil, catalog: catalog) == "\"ROWS\"")
    #expect(
      GraphQLLiteralRenderer.render(.string("INBOUND"), as: .named("Direction"), catalog: catalog) == "INBOUND"
    )
    #expect(GraphQLLiteralRenderer.render(.null, as: .named("Int"), catalog: catalog) == "null")
    #expect(
      GraphQLLiteralRenderer.render(
        .array([.int(1), .int(2)]),
        as: .nonNull(.list(.named("Int"))),
        catalog: catalog
      ) == "[1, 2]"
    )
  }
}
