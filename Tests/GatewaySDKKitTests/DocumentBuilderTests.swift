import Foundation
import Testing
@testable import GatewaySDKKit

@Suite("Document builder")
struct DocumentBuilderTests {
  private let builder = GatewayDocumentBuilder(catalog: FixtureCatalogs.gmail)
  private let catalog = FixtureCatalogs.gmail

  @Test("the Threads document matches the golden byte for byte")
  func threadsGolden() throws {
    let built = try builder.build(
      GatewayOperationRequest(
        operation: "threads",
        variables: ["accountId": .string("acct-1"), "first": .int(20)]
      )
    )
    let expected = """
      query Threads($accountId: ID!, $first: Int) {
        threads(accountId: $accountId, first: $first) {
          totalCount
          pageInfo { hasNextPage endCursor }
          edges { cursor node { id subject messages { id snippet direction } } }
        }
      }
      """
    #expect(built.document == expected)
    #expect(!built.document.hasSuffix("\n"))
    #expect(built.variables == ["accountId": .string("acct-1"), "first": .int(20)])
  }

  @Test("only supplied variables are declared and passed, in catalog argument order")
  func onlySuppliedVariables() throws {
    let built = try builder.build(
      GatewayOperationRequest(
        operation: "threads",
        variables: ["direction": .string("INBOUND"), "accountId": .string("a")],
        selection: .fields(["totalCount"])
      )
    )
    #expect(
      built.document == """
        query Threads($accountId: ID!, $direction: Direction) {
          threads(accountId: $accountId, direction: $direction) {
            totalCount
          }
        }
        """
    )
  }

  @Test("mutations use the mutation keyword and an upper-camel-cased name")
  func mutationGolden() throws {
    let built = try builder.build(
      GatewayOperationRequest(
        operation: "sendMessage",
        variables: [
          "accountId": .string("a"),
          "input": .object(["to": .array([.string("x@example.com")])])
        ]
      )
    )
    #expect(
      built.document == """
        mutation SendMessage($accountId: ID!, $input: SendMessageInput!) {
          sendMessage(accountId: $accountId, input: $input) {
            id
            sentAt
          }
        }
        """
    )
  }

  @Test("upperCamelCased splits on spaces, dashes and underscores")
  func nameCasing() {
    #expect(GatewayDocumentBuilder.upperCamelCased("threads") == "Threads")
    #expect(GatewayDocumentBuilder.upperCamelCased("sendMessage") == "SendMessage")
    #expect(GatewayDocumentBuilder.upperCamelCased("values get") == "ValuesGet")
    #expect(GatewayDocumentBuilder.upperCamelCased("page-size_x") == "PageSizeX")
  }

  @Test("an operation with no supplied variables omits both parenthesis groups")
  func noVariables() throws {
    let catalog = GatewaySchemaCatalog(
      provider: "p",
      tier: "t",
      operations: [GatewayOperation(name: "ping", kind: .query, tier: "t", result: .named("Pong"))],
      types: [GatewayNamedType(name: "Pong", kind: .object([GatewayField(name: "ok", type: .named("Boolean"))]))]
    )
    let built = try GatewayDocumentBuilder(catalog: catalog).build(GatewayOperationRequest(operation: "ping"))
    #expect(
      built.document == """
        query Ping {
          ping {
            ok
          }
        }
        """
    )
  }

  @Test("a scalar or enum result prints no selection set")
  func scalarResultHasNoSelection() throws {
    let catalog = GatewaySchemaCatalog(
      provider: "p",
      tier: "t",
      operations: [
        GatewayOperation(name: "count", kind: .query, tier: "t", result: .nonNull(.named("Int"))),
        GatewayOperation(name: "mode", kind: .query, tier: "t", result: .named("Direction"))
      ],
      types: [GatewayNamedType(name: "Direction", kind: .enumeration(["IN", "OUT"]))]
    )
    let builder = GatewayDocumentBuilder(catalog: catalog)
    #expect(try builder.build(GatewayOperationRequest(operation: "count")).document == "query Count {\n  count\n}")
    #expect(try builder.build(GatewayOperationRequest(operation: "mode")).document == "query Mode {\n  mode\n}")
  }

  // MARK: - Default selection rules

  @Test("default selection opens objects at levels 1 to 3 and omits level 4")
  func depthBoundary() throws {
    let built = try builder.build(
      GatewayOperationRequest(operation: "threads", variables: ["accountId": .string("a")])
    )
    // Message sits at level 3 and opens; its object field `from` would sit at level 4.
    #expect(built.document.contains("messages { id snippet direction }"))
    #expect(!built.document.contains("from"))
    #expect(!built.document.contains("address"))
  }

  @Test("recursion stops at a type already on the path")
  func cycleStop() throws {
    let built = try builder.build(
      GatewayOperationRequest(operation: "thread", variables: ["accountId": .string("a"), "id": .string("t")])
    )
    // Message.thread points back at Thread, which is already on the path.
    #expect(
      built.document == """
        query Thread($accountId: ID!, $id: ID!) {
          thread(accountId: $accountId, id: $id) {
            id
            subject
            messages { id snippet direction from { address name } }
          }
        }
        """
    )
  }

  @Test("fields with required arguments are skipped by the default selection")
  func requiredArgumentFieldSkipped() {
    let nodes = GatewaySelectionPlanner.defaultSelection(of: "Message", catalog: catalog)
    #expect(nodes.map(\.name) == ["id", "snippet", "direction", "from", "thread"])
    #expect(!nodes.contains { $0.name == "raw" })
  }

  @Test("an object whose fields were all skipped is omitted entirely")
  func emptyObjectOmitted() {
    let catalog = GatewaySchemaCatalog(
      provider: "p",
      tier: "t",
      types: [
        GatewayNamedType(
          name: "Root",
          kind: .object([
            GatewayField(name: "ok", type: .named("Boolean")),
            GatewayField(name: "blocked", type: .named("Blocked"))
          ])
        ),
        GatewayNamedType(
          name: "Blocked",
          kind: .object([
            GatewayField(
              name: "needsArg",
              type: .named("String"),
              arguments: [GatewayArgument(name: "a", type: .nonNull(.named("String")))]
            )
          ])
        )
      ]
    )
    #expect(GatewaySelectionPlanner.defaultSelection(of: "Root", catalog: catalog).map(\.name) == ["ok"])
  }

  @Test("a composite result whose default selection is empty throws rather than emitting a bare field")
  func emptyDefaultSelectionThrows() throws {
    // GraphQL requires a selection set on a composite field, so emitting `top` bare would
    // ship a document the gateway cannot parse. This is not the scalar-result case.
    let allFieldsSkipped = GatewaySchemaCatalog(
      provider: "p",
      tier: "t",
      operations: [GatewayOperation(name: "top", kind: .query, tier: "t", result: .named("Empty"))],
      types: [
        GatewayNamedType(
          name: "Empty",
          kind: .object([
            GatewayField(
              name: "needsArg",
              type: .named("Int"),
              arguments: [GatewayArgument(name: "x", type: .nonNull(.named("Int")))]
            )
          ])
        )
      ]
    )
    #expect {
      _ = try GatewayDocumentBuilder(catalog: allFieldsSkipped)
        .build(GatewayOperationRequest(operation: "top"))
    } throws: { error in
      error as? GatewaySDKError == .emptySelection(operation: "top", type: "Empty")
    }
    #expect(
      allFieldsSkipped.validate().contains(
        GatewaySchemaProblem(
          path: "operation.top.result",
          message: "result type 'Empty' yields an empty default selection"
        )
      )
    )

    // Mutually recursive objects with no scalar field anywhere: the cycle stop leaves
    // both sides empty, so the root has nothing to select either.
    let mutuallyRecursive = GatewaySchemaCatalog(
      provider: "p",
      tier: "t",
      operations: [GatewayOperation(name: "a", kind: .query, tier: "t", result: .named("A"))],
      types: [
        GatewayNamedType(name: "A", kind: .object([GatewayField(name: "b", type: .named("B"))])),
        GatewayNamedType(name: "B", kind: .object([GatewayField(name: "a", type: .named("A"))]))
      ]
    )
    #expect {
      _ = try GatewayDocumentBuilder(catalog: mutuallyRecursive)
        .build(GatewayOperationRequest(operation: "a"))
    } throws: { error in
      error as? GatewaySDKError == .emptySelection(operation: "a", type: "A")
    }
    #expect(
      mutuallyRecursive.validate().contains(
        GatewaySchemaProblem(
          path: "operation.a.result",
          message: "result type 'A' yields an empty default selection"
        )
      )
    )

    // `.raw` still drives these operations, so the validate() problem is advisory.
    #expect(
      try GatewayDocumentBuilder(catalog: mutuallyRecursive).build(
        GatewayOperationRequest(operation: "a", selection: .raw("{ b { a { b } } }"))
      ).document == "query A {\n  a { b { a { b } } }\n}"
    )
  }

  @Test("a scalar or enum result still emits no selection set, and validate stays quiet")
  func leafResultIsNotConfusedWithAnEmptySelection() throws {
    // The control for the rule above: `.none` must remain reachable for a genuine leaf.
    let catalog = GatewaySchemaCatalog(
      provider: "p",
      tier: "t",
      operations: [
        GatewayOperation(name: "count", kind: .query, tier: "t", result: .nonNull(.named("Int"))),
        GatewayOperation(name: "mode", kind: .query, tier: "t", result: .named("Direction")),
        GatewayOperation(name: "blob", kind: .query, tier: "t", result: .named("JSON"))
      ],
      types: [GatewayNamedType(name: "Direction", kind: .enumeration(["IN", "OUT"]))]
    )
    let builder = GatewayDocumentBuilder(catalog: catalog)
    #expect(try builder.build(GatewayOperationRequest(operation: "count")).document
      == "query Count {\n  count\n}")
    #expect(try builder.build(GatewayOperationRequest(operation: "mode")).document
      == "query Mode {\n  mode\n}")
    #expect(try builder.build(GatewayOperationRequest(operation: "blob")).document
      == "query Blob {\n  blob\n}")
    #expect(catalog.validate() == [])
  }

  // MARK: - .fields paths

  @Test("valid dot paths select scalars, nest, and expand object leaves")
  func fieldPaths() throws {
    let built = try builder.build(
      GatewayOperationRequest(
        operation: "threads",
        variables: ["accountId": .string("a")],
        selection: .fields(["totalCount", "edges.node.subject", "edges.cursor", "pageInfo"])
      )
    )
    #expect(
      built.document == """
        query Threads($accountId: ID!) {
          threads(accountId: $accountId) {
            totalCount
            edges { node { subject } cursor }
            pageInfo { hasNextPage endCursor }
          }
        }
        """
    )
  }

  @Test("an object leaf expands with depth recounted from that object")
  func objectLeafExpansion() throws {
    let built = try builder.build(
      GatewayOperationRequest(
        operation: "threads",
        variables: ["accountId": .string("a")],
        selection: .fields(["edges.node.messages"])
      )
    )
    // Depth restarts at Message, so EmailAddress (a level deeper) is still included.
    #expect(built.document.contains("edges { node { messages { id snippet direction from { address name } } } }"))
  }

  @Test("an object leaf expansion still stops at types already walked")
  func objectLeafCycleStop() throws {
    let built = try builder.build(
      GatewayOperationRequest(
        operation: "thread",
        variables: ["accountId": .string("a"), "id": .string("t")],
        selection: .fields(["messages"])
      )
    )
    #expect(built.document.contains("messages { id snippet direction from { address name } }"))
    #expect(!built.document.contains("thread {"))
  }

  @Test(
    "invalid dot paths throw invalidSelectionPath carrying the full path",
    arguments: [
      "nope",
      "edges.nope",
      "totalCount.deeper",
      "edges.node.subject.deeper",
      "",
      "edges..node",
      "edges.node.raw"
    ]
  )
  func invalidFieldPaths(_ path: String) {
    #expect {
      _ = try builder.build(
        GatewayOperationRequest(
          operation: "threads",
          variables: ["accountId": .string("a")],
          selection: .fields([path])
        )
      )
    } throws: { error in
      error as? GatewaySDKError == .invalidSelectionPath(path: path)
    }
  }

  // MARK: - .raw

  @Test("a raw selection set is appended verbatim on the root field line")
  func rawSelection() throws {
    let built = try builder.build(
      GatewayOperationRequest(
        operation: "threads",
        variables: ["accountId": .string("a"), "first": .int(3)],
        selection: .raw("{ totalCount edges { cursor } }")
      )
    )
    #expect(
      built.document == """
        query Threads($accountId: ID!, $first: Int) {
          threads(accountId: $accountId, first: $first) { totalCount edges { cursor } }
        }
        """
    )
  }

  @Test("a raw selection set may carry leading whitespace but must start with a brace")
  func rawSelectionValidation() throws {
    let built = try builder.build(
      GatewayOperationRequest(
        operation: "threads",
        variables: ["accountId": .string("a")],
        selection: .raw("   { totalCount }")
      )
    )
    #expect(built.document.contains("threads(accountId: $accountId) { totalCount }"))

    #expect {
      _ = try builder.build(
        GatewayOperationRequest(
          operation: "threads",
          variables: ["accountId": .string("a")],
          selection: .raw("totalCount")
        )
      )
    } throws: { error in
      error as? GatewaySDKError == .invalidSelectionPath(path: "totalCount")
    }
  }

  @Test("a raw selection set is used even for a scalar-result operation")
  func rawWinsOverResultShape() throws {
    let catalog = GatewaySchemaCatalog(
      provider: "p",
      tier: "t",
      operations: [GatewayOperation(name: "count", kind: .query, tier: "t", result: .named("Int"))]
    )
    let built = try GatewayDocumentBuilder(catalog: catalog).build(
      GatewayOperationRequest(operation: "count", selection: .raw("{ x }"))
    )
    #expect(built.document == "query Count {\n  count { x }\n}")
  }

  // MARK: - Errors

  @Test("unknown operation")
  func unknownOperation() {
    #expect {
      _ = try builder.build(GatewayOperationRequest(operation: "nope"))
    } throws: { error in
      error as? GatewaySDKError == .unknownOperation(name: "nope")
    }
  }

  @Test("a command operation must go through the argv builder")
  func commandNeedsArgv() {
    let builder = GatewayDocumentBuilder(catalog: FixtureCatalogs.documents)
    #expect {
      _ = try builder.build(GatewayOperationRequest(operation: "files list"))
    } throws: { error in
      error as? GatewaySDKError == .commandOperationNeedsArgv(name: "files list")
    }
  }

  @Test("unknown variable")
  func unknownVariable() {
    #expect {
      _ = try builder.build(
        GatewayOperationRequest(
          operation: "threads",
          variables: ["accountId": .string("a"), "bogus": .int(1)]
        )
      )
    } throws: { error in
      error as? GatewaySDKError == .unknownVariable(operation: "threads", name: "bogus")
    }
  }

  @Test("a missing required variable, and an explicit null for one, both fail")
  func missingRequiredVariable() {
    for variables in [[:], ["accountId": GatewayJSONValue.null]] {
      #expect {
        _ = try builder.build(GatewayOperationRequest(operation: "threads", variables: variables))
      } throws: { error in
        error as? GatewaySDKError == .missingRequiredVariable(operation: "threads", name: "accountId")
      }
    }
  }

  @Test("a required argument carrying a catalog default may be omitted")
  func requiredWithDefaultMayBeOmitted() throws {
    let catalog = GatewaySchemaCatalog(
      provider: "p",
      tier: "t",
      operations: [
        GatewayOperation(
          name: "op",
          kind: .query,
          tier: "t",
          arguments: [
            GatewayArgument(name: "a", type: .nonNull(.named("Int")), defaultValue: .int(1))
          ],
          result: .named("Int")
        )
      ]
    )
    let built = try GatewayDocumentBuilder(catalog: catalog).build(GatewayOperationRequest(operation: "op"))
    // The gateway applies the default; the kit never injects it.
    #expect(built.document == "query Op {\n  op\n}")
    #expect(built.variables.isEmpty)
  }
}
