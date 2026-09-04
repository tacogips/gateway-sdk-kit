import Foundation

/// Deterministic admission policy for caller-supplied schema-search patterns.
///
/// Schema search evaluates a pattern against every searchable catalog label. This
/// deliberately conservative subset bounds pattern complexity before Swift Regex
/// compiles or matches it.
enum GatewaySchemaSearchPattern {
  static let maximumUTF8Length = 256

  static func validate(_ pattern: String) throws {
    guard pattern.utf8.count <= maximumUTF8Length else {
      throw invalidPattern("search pattern exceeds 256 UTF-8 bytes")
    }

    var groupDepth = 0
    var inCharacterClass = false
    var escaped = false
    var firstCharacterInGroup = false
    var previousWasQuantifier = false
    var previousWasClosedGroup = false
    var hasOptionalQuantifier = false

    for character in pattern {
      if escaped {
        if !inCharacterClass && isBackreferencePrefix(character) {
          throw invalidPattern("search pattern does not support backreferences")
        }
        escaped = false
        firstCharacterInGroup = false
        previousWasQuantifier = false
        previousWasClosedGroup = false
        continue
      }

      if firstCharacterInGroup {
        if character == "?" {
          throw invalidPattern("search pattern does not support extension groups")
        }
        firstCharacterInGroup = false
      }

      if character == "\\" {
        escaped = true
        continue
      }

      if inCharacterClass {
        if character == "]" {
          inCharacterClass = false
        }
        continue
      }

      switch character {
      case "[":
        inCharacterClass = true
        previousWasQuantifier = false
        previousWasClosedGroup = false
      case "]":
        throw invalidPattern("search pattern has an unmatched closing delimiter")
      case ")" where groupDepth == 0:
        throw invalidPattern("search pattern has an unmatched closing delimiter")
      case "(":
        groupDepth += 1
        firstCharacterInGroup = true
        previousWasQuantifier = false
        previousWasClosedGroup = false
      case ")":
        groupDepth -= 1
        previousWasQuantifier = false
        previousWasClosedGroup = true
      case "|" where groupDepth > 0:
        throw invalidPattern("search pattern does not support grouped alternation")
      case "{", "}":
        throw invalidPattern("search pattern does not support counted quantifiers")
      case "*", "+":
        throw invalidPattern("search pattern does not support unbounded quantifiers")
      case "?":
        guard !previousWasClosedGroup else {
          throw invalidPattern("search pattern does not support quantified groups")
        }
        guard !previousWasQuantifier, !hasOptionalQuantifier else {
          throw invalidPattern("search pattern allows at most one optional quantifier")
        }
        hasOptionalQuantifier = true
        previousWasQuantifier = true
        previousWasClosedGroup = false
      default:
        previousWasQuantifier = false
        previousWasClosedGroup = false
      }
    }

    guard !escaped, !inCharacterClass, groupDepth == 0 else {
      throw invalidPattern("search pattern syntax is incomplete")
    }
  }

  private static func invalidPattern(_ reason: String) -> GatewaySDKError {
    .invalidPattern(reason)
  }

  private static func isBackreferencePrefix(_ character: Character) -> Bool {
    (character.isASCII && character.isNumber) || character == "k" || character == "g"
  }
}
