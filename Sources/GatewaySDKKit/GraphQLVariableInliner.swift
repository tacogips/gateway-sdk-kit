import Foundation

/// Rewrites a GraphQL document so it carries no variables, by validating the declared
/// variables and splicing their literal values into the body.
///
/// This exists for gateways whose runtime accepts a document but no variables map. The
/// rewrite is a splice over the original string: only the variable-definition
/// parenthesis and the `$var` tokens change, so whitespace, comments, strings and block
/// strings survive byte for byte.
public struct GraphQLVariableInliner: Sendable {
  private let catalog: GatewaySchemaCatalog

  public init(catalog: GatewaySchemaCatalog) {
    self.catalog = catalog
  }

  /// Validates the declared variables and returns the document with every `$var`
  /// replaced by its literal.
  ///
  /// A variable's value is the supplied value, else its declared default. A declared,
  /// used, nullable variable with neither inlines to an explicit `null`: the rewrite is
  /// a token splice, so it can replace `$var` but cannot delete the surrounding
  /// `arg: $var` pair the way an omitted GraphQL variable would. For an argument that
  /// distinguishes "absent" from `null` — a patch-style mutation, say — supply a value
  /// or give the variable a default rather than relying on omission.
  public func inline(document: String, variables: [String: GatewayJSONValue]) throws -> String {
    let tokens = try GraphQLLexer.tokenize(document)
    let significant = tokens.filter { $0.kind != .comment }
    guard let first = significant.first else {
      throw GatewaySDKError.malformedDocument("document contains no GraphQL tokens")
    }

    if first.kind == .punctuator, first.text == "{" {
      return try inlineAnonymous(document: document, tokens: tokens, variables: variables)
    }

    guard first.kind == .name, first.text == "query" || first.text == "mutation" else {
      throw GatewaySDKError.malformedDocument("expected 'query', 'mutation' or '{' but found '\(first.text)'")
    }

    var cursor = 1
    var operationName = "(anonymous)"
    if cursor < significant.count, significant[cursor].kind == .name {
      operationName = significant[cursor].text
      cursor += 1
    }

    var declarations: [VariableDeclaration] = []
    var definitionRange: Range<String.Index>?
    if cursor < significant.count, significant[cursor].kind == .punctuator, significant[cursor].text == "(" {
      let open = significant[cursor]
      let parsed = try parseVariableDefinitions(significant, from: cursor)
      declarations = parsed.declarations
      definitionRange = open.range.lowerBound..<significant[parsed.closeIndex].range.upperBound
      cursor = parsed.closeIndex + 1
    }

    let bodyVariables = significant[cursor...].filter { $0.kind == .variable }
    try validate(
      declarations: declarations,
      bodyVariables: bodyVariables,
      supplied: variables,
      operation: operationName
    )

    return splice(
      document: document,
      definitionRange: definitionRange,
      bodyVariables: bodyVariables,
      declarations: declarations,
      supplied: variables
    )
  }

  // MARK: - Anonymous documents

  private func inlineAnonymous(
    document: String,
    tokens: [GraphQLToken],
    variables: [String: GatewayJSONValue]
  ) throws -> String {
    if let used = tokens.first(where: { $0.kind == .variable }) {
      throw GatewaySDKError.undeclaredVariable(name: used.variableName ?? used.text)
    }
    if let name = variables.keys.sorted().first {
      throw GatewaySDKError.unknownVariable(operation: "(anonymous)", name: name)
    }
    return document
  }

  // MARK: - Variable definitions

  private struct VariableDeclaration {
    var name: String
    var type: GatewayTypeRef
    var defaultValue: GatewayJSONValue?
  }

  private func parseVariableDefinitions(
    _ tokens: [GraphQLToken],
    from openIndex: Int
  ) throws -> (declarations: [VariableDeclaration], closeIndex: Int) {
    var index = openIndex + 1
    var declarations: [VariableDeclaration] = []
    var seen: Set<String> = []

    while index < tokens.count {
      let token = tokens[index]
      if token.kind == .punctuator, token.text == ")" {
        return (declarations, index)
      }
      guard token.kind == .variable, let name = token.variableName else {
        throw GatewaySDKError.malformedDocument("expected a variable declaration but found '\(token.text)'")
      }
      guard seen.insert(name).inserted else {
        throw GatewaySDKError.malformedDocument("variable '$\(name)' is declared more than once")
      }
      index += 1
      guard index < tokens.count, tokens[index].kind == .punctuator, tokens[index].text == ":" else {
        throw GatewaySDKError.malformedDocument("expected ':' after '$\(name)'")
      }
      index += 1
      let parsedType = try parseType(tokens, from: index)
      index = parsedType.nextIndex

      var defaultValue: GatewayJSONValue?
      if index < tokens.count, tokens[index].kind == .punctuator, tokens[index].text == "=" {
        index += 1
        let parsedValue = try parseConstValue(tokens, from: index)
        defaultValue = parsedValue.value
        index = parsedValue.nextIndex
      }
      declarations.append(
        VariableDeclaration(name: name, type: parsedType.type, defaultValue: defaultValue)
      )
    }
    throw GatewaySDKError.malformedDocument("unterminated variable definition list")
  }

  private func parseType(
    _ tokens: [GraphQLToken],
    from start: Int
  ) throws -> (type: GatewayTypeRef, nextIndex: Int) {
    guard start < tokens.count else {
      throw GatewaySDKError.malformedDocument("expected a type but reached the end of the document")
    }
    var index = start
    var type: GatewayTypeRef
    let token = tokens[index]
    if token.kind == .punctuator, token.text == "[" {
      let inner = try parseType(tokens, from: index + 1)
      index = inner.nextIndex
      guard index < tokens.count, tokens[index].kind == .punctuator, tokens[index].text == "]" else {
        throw GatewaySDKError.malformedDocument("expected ']' closing a list type")
      }
      index += 1
      type = .list(inner.type)
    } else if token.kind == .name {
      index += 1
      type = .named(token.text)
    } else {
      throw GatewaySDKError.malformedDocument("expected a type but found '\(token.text)'")
    }
    if index < tokens.count, tokens[index].kind == .punctuator, tokens[index].text == "!" {
      index += 1
      type = .nonNull(type)
    }
    return (type, index)
  }

  private func parseConstValue(
    _ tokens: [GraphQLToken],
    from start: Int
  ) throws -> (value: GatewayJSONValue, nextIndex: Int) {
    guard start < tokens.count else {
      throw GatewaySDKError.malformedDocument("expected a value but reached the end of the document")
    }
    let token = tokens[start]
    switch token.kind {
    case .variable:
      throw GatewaySDKError.malformedDocument("a variable default value must be constant")
    case .int:
      guard let number = Int(token.text) else {
        throw GatewaySDKError.malformedDocument("integer default '\(token.text)' is out of range")
      }
      return (.int(number), start + 1)
    case .float:
      // `Double("1e999")` is `+inf`, and a default is never type-checked (only supplied
      // values are), so an overflowing literal would otherwise be spliced back in as a
      // bare `inf`.
      guard let number = Double(token.text), number.isFinite else {
        throw GatewaySDKError.malformedDocument("float default '\(token.text)' is not a finite number")
      }
      return (.double(number), start + 1)
    case .string, .blockString:
      return (.string(try Self.decodeStringToken(token)), start + 1)
    case .name:
      switch token.text {
      case "true": return (.bool(true), start + 1)
      case "false": return (.bool(false), start + 1)
      case "null": return (.null, start + 1)
      // Bare enum values carry no JSON counterpart, so they travel as strings.
      default: return (.string(token.text), start + 1)
      }
    case .punctuator:
      if token.text == "[" { return try parseConstList(tokens, from: start) }
      if token.text == "{" { return try parseConstObject(tokens, from: start) }
      throw GatewaySDKError.malformedDocument("unexpected '\(token.text)' in a default value")
    case .comment:
      throw GatewaySDKError.malformedDocument("unexpected comment in a default value")
    }
  }

  private func parseConstList(
    _ tokens: [GraphQLToken],
    from start: Int
  ) throws -> (value: GatewayJSONValue, nextIndex: Int) {
    var index = start + 1
    var elements: [GatewayJSONValue] = []
    while index < tokens.count {
      if tokens[index].kind == .punctuator, tokens[index].text == "]" {
        return (.array(elements), index + 1)
      }
      let element = try parseConstValue(tokens, from: index)
      elements.append(element.value)
      index = element.nextIndex
    }
    throw GatewaySDKError.malformedDocument("unterminated list in a default value")
  }

  private func parseConstObject(
    _ tokens: [GraphQLToken],
    from start: Int
  ) throws -> (value: GatewayJSONValue, nextIndex: Int) {
    var index = start + 1
    var members: [String: GatewayJSONValue] = [:]
    while index < tokens.count {
      if tokens[index].kind == .punctuator, tokens[index].text == "}" {
        return (.object(members), index + 1)
      }
      guard tokens[index].kind == .name else {
        throw GatewaySDKError.malformedDocument("expected an object field name in a default value")
      }
      let key = tokens[index].text
      index += 1
      guard index < tokens.count, tokens[index].kind == .punctuator, tokens[index].text == ":" else {
        throw GatewaySDKError.malformedDocument("expected ':' after '\(key)' in a default value")
      }
      index += 1
      let member = try parseConstValue(tokens, from: index)
      members[key] = member.value
      index = member.nextIndex
    }
    throw GatewaySDKError.malformedDocument("unterminated object in a default value")
  }

  // MARK: - Validation

  private func validate(
    declarations: [VariableDeclaration],
    bodyVariables: [GraphQLToken],
    supplied: [String: GatewayJSONValue],
    operation: String
  ) throws {
    let declaredByName = Dictionary(uniqueKeysWithValues: declarations.map { ($0.name, $0) })
    let usedNames = Set(bodyVariables.compactMap(\.variableName))

    for name in supplied.keys.sorted() where declaredByName[name] == nil {
      throw GatewaySDKError.unknownVariable(operation: operation, name: name)
    }
    for declaration in declarations where !usedNames.contains(declaration.name) {
      throw GatewaySDKError.unusedVariable(operation: operation, name: declaration.name)
    }
    for token in bodyVariables {
      let name = token.variableName ?? token.text
      guard declaredByName[name] == nil else { continue }
      throw GatewaySDKError.undeclaredVariable(name: name)
    }
    for declaration in declarations {
      let value = supplied[declaration.name]
      if declaration.type.isRequired, value == nil || value?.isNull == true,
        declaration.defaultValue == nil {
        throw GatewaySDKError.missingRequiredVariable(operation: operation, name: declaration.name)
      }
      guard let value else { continue }
      try GatewayVariableTypeCheck.check(
        value,
        against: declaration.type,
        name: declaration.name,
        catalog: catalog
      )
    }
  }

  // MARK: - Rewrite

  private func splice(
    document: String,
    definitionRange: Range<String.Index>?,
    bodyVariables: [GraphQLToken],
    declarations: [VariableDeclaration],
    supplied: [String: GatewayJSONValue]
  ) -> String {
    let declaredByName = Dictionary(uniqueKeysWithValues: declarations.map { ($0.name, $0) })
    var edits: [(range: Range<String.Index>, replacement: String)] = []
    if let definitionRange {
      edits.append((definitionRange, ""))
    }
    for token in bodyVariables {
      let name = token.variableName ?? token.text
      let declaration = declaredByName[name]
      let value = supplied[name] ?? declaration?.defaultValue ?? .null
      edits.append(
        (token.range, GraphQLLiteralRenderer.render(value, as: declaration?.type, catalog: catalog))
      )
    }
    edits.sort { $0.range.lowerBound < $1.range.lowerBound }

    var out = ""
    var cursor = document.startIndex
    for edit in edits {
      out += document[cursor..<edit.range.lowerBound]
      out += edit.replacement
      cursor = edit.range.upperBound
    }
    out += document[cursor...]
    return out
  }

  // MARK: - String token decoding

  /// Decodes a `.string` or `.blockString` token into its value.
  static func decodeStringToken(_ token: GraphQLToken) throws -> String {
    if token.kind == .blockString {
      let body = String(token.text.dropFirst(3).dropLast(3))
      return blockStringValue(body.replacingOccurrences(of: "\\\"\"\"", with: "\"\"\""))
    }
    var out = ""
    var index = token.text.index(after: token.text.startIndex)
    let end = token.text.index(before: token.text.endIndex)
    while index < end {
      let character = token.text[index]
      guard character == "\\" else {
        out.append(character)
        index = token.text.index(after: index)
        continue
      }
      index = token.text.index(after: index)
      guard index < end else {
        throw GatewaySDKError.malformedDocument("trailing escape in string \(token.text)")
      }
      let escape = token.text[index]
      index = token.text.index(after: index)
      switch escape {
      case "\"", "\\", "/": out.append(escape)
      case "b": out.append("\u{08}")
      case "f": out.append("\u{0C}")
      case "n": out.append("\n")
      case "r": out.append("\r")
      case "t": out.append("\t")
      case "u":
        var digits = ""
        for _ in 0..<4 where index < end {
          digits.append(token.text[index])
          index = token.text.index(after: index)
        }
        guard digits.count == 4, let code = UInt32(digits, radix: 16),
          let scalar = Unicode.Scalar(code) else {
          throw GatewaySDKError.malformedDocument("invalid unicode escape '\\u\(digits)'")
        }
        out.unicodeScalars.append(scalar)
      default:
        throw GatewaySDKError.malformedDocument("unknown escape '\\\(escape)'")
      }
    }
    return out
  }

  /// The spec's block-string value algorithm: strip the common indentation and the
  /// leading/trailing blank lines.
  private static func blockStringValue(_ body: String) -> String {
    var lines = body.components(separatedBy: "\n").map { $0.replacingOccurrences(of: "\r", with: "") }
    var commonIndent: Int?
    for line in lines.dropFirst() {
      let indent = line.prefix { $0 == " " || $0 == "\t" }.count
      guard indent < line.count else { continue }
      commonIndent = min(commonIndent ?? indent, indent)
    }
    if let commonIndent, commonIndent > 0 {
      lines = [lines[0]] + lines.dropFirst().map { String($0.dropFirst(min(commonIndent, $0.count))) }
    }
    while let first = lines.first, first.allSatisfy({ $0 == " " || $0 == "\t" }) {
      lines.removeFirst()
    }
    while let last = lines.last, last.allSatisfy({ $0 == " " || $0 == "\t" }) {
      lines.removeLast()
    }
    return lines.joined(separator: "\n")
  }
}
