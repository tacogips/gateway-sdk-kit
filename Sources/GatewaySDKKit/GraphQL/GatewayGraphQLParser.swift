import Foundation

public enum GatewayGraphQLParser {
  public static func parse(_ document: String) throws -> GatewayGraphQLDocument {
    guard document.utf8.count <= GatewayGraphQLLimits.documentBytes else {
      throw GatewaySDKError.syntax(
        message: GatewayGraphQLLimits.message("documentBytes", GatewayGraphQLLimits.documentBytes), line: 1, column: 1
      )
    }
    let tokens = try GraphQLLexer.tokenize(document, maximumTokens: GatewayGraphQLLimits.tokens)
      .filter { $0.kind != .comment }
    var parser = GraphQLDocumentParser(source: document, tokens: tokens)
    return try parser.parse()
  }
}

enum GraphQLStringDecoder {
  static func decode(_ token: GraphQLToken) throws -> String {
    switch token.kind {
    case .string: return try decodeQuoted(String(token.text.dropFirst().dropLast()))
    case .blockString: return decodeBlock(String(token.text.dropFirst(3).dropLast(3)))
    default: throw StringDecodeError.invalidEscape
    }
  }

  private static func decodeQuoted(_ raw: String) throws -> String {
    var result = ""
    var index = raw.startIndex
    while index < raw.endIndex {
      let char = raw[index]
      guard char == "\\" else { result.append(char); index = raw.index(after: index); continue }
      index = raw.index(after: index)
      guard index < raw.endIndex else { throw StringDecodeError.invalidEscape }
      switch raw[index] {
      case "\"": result.append("\"")
      case "\\": result.append("\\")
      case "/": result.append("/")
      case "b": result.append("\u{08}")
      case "f": result.append("\u{0C}")
      case "n": result.append("\n")
      case "r": result.append("\r")
      case "t": result.append("\t")
      case "u":
        let firstStart = raw.index(after: index)
        guard let (first, afterFirst) = unicodeCodeUnit(raw, at: firstStart) else { throw StringDecodeError.invalidEscape }
        if (0xD800...0xDBFF).contains(first) {
          guard afterFirst < raw.endIndex, raw[afterFirst] == "\\",
            raw.index(after: afterFirst) < raw.endIndex, raw[raw.index(after: afterFirst)] == "u",
            let (second, afterSecond) = unicodeCodeUnit(raw, at: raw.index(afterFirst, offsetBy: 2)),
            (0xDC00...0xDFFF).contains(second),
            let scalar = Unicode.Scalar(0x10000 + ((first - 0xD800) << 10) + (second - 0xDC00))
          else { throw StringDecodeError.invalidEscape }
          result.unicodeScalars.append(scalar)
          index = afterSecond
          continue
        }
        guard !(0xDC00...0xDFFF).contains(first), let scalar = Unicode.Scalar(first) else {
          throw StringDecodeError.invalidEscape
        }
        result.unicodeScalars.append(scalar)
        index = afterFirst
        continue
      default: throw StringDecodeError.invalidEscape
      }
      index = raw.index(after: index)
    }
    return result
  }

  private static func unicodeCodeUnit(_ text: String, at start: String.Index) -> (UInt32, String.Index)? {
    guard let end = text.index(start, offsetBy: 4, limitedBy: text.endIndex), end <= text.endIndex,
      let value = UInt32(text[start..<end], radix: 16), text.distance(from: start, to: end) == 4 else { return nil }
    return (value, end)
  }

  private static func decodeBlock(_ raw: String) -> String {
    let replaced = raw.replacingOccurrences(of: "\\\"\"\"", with: "\"\"\"")
    var lines = replaced.components(separatedBy: .newlines)
    if lines.first?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true { lines.removeFirst() }
    if lines.last?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true { lines.removeLast() }
    let indents = lines.dropFirst().filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.map {
      $0.prefix { $0 == " " || $0 == "\t" }.count
    }
    if let indent = indents.min(), indent > 0 {
      lines = lines.map { line in
        let count = line.prefix { $0 == " " || $0 == "\t" }.count
        return String(line.dropFirst(min(indent, count)))
      }
    }
    return lines.joined(separator: "\n")
  }

  enum StringDecodeError: Error { case invalidEscape }
}

private struct GraphQLDocumentParser {
  let source: String
  let tokens: [GraphQLToken]
  var cursor = 0
  var selectionCount = 0
  var inputNodeCount = 0

  init(source: String, tokens: [GraphQLToken]) { self.source = source; self.tokens = tokens }

  mutating func parse() throws -> GatewayGraphQLDocument {
    guard let first = peek else { throw failure("expected an operation", at: nil) }
    let document: GatewayGraphQLDocument
    if first.text == "{" {
      document = GatewayGraphQLDocument(operationType: .query, selectionSet: try selectionSet(depth: 0, root: true))
    } else {
      document = try namedOperation()
    }
    if let trailing = peek {
      if trailing.text == "fragment" || trailing.text == "query" || trailing.text == "mutation" { throw failure("multiple operations are not supported", at: trailing) }
      throw failure("trailing tokens after operation", at: trailing)
    }
    return document
  }

  private mutating func namedOperation() throws -> GatewayGraphQLDocument {
    let operationToken = try take()
    let operation: GatewayGraphQLDocument.OperationType
    switch operationToken.text {
    case "query": operation = .query
    case "mutation": operation = .mutation
    case "subscription": throw failure("subscriptions are not supported", at: operationToken)
    case "fragment": throw failure("fragments are not supported", at: operationToken)
    default: throw failure("expected query, mutation, or selection set", at: operationToken)
    }
    var name: String?
    if peek?.kind == .name { name = try take().text }
    var definitions: [GatewayGraphQLDocument.VariableDefinition] = []
    if peek?.text == "(" { definitions = try variableDefinitions() }
    return GatewayGraphQLDocument(operationType: operation, name: name, variableDefinitions: definitions, selectionSet: try selectionSet(depth: 0, root: true))
  }

  private mutating func variableDefinitions() throws -> [GatewayGraphQLDocument.VariableDefinition] {
    _ = try expect("(")
    guard peek?.text != ")" else { throw failure("empty variable definitions", at: peek) }
    var definitions: [GatewayGraphQLDocument.VariableDefinition] = []
    var names: Set<String> = []
    while peek?.text != ")" {
      let variable = try take(kind: .variable)
      guard let name = variable.variableName else { throw failure("expected variable", at: variable) }
      guard names.insert(name).inserted else { throw failure("duplicate variable declaration '\(name)'", at: variable) }
      _ = try expect(":")
      let type = try typeReference(depth: 0)
      let defaultValue: GraphQLValue?
      if peek?.text == "=" { _ = try take(); defaultValue = try value(depth: 0, constant: true) } else { defaultValue = nil }
      definitions.append(.init(name: name, type: type, defaultValue: defaultValue))
    }
    _ = try expect(")")
    return definitions
  }

  private mutating func typeReference(depth: Int) throws -> GatewayTypeRef {
    try checkDepth(depth, at: peek)
    if peek?.text == "[" {
      _ = try take(); let inner = try typeReference(depth: depth + 1); _ = try expect("]")
      return peek?.text == "!" ? { _ = try? take(); return GatewayTypeRef.nonNull(.list(inner)) }() : .list(inner)
    }
    let name = try take(kind: .name)
    let type: GatewayTypeRef = .named(name.text)
    if peek?.text == "!" { _ = try take(); return .nonNull(type) }
    return type
  }

  private mutating func selectionSet(depth: Int, root: Bool) throws -> [GatewayGraphQLDocument.Selection] {
    let opening = try expect("{")
    try checkDepth(depth + 1, at: opening)
    var selections: [GatewayGraphQLDocument.Selection] = []
    while peek?.text != "}" {
      guard peek != nil else { throw failure("unterminated selection set", at: opening) }
      if root && selections.count >= GatewayGraphQLLimits.rootFields {
        throw failure(GatewayGraphQLLimits.message("rootFields", GatewayGraphQLLimits.rootFields), at: peek)
      }
      selectionCount += 1
      guard selectionCount <= GatewayGraphQLLimits.selections else {
        throw failure(GatewayGraphQLLimits.message("selections", GatewayGraphQLLimits.selections), at: peek)
      }
      selections.append(try selection(depth: depth + 1))
    }
    _ = try expect("}")
    guard !selections.isEmpty else { throw failure("empty selection set", at: opening) }
    return selections
  }

  private mutating func selection(depth: Int) throws -> GatewayGraphQLDocument.Selection {
    let initial = try take(kind: .name)
    if initial.text == "fragment" { throw failure("fragments are not supported", at: initial) }
    if initial.text.hasPrefix("__") { throw failure("introspection is not supported", at: initial) }
    var alias: String?
    var name = initial.text
    var field = initial
    if peek?.text == ":" {
      _ = try take()
      alias = name
      field = try take(kind: .name)
      name = field.text
    }
    if name.hasPrefix("__") { throw failure("introspection is not supported", at: field) }
    let arguments = peek?.text == "(" ? try arguments(depth: depth) : []
    if peek?.text == "@" { throw failure("directives are not supported", at: peek) }
    let nested = peek?.text == "{" ? try selectionSet(depth: depth, root: false) : []
    return .init(alias: alias, name: name, arguments: arguments, selectionSet: nested)
  }

  private mutating func arguments(depth: Int) throws -> [GatewayGraphQLDocument.Argument] {
    _ = try expect("(")
    var arguments: [GatewayGraphQLDocument.Argument] = []
    var names: Set<String> = []
    while peek?.text != ")" {
      let name = try take(kind: .name)
      guard names.insert(name.text).inserted else { throw failure("duplicate argument '\(name.text)'", at: name) }
      _ = try expect(":")
      arguments.append(.init(name: name.text, value: try value(depth: depth, constant: false)))
    }
    _ = try expect(")")
    return arguments
  }

  private mutating func value(depth: Int, constant: Bool) throws -> GraphQLValue {
    try checkDepth(depth + 1, at: peek)
    let token = try take()
    inputNodeCount += 1
    guard inputNodeCount <= GatewayGraphQLLimits.inputValueNodes else {
      throw failure(GatewayGraphQLLimits.message("inputValueNodes", GatewayGraphQLLimits.inputValueNodes), at: token)
    }
    switch token.kind {
    case .int:
      guard let value = Int64(token.text) else { throw failure("integer literal overflow", at: token) }; return .int(value)
    case .float:
      guard let value = Double(token.text), value.isFinite else { throw failure("invalid floating-point literal", at: token) }; return .float(value)
    case .string, .blockString:
      do { return .string(try GraphQLStringDecoder.decode(token)) } catch { throw failure("invalid string escape", at: token) }
    case .variable:
      guard !constant, let name = token.variableName else { throw failure("variables are not allowed in defaults", at: token) }
      return .variable(name)
    case .name:
      switch token.text {
      case "true": return .bool(true)
      case "false": return .bool(false)
      case "null": return .null
      default: return .enumValue(token.text)
      }
    case .punctuator:
      if token.text == "[" { return try listValue(depth: depth + 1, constant: constant) }
      if token.text == "{" { return try objectValue(depth: depth + 1, constant: constant) }
      if token.text == "..." { throw failure("fragments are not supported", at: token) }
      if token.text == "@" { throw failure("directives are not supported", at: token) }
      throw failure("expected value", at: token)
    case .comment: throw failure("expected value", at: token)
    }
  }

  private mutating func listValue(depth: Int, constant: Bool) throws -> GraphQLValue {
    var values: [GraphQLValue] = []
    while peek?.text != "]" {
      guard peek != nil else { throw failure("unterminated list", at: nil) }
      guard values.count < GatewayGraphQLLimits.containerEntries else { throw failure(GatewayGraphQLLimits.message("containerEntries", GatewayGraphQLLimits.containerEntries), at: peek) }
      values.append(try value(depth: depth, constant: constant))
    }
    _ = try expect("]"); return .list(values)
  }

  private mutating func objectValue(depth: Int, constant: Bool) throws -> GraphQLValue {
    var values: [(name: String, value: GraphQLValue)] = []
    var names: Set<String> = []
    while peek?.text != "}" {
      let key = try take(kind: .name)
      guard names.insert(key.text).inserted else { throw failure("duplicate object key '\(key.text)'", at: key) }
      guard values.count < GatewayGraphQLLimits.containerEntries else { throw failure(GatewayGraphQLLimits.message("containerEntries", GatewayGraphQLLimits.containerEntries), at: key) }
      _ = try expect(":")
      values.append((key.text, try value(depth: depth, constant: constant)))
    }
    _ = try expect("}"); return .object(values)
  }

  private var peek: GraphQLToken? { cursor < tokens.count ? tokens[cursor] : nil }
  private mutating func take() throws -> GraphQLToken { guard let token = peek else { throw failure("unexpected end of document", at: nil) }; cursor += 1; return token }
  private mutating func take(kind: GraphQLToken.Kind) throws -> GraphQLToken {
    let token = try take()
    if token.text == "@" { throw failure("directives are not supported", at: token) }
    if token.text == "..." { throw failure("fragments are not supported", at: token) }
    guard token.kind == kind else { throw failure("unexpected token '\(token.text)'", at: token) }
    return token
  }
  private mutating func expect(_ text: String) throws -> GraphQLToken {
    let token = try take()
    if token.text == "@" { throw failure("directives are not supported", at: token) }
    if token.text == "..." { throw failure("fragments are not supported", at: token) }
    guard token.text == text else { throw failure("expected '\(text)'", at: token) }
    return token
  }
  private func checkDepth(_ depth: Int, at token: GraphQLToken?) throws { if depth > GatewayGraphQLLimits.depth { throw failure(GatewayGraphQLLimits.message("depth", GatewayGraphQLLimits.depth), at: token) } }
  private func failure(_ message: String, at token: GraphQLToken?) -> GatewaySDKError {
    let position = GraphQLLexer.sourcePosition(source, token?.range.lowerBound ?? source.endIndex)
    return .syntax(message: message, line: position.line, column: position.column)
  }
}
