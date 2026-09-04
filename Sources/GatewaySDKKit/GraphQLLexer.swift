import Foundation

/// One lexical token, carrying its exact range in the source string.
///
/// Ranges preserve source locations for parser diagnostics.
public struct GraphQLToken: Sendable, Equatable {
  public enum Kind: Sendable, Equatable {
    case punctuator
    case name
    case variable
    case int
    case float
    case string
    case blockString
    case comment
  }

  public var kind: Kind
  /// The raw source slice, including quotes for strings and `#` for comments.
  public var text: String
  public var range: Range<String.Index>

  public init(kind: Kind, text: String, range: Range<String.Index>) {
    self.kind = kind
    self.text = text
    self.range = range
  }

  /// A variable token's name without the leading `$`.
  public var variableName: String? {
    guard kind == .variable else { return nil }
    return String(text.dropFirst())
  }
}

/// A GraphQL lexer covering the whole spec token grammar.
///
/// Whitespace, commas and the BOM are ignored; comments are kept as tokens so the
/// parsers can retain source-aware comments when needed.
public enum GraphQLLexer {
  public static func tokenize(_ source: String) throws -> [GraphQLToken] {
    try tokenize(source, maximumTokens: nil)
  }

  static func tokenize(_ source: String, maximumTokens: Int?) throws -> [GraphQLToken] {
    var tokens: [GraphQLToken] = []
    var index = source.startIndex

    while index < source.endIndex {
      let character = source[index]
      if character == " " || character == "\t" || isLineTerminator(character)
        || character == "," || character == "\u{FEFF}" {
        index = source.index(after: index)
        continue
      }
      if character == "#" {
        let start = index
        while index < source.endIndex, !isLineTerminator(source[index]) {
          index = source.index(after: index)
        }
        try append(token(.comment, source, start, index), to: &tokens, maximum: maximumTokens, source: source)
        continue
      }
      if character == "\"" {
        try append(lexString(source, &index), to: &tokens, maximum: maximumTokens, source: source)
        continue
      }
      if character == "$" {
        let start = index
        index = source.index(after: index)
        guard index < source.endIndex, isNameStart(source[index]) else {
          throw syntax("expected a variable name", source: source, at: start)
        }
        scanName(source, &index)
        try append(token(.variable, source, start, index), to: &tokens, maximum: maximumTokens, source: source)
        continue
      }
      if isNameStart(character) {
        let start = index
        scanName(source, &index)
        try append(token(.name, source, start, index), to: &tokens, maximum: maximumTokens, source: source)
        continue
      }
      if character == "-" || character.isNumber {
        try append(lexNumber(source, &index), to: &tokens, maximum: maximumTokens, source: source)
        continue
      }
      if let punctuator = lexPunctuator(source, &index) {
        try append(punctuator, to: &tokens, maximum: maximumTokens, source: source)
        continue
      }
      throw syntax("unexpected character '\(character)'", source: source, at: index)
    }
    return tokens
  }

  // MARK: - Token scanners

  private static func lexString(_ source: String, _ index: inout String.Index) throws -> GraphQLToken {
    let start = index
    if source[index...].hasPrefix("\"\"\"") {
      var cursor = source.index(index, offsetBy: 3)
      while cursor < source.endIndex {
        if source[cursor] == "\\", source[cursor...].hasPrefix("\\\"\"\"") {
          cursor = source.index(cursor, offsetBy: 4)
          continue
        }
        if source[cursor...].hasPrefix("\"\"\"") {
          cursor = source.index(cursor, offsetBy: 3)
          index = cursor
          return token(.blockString, source, start, cursor)
        }
        cursor = source.index(after: cursor)
      }
      throw syntax("unterminated block string", source: source, at: start)
    }

    var cursor = source.index(after: index)
    while cursor < source.endIndex {
      let character = source[cursor]
      if character == "\\" {
        let next = source.index(after: cursor)
        guard next < source.endIndex else { break }
        cursor = source.index(after: next)
        continue
      }
      if isC0Control(character) {
        throw syntax("raw control character in string", source: source, at: cursor)
      }
      if character == "\"" {
        cursor = source.index(after: cursor)
        index = cursor
        return token(.string, source, start, cursor)
      }
      cursor = source.index(after: cursor)
    }
    throw syntax("unterminated string", source: source, at: start)
  }

  private static func lexNumber(_ source: String, _ index: inout String.Index) throws -> GraphQLToken {
    let start = index
    if source[index] == "-" { index = source.index(after: index) }
    let digitsStart = index
    scanDigits(source, &index)
    guard digitsStart < index else {
      throw syntax("expected digits", source: source, at: start)
    }
    if source[digitsStart] == "0", index > source.index(after: digitsStart) {
      throw syntax("leading zeroes are not allowed", source: source, at: start)
    }

    var isFloat = false
    if index < source.endIndex, source[index] == "." {
      isFloat = true
      index = source.index(after: index)
      let fractionStart = index
      scanDigits(source, &index)
      guard fractionStart < index else {
        throw syntax("expected digits after '.'", source: source, at: index)
      }
    }
    if index < source.endIndex, source[index] == "e" || source[index] == "E" {
      isFloat = true
      index = source.index(after: index)
      if index < source.endIndex, source[index] == "+" || source[index] == "-" {
        index = source.index(after: index)
      }
      let exponentStart = index
      scanDigits(source, &index)
      guard exponentStart < index else {
        throw syntax("expected exponent digits", source: source, at: index)
      }
    }
    if index < source.endIndex, isNameStart(source[index]) {
      throw syntax("invalid number/name boundary", source: source, at: index)
    }
    return token(isFloat ? .float : .int, source, start, index)
  }

  private static let punctuators: Set<Character> = ["!", "(", ")", ":", "=", "@", "[", "]", "{", "}", "|", "&"]

  private static func lexPunctuator(_ source: String, _ index: inout String.Index) -> GraphQLToken? {
    let start = index
    if source[index...].hasPrefix("...") {
      index = source.index(index, offsetBy: 3)
      return token(.punctuator, source, start, index)
    }
    guard punctuators.contains(source[index]) else { return nil }
    index = source.index(after: index)
    return token(.punctuator, source, start, index)
  }

  // MARK: - Character helpers

  private static func isNameStart(_ character: Character) -> Bool {
    character == "_" || (character.isASCII && character.isLetter)
  }

  private static func isLineTerminator(_ character: Character) -> Bool {
    character == "\n" || character == "\r" || character == "\r\n"
  }

  private static func isC0Control(_ character: Character) -> Bool {
    character.unicodeScalars.contains { $0.value <= 0x1F }
  }

  private static func isNameContinuation(_ character: Character) -> Bool {
    isNameStart(character) || (character.isASCII && character.isNumber)
  }

  private static func scanName(_ source: String, _ index: inout String.Index) {
    while index < source.endIndex, isNameContinuation(source[index]) {
      index = source.index(after: index)
    }
  }

  private static func scanDigits(_ source: String, _ index: inout String.Index) {
    while index < source.endIndex, source[index].isASCII, source[index].isNumber {
      index = source.index(after: index)
    }
  }

  private static func token(
    _ kind: GraphQLToken.Kind,
    _ source: String,
    _ start: String.Index,
    _ end: String.Index
  ) -> GraphQLToken {
    GraphQLToken(kind: kind, text: String(source[start..<end]), range: start..<end)
  }

  private static func append(
    _ token: GraphQLToken,
    to tokens: inout [GraphQLToken],
    maximum: Int?,
    source: String
  ) throws {
    if let maximum, tokens.count >= maximum {
      throw syntax(
        "resource limit exceeded: tokens maximum \(maximum)", source: source, at: token.range.lowerBound
      )
    }
    tokens.append(token)
  }

  private static func syntax(_ message: String, source: String, at index: String.Index) -> GatewaySDKError {
    let position = sourcePosition(source, index)
    return .syntax(message: message, line: position.line, column: position.column)
  }

  static func sourcePosition(_ source: String, _ index: String.Index) -> (line: Int, column: Int) {
    var line = 1
    var column = 1
    var cursor = source.startIndex
    while cursor < index {
      if isLineTerminator(source[cursor]) {
        line += 1
        column = 1
        cursor = source.index(after: cursor)
      } else {
        column += 1
        cursor = source.index(after: cursor)
      }
    }
    return (line, column)
  }
}
