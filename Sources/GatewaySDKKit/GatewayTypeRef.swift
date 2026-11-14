import Foundation

/// A GraphQL type reference: a named type wrapped in any number of list and non-null
/// modifiers.
///
/// Wire format: a single JSON string holding the GraphQL spelling (`"[Foo!]!"`), so
/// catalog JSON stays readable and hand-editable.
public indirect enum GatewayTypeRef: Codable, Sendable, Equatable, Hashable {
  case named(String)
  case list(GatewayTypeRef)
  case nonNull(GatewayTypeRef)

  // MARK: - Helpers

  /// The innermost named type, ignoring every list and non-null wrapper.
  public var namedTypeName: String {
    switch self {
    case .named(let name): return name
    case .list(let inner): return inner.namedTypeName
    case .nonNull(let inner): return inner.namedTypeName
    }
  }

  /// True when the outermost modifier is non-null.
  public var isRequired: Bool {
    if case .nonNull = self { return true }
    return false
  }

  /// True when a list modifier appears anywhere below the outer non-null.
  public var isList: Bool {
    switch self {
    case .named: return false
    case .list: return true
    case .nonNull(let inner): return inner.isList
    }
  }

  /// The reference with its outer non-null removed, if present.
  public var unwrappingNonNull: GatewayTypeRef {
    if case .nonNull(let inner) = self { return inner }
    return self
  }

  /// The element type of a list reference (after unwrapping an outer non-null).
  public var listElementType: GatewayTypeRef? {
    if case .list(let element) = unwrappingNonNull { return element }
    return nil
  }

  /// The GraphQL spelling, e.g. `[Foo!]!`.
  public var graphQLString: String {
    switch self {
    case .named(let name): return name
    case .list(let inner): return "[\(inner.graphQLString)]"
    case .nonNull(let inner): return "\(inner.graphQLString)!"
    }
  }

  // MARK: - Parsing

  /// Parses a GraphQL type spelling such as `ID!`, `[Int]`, or `[Foo!]!`.
  public static func parse(_ graphQL: String) throws -> GatewayTypeRef {
    var parser = Parser(source: Array(graphQL.unicodeScalars), original: graphQL)
    let result = try parser.parseType()
    parser.skipWhitespace()
    guard parser.isAtEnd else {
      throw GatewaySDKError.invalidTypeReference(graphQL)
    }
    return result
  }

  private struct Parser {
    let source: [Unicode.Scalar]
    let original: String
    var index = 0

    var isAtEnd: Bool { index >= source.count }

    mutating func skipWhitespace() {
      while index < source.count, source[index] == " " || source[index] == "\t" {
        index += 1
      }
    }

    mutating func parseType() throws -> GatewayTypeRef {
      skipWhitespace()
      guard index < source.count else {
        throw GatewaySDKError.invalidTypeReference(original)
      }
      var result: GatewayTypeRef
      if source[index] == "[" {
        index += 1
        let inner = try parseType()
        skipWhitespace()
        guard index < source.count, source[index] == "]" else {
          throw GatewaySDKError.invalidTypeReference(original)
        }
        index += 1
        result = .list(inner)
      } else {
        result = .named(try parseName())
      }
      skipWhitespace()
      // Repeated `!` is not legal GraphQL; one bang binds to the type just parsed.
      if index < source.count, source[index] == "!" {
        index += 1
        result = .nonNull(result)
      }
      return result
    }

    mutating func parseName() throws -> String {
      let start = index
      while index < source.count, Parser.isNameScalar(source[index], isFirst: index == start) {
        index += 1
      }
      guard index > start else {
        throw GatewaySDKError.invalidTypeReference(original)
      }
      var name = ""
      for scalar in source[start..<index] {
        name.unicodeScalars.append(scalar)
      }
      return name
    }

    static func isNameScalar(_ scalar: Unicode.Scalar, isFirst: Bool) -> Bool {
      switch scalar {
      case "A"..."Z", "a"..."z", "_": return true
      case "0"..."9": return !isFirst
      default: return false
      }
    }
  }

  // MARK: - Codable

  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    let text = try container.decode(String.self)
    do {
      self = try GatewayTypeRef.parse(text)
    } catch {
      throw DecodingError.dataCorruptedError(
        in: container,
        debugDescription: "invalid type reference '\(text)'"
      )
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(graphQLString)
  }
}
