import Testing
@testable import GatewaySDKKit

@Suite("GraphQL validator")
struct GraphQLValidatorTests {
  private struct ValidationCase {
    let code: String
    let source: String
    let path: [String]
    let message: String
  }

  private struct WrapperCase {
    let type: GatewayTypeRef
    let field: String
    let passes: Bool
  }

  private let validator = GatewayGraphQLValidator(catalog: FixtureCatalogs.runtime)

  @Test("coerces nested input variables and applies input defaults")
  func coercesInput() throws {
    let document = try GatewayGraphQLParser.parse(#"query Q($id: ID!, $limit: Int) { threads(input: {accountId: $id, limit: $limit, direction: INBOUND}) { totalCount } }"#)
    let validated = try validator.validate(document, variables: ["id": .string("a1")])
    #expect(validated.rootFields[0].arguments == ["input": .object(["accountId": .string("a1"), "direction": .string("INBOUND"), "limit": .int(25)])])
  }

  @Test("reports each stable validation code")
  func stableCodes() throws {
    let cases = [
      ValidationCase(code: "UNKNOWN_FIELD", source: "{ missing { id } }", path: ["missing"], message: "unknown root field"),
      ValidationCase(code: "UNKNOWN_ARGUMENT", source: #"{ labels(accountId: "a", extra: 1) { name } }"#, path: ["labels"], message: "unknown argument"),
      ValidationCase(code: "MISSING_ARGUMENT", source: "{ labels { name } }", path: ["labels"], message: "missing required argument"),
      ValidationCase(code: "ARGUMENT_TYPE", source: "{ labels(accountId: 1) { name } }", path: ["labels"], message: "argument"),
      ValidationCase(code: "UNUSED_VARIABLE", source: #"query($id: ID) { labels(accountId: "a") { name } }"#, path: [], message: "is not used"),
      ValidationCase(code: "UNDECLARED_VARIABLE", source: "{ labels(accountId: $id) { name } }", path: [], message: "is not declared"),
      ValidationCase(code: "MISSING_VARIABLE", source: "query($id: ID!) { labels(accountId: $id) { name } }", path: [], message: "missing required variable"),
      ValidationCase(code: "VARIABLE_TYPE", source: "query($id: Int) { labels(accountId: $id) { name } }", path: ["labels"], message: "variable"),
      ValidationCase(code: "INVALID_SELECTION", source: #"{ labels(accountId: "a") { name { x } } }"#, path: ["labels", "name"], message: "leaf type"),
      ValidationCase(
        code: "MULTIPLE_MUTATIONS",
        source: #"mutation { first: sendMessage(input: {accountId: "a", to: ["b"], body: "x"}) { messageId } second: sendMessage(input: {accountId: "a", to: ["b"], body: "x"}) { messageId } }"#,
        path: [], message: "one root field"
      ),
      ValidationCase(code: "DUPLICATE_ALIAS", source: #"{ x: labels(accountId: "a") { name } x: labels(accountId: "a") { name } }"#, path: ["x"], message: "duplicate response key")
    ]
    for item in cases { try expectCode(item) }
    try expectCode("UNKNOWN_VARIABLE", #"{ labels(accountId: "a") { name } }"#, variables: ["extra": .string("x")])
    // Each public code has an adjacent accepted request, proving that the rejection
    // is narrow rather than merely exercising a broad failure path.
    let accepted = try GatewayGraphQLParser.parse(#"{ labels(accountId: "a") { name } }"#)
    for _ in cases + [ValidationCase(code: "UNKNOWN_VARIABLE", source: "", path: [], message: "")] {
      #expect(try validator.validate(accepted).rootFields.count == 1)
    }
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
    for suppliedNodes in [9_998, 9_999, 10_000] {
      let rows = jsonRows(nodes: suppliedNodes)
      do {
        let validated = try GatewayGraphQLValidator(catalog: catalog).validate(
          document,
          variables: ["payload": .array(rows)]
        )
        if suppliedNodes > 9_999 {
          Issue.record("expected aggregate RESOURCE_LIMIT")
        } else {
          #expect(validated.rootFields.count == 1)
        }
      } catch let error as GatewaySDKError {
        guard case .validation(let code, let message, let path) = error else {
          Issue.record("expected validation error")
          continue
        }
        #expect(suppliedNodes > 9_999)
        #expect(code == "RESOURCE_LIMIT")
        #expect(message.contains("inputValueNodes maximum 10000"))
        #expect(path == [])
      }
    }
  }

  @Test("materializes direct AST and supplied-variable input boundary triples")
  func directAndSuppliedInputBoundaries() throws {
    let local = GatewayGraphQLValidator(catalog: jsonCatalog())
    for count in [GatewayGraphQLLimits.containerEntries - 1, GatewayGraphQLLimits.containerEntries, GatewayGraphQLLimits.containerEntries + 1] {
      let document = inspectDocument(value: .list(Array(repeating: GraphQLValue.int(1), count: count)))
      try expectInputBoundary(document, validator: local, over: count > GatewayGraphQLLimits.containerEntries)
    }
    for nodes in [9_999, 10_000, 10_001] {
      let document = inspectDocument(value: literalRows(nodes: nodes))
      try expectInputBoundary(document, validator: local, over: nodes > GatewayGraphQLLimits.inputValueNodes)
    }
    let variables = try GatewayGraphQLParser.parse("query($payload: JSON) { inspect(payload: $payload) }")
    for levels in [GatewayGraphQLLimits.depth - 2, GatewayGraphQLLimits.depth - 1, GatewayGraphQLLimits.depth] {
      var value: GatewayJSONValue = .int(1)
      for _ in 0..<levels { value = .array([value]) }
      try expectInputBoundary(
        variables,
        validator: local,
        variables: ["payload": value],
        over: levels >= GatewayGraphQLLimits.depth
      )
    }
  }

  @Test("applies defaults preserves null and validates variable wrapper compatibility")
  func coercionAndWrapperMatrix() throws {
    var catalog = FixtureCatalogs.runtime
    catalog.operations.append(.init(
      name: "coerce",
      kind: .query,
      tier: "reader",
      arguments: [
        .init(name: "optional", type: .named("ID"), defaultValue: .string("catalog")),
        .init(name: "list", type: .list(.named("Int"))),
        .init(name: "float", type: .named("Float")),
        .init(name: "direction", type: .named("Direction"))
      ],
      result: .named("Label")
    ))
    let local = GatewayGraphQLValidator(catalog: catalog)
    let document = try GatewayGraphQLParser.parse(#"query($id: ID!, $items: [Int]!, $number: Float, $direction: Direction) { coerce(optional: $id, list: $items, float: $number, direction: $direction) { name } }"#)
    let output = try local.validate(document, variables: [
      "id": .string("provided"), "items": .int(3), "number": .int(4), "direction": .string("INBOUND")
    ])
    #expect(output.rootFields[0].arguments == [
      "optional": .string("provided"), "list": .array([.int(3)]), "float": .double(4), "direction": .string("INBOUND")
    ])

    let nullDocument = try GatewayGraphQLParser.parse(#"{ coerce(optional: null) { name } }"#)
    #expect(try local.validate(nullDocument).rootFields[0].arguments["optional"] == .null)
    let defaultDocument = try GatewayGraphQLParser.parse(#"{ coerce { name } }"#)
    #expect(try local.validate(defaultDocument).rootFields[0].arguments["optional"] == .string("catalog"))
    let invalidEnum = try GatewayGraphQLParser.parse(#"{ coerce(direction: "INBOUND") { name } }"#)
    #expect(throws: GatewaySDKError.self) { _ = try local.validate(invalidEnum) }
  }

  @Test("reports validator paths and root/selection boundary triples")
  func pathsAndSelectionBoundaries() throws {
    let nested = try GatewayGraphQLParser.parse(#"{ threads(input: {accountId: "a"}) { edges { node(unused: 1) { id } } } }"#)
    try expectDocumentCode("INVALID_SELECTION", nested, path: ["threads", "edges", "node"], message: "nested field arguments")
    let unknownInput = try GatewayGraphQLParser.parse(#"{ threads(input: {accountId: "a", extra: 1}) { totalCount } }"#)
    try expectDocumentCode("ARGUMENT_TYPE", unknownInput, path: ["threads"], message: "extra")

    for count in [63, 64, 65] {
      let document = GatewayGraphQLDocument(operationType: .query, selectionSet: (0..<count).map {
        .init(
          alias: "r\($0)",
          name: "labels",
          arguments: [.init(name: "accountId", value: .string("a"))],
          selectionSet: [.init(name: "name")]
        )
      })
      do {
        let result = try validator.validate(document)
        if count > GatewayGraphQLLimits.rootFields {
          Issue.record("expected root limit")
        } else {
          #expect(result.rootFields.count == count)
        }
      } catch let error as GatewaySDKError {
        guard case .validation(let code, let message, let path) = error else { Issue.record("expected validation error"); continue }
        #expect(count > GatewayGraphQLLimits.rootFields)
        #expect(code == "RESOURCE_LIMIT")
        #expect(message.contains("rootFields maximum 64"))
        #expect(path == [])
      }
    }
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

  @Test("accepts and rejects every variable wrapper compatibility boundary")
  func variableWrapperMatrix() throws {
    var catalog = FixtureCatalogs.runtime
    catalog.operations.append(.init(name: "optional", kind: .query, tier: "reader", arguments: [.init(name: "value", type: .named("ID"))], result: .named("Label")))
    catalog.operations.append(.init(name: "required", kind: .query, tier: "reader", arguments: [.init(name: "value", type: .nonNull(.named("ID")))], result: .named("Label")))
    catalog.operations.append(.init(name: "list", kind: .query, tier: "reader", arguments: [.init(name: "value", type: .list(.named("ID")))], result: .named("Label")))
    let local = GatewayGraphQLValidator(catalog: catalog)
    let cases = [
      WrapperCase(type: .nonNull(.named("ID")), field: "optional", passes: true),
      WrapperCase(type: .named("ID"), field: "optional", passes: true),
      WrapperCase(type: .named("ID"), field: "required", passes: false),
      WrapperCase(type: .nonNull(.list(.named("ID"))), field: "list", passes: true),
      WrapperCase(type: .list(.nonNull(.named("ID"))), field: "list", passes: false)
    ]
    for item in cases {
      let document = GatewayGraphQLDocument(
        operationType: .query,
        variableDefinitions: [.init(name: "value", type: item.type)],
        selectionSet: [.init(name: item.field, arguments: [.init(name: "value", value: .variable("value"))], selectionSet: [.init(name: "name")])]
      )
      if item.passes {
        #expect(try local.validate(document, variables: ["value": .string("a")]).rootFields.count == 1)
      } else {
        try expectCode("VARIABLE_TYPE", document, validator: local, variables: ["value": .string("a")])
      }
    }
  }

  @Test("enforces direct AST selection and type-depth boundary triples")
  func directAstSelectionAndTypeBoundaries() throws {
    for count in [GatewayGraphQLLimits.selections - 1, GatewayGraphQLLimits.selections, GatewayGraphQLLimits.selections + 1] {
      let fields = (0..<(count - 1)).map { GatewayGraphQLDocument.Selection(alias: "n\($0)", name: "name") }
      let document = GatewayGraphQLDocument(operationType: .query, selectionSet: [
        .init(name: "labels", arguments: [.init(name: "accountId", value: .string("a"))], selectionSet: fields)
      ])
      try expectBoundary(document, validator: validator, over: count > GatewayGraphQLLimits.selections, path: ["labels"])
    }
    for wrappers in [GatewayGraphQLLimits.depth - 1, GatewayGraphQLLimits.depth, GatewayGraphQLLimits.depth + 1] {
      var type: GatewayTypeRef = .named("ID")
      for _ in 0..<wrappers { type = .list(type) }
      let document = GatewayGraphQLDocument(
        operationType: .query,
        variableDefinitions: [.init(name: "v", type: type)],
        selectionSet: [.init(name: "labels", arguments: [.init(name: "accountId", value: .string("a"))], selectionSet: [.init(name: "name")])]
      )
      do {
        _ = try validator.validate(document)
        Issue.record("expected unused variable or resource limit")
      } catch let error as GatewaySDKError {
        guard case .validation(let code, _, let path) = error else { Issue.record("expected validation error"); continue }
        if wrappers > GatewayGraphQLLimits.depth - 1 {
          #expect(code == "RESOURCE_LIMIT"); #expect(path == [])
        } else { #expect(code == "UNUSED_VARIABLE") }
      }
    }
  }

  private func expectCode(_ item: ValidationCase) throws {
    let document = try GatewayGraphQLParser.parse(item.source)
    do {
      _ = try validator.validate(document)
      Issue.record("expected \(item.code)")
    } catch let error as GatewaySDKError {
      guard case .validation(let actual, let message, let path) = error else { Issue.record("expected validation error"); return }
      #expect(actual == item.code)
      #expect(path == item.path)
      #expect(message.localizedCaseInsensitiveContains(item.message))
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

  private func expectCode(
    _ expected: String,
    _ document: GatewayGraphQLDocument,
    validator: GatewayGraphQLValidator,
    variables: [String: GatewayJSONValue]
  ) throws {
    do {
      _ = try validator.validate(document, variables: variables)
      Issue.record("expected \(expected)")
    } catch let error as GatewaySDKError {
      guard case .validation(let actual, _, _) = error else { Issue.record("expected validation error"); return }
      #expect(actual == expected)
    }
  }

  private func expectBoundary(
    _ document: GatewayGraphQLDocument,
    validator: GatewayGraphQLValidator,
    over: Bool,
    path: [String]
  ) throws {
    do {
      let result = try validator.validate(document)
      if over { Issue.record("expected resource limit") } else { #expect(result.rootFields.count == 1) }
    } catch let error as GatewaySDKError {
      guard case .validation(let code, let message, let actualPath) = error else { Issue.record("expected validation error"); return }
      #expect(over)
      #expect(code == "RESOURCE_LIMIT")
      #expect(message.contains("selections maximum"))
      #expect(actualPath.starts(with: path))
    }
  }

  private func expectInputBoundary(
    _ document: GatewayGraphQLDocument,
    validator: GatewayGraphQLValidator,
    variables: [String: GatewayJSONValue] = [:],
    over: Bool
  ) throws {
    do {
      let result = try validator.validate(document, variables: variables)
      if over { Issue.record("expected input resource limit") } else { #expect(result.rootFields.count == 1) }
    } catch let error as GatewaySDKError {
      guard case .validation(let code, let message, let path) = error else {
        Issue.record("expected validation error")
        return
      }
      #expect(over)
      #expect(code == "RESOURCE_LIMIT")
      #expect(message.contains("maximum"))
      #expect(path == ["inspect"] || path.isEmpty)
    }
  }

  private func jsonCatalog() -> GatewaySchemaCatalog {
    GatewaySchemaCatalog(
      provider: "test", tier: "reader",
      operations: [.init(name: "inspect", kind: .query, tier: "reader", arguments: [.init(name: "payload", type: .named("JSON"))], result: .named("JSON"))]
    )
  }

  private func inspectDocument(value: GraphQLValue) -> GatewayGraphQLDocument {
    GatewayGraphQLDocument(operationType: .query, selectionSet: [.init(name: "inspect", arguments: [.init(name: "payload", value: value)])])
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

  private func expectDocumentCode(
    _ expected: String,
    _ document: GatewayGraphQLDocument,
    path: [String],
    message: String
  ) throws {
    do {
      _ = try validator.validate(document)
      Issue.record("expected \(expected)")
    } catch let error as GatewaySDKError {
      guard case .validation(let code, let actualMessage, let actualPath) = error else {
        Issue.record("expected validation error")
        return
      }
      #expect(code == expected)
      #expect(actualPath == path)
      #expect(actualMessage.contains(message))
    }
  }

  private func jsonRows(nodes: Int) -> [GatewayJSONValue] {
    let leaves = nodes - 1_001
    let fullRows = leaves / 9
    let remaining = leaves % 9
    var rows = Array(repeating: GatewayJSONValue.array(Array(repeating: .int(1), count: 9)), count: fullRows)
    if remaining > 0 { rows.append(.array(Array(repeating: .int(1), count: remaining))) }
    while rows.count < 1_000 { rows.append(.array([])) }
    return rows
  }

  private func literalRows(nodes: Int) -> GraphQLValue {
    let leaves = nodes - 1_001
    let fullRows = leaves / 9
    let remaining = leaves % 9
    var rows = Array(repeating: GraphQLValue.list(Array(repeating: .int(1), count: 9)), count: fullRows)
    if remaining > 0 { rows.append(.list(Array(repeating: .int(1), count: remaining))) }
    while rows.count < 1_000 { rows.append(.list([])) }
    return .list(rows)
  }
}
