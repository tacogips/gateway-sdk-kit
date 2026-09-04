import Foundation

/// One lexical token, carrying its exact range in the source string.
///
/// The ranges are what makes byte-preserving rewriting possible: the inliner splices
/// the original text rather than re-printing a parsed document.
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
/// inliner can see (and preserve) them.
public enum GraphQLLexer {
  public static func tokenize(_ source: String) throws -> [GraphQLToken] {
    var tokens: [GraphQLToken] = []
    var index = source.startIndex

    while index < source.endIndex {
      let character = source[index]
      if character == " " || character == "\t" || character == "\n" || character == "\r"
        || character == "," || character == "\u{FEFF}" {
        index = source.index(after: index)
        continue
      }
      if character == "#" {
        let start = index
        while index < source.endIndex, source[index] != "\n", source[index] != "\r" {
          index = source.index(after: index)
        }
        tokens.append(token(.comment, source, start, index))
        continue
      }
      if character == "\"" {
        tokens.append(try lexString(source, &index))
        continue
      }
      if character == "$" {
        let start = index
        index = source.index(after: index)
        let nameStart = index
        scanName(source, &index)
        guard nameStart < index else {
          throw GatewaySDKError.malformedDocument("expected a variable name at offset \(offset(source, start))")
        }
        tokens.append(token(.variable, source, start, index))
        continue
      }
      if isNameStart(character) {
        let start = index
        scanName(source, &index)
        tokens.append(token(.name, source, start, index))
        continue
      }
      if character == "-" || character.isNumber {
        tokens.append(try lexNumber(source, &index))
        continue
      }
      if let punctuator = lexPunctuator(source, &index) {
        tokens.append(punctuator)
        continue
      }
      throw GatewaySDKError.malformedDocument(
        "unexpected character '\(character)' at offset \(offset(source, index))"
      )
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
      throw GatewaySDKError.malformedDocument(
        "unterminated block string starting at offset \(offset(source, start))"
      )
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
      if character == "\n" || character == "\r" { break }
      if character == "\"" {
        cursor = source.index(after: cursor)
        index = cursor
        return token(.string, source, start, cursor)
      }
      cursor = source.index(after: cursor)
    }
    throw GatewaySDKError.malformedDocument("unterminated string starting at offset \(offset(source, start))")
  }

  private static func lexNumber(_ source: String, _ index: inout String.Index) throws -> GraphQLToken {
    let start = index
    if source[index] == "-" { index = source.index(after: index) }
    let digitsStart = index
    scanDigits(source, &index)
    guard digitsStart < index else {
      throw GatewaySDKError.malformedDocument("expected digits at offset \(offset(source, start))")
    }

    var isFloat = false
    if index < source.endIndex, source[index] == "." {
      isFloat = true
      index = source.index(after: index)
      let fractionStart = index
      scanDigits(source, &index)
      guard fractionStart < index else {
        throw GatewaySDKError.malformedDocument("expected digits after '.' at offset \(offset(source, index))")
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
        throw GatewaySDKError.malformedDocument("expected exponent digits at offset \(offset(source, index))")
      }
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

  private static func offset(_ source: String, _ index: String.Index) -> Int {
    source.distance(from: source.startIndex, to: index)
  }
}
