import Foundation

/// Every error the kit throws. The first eight cases are the package brief's list; the
/// remainder cover features the brief specifies without naming an error (the inliner's
/// declared-unused / used-undeclared rules and the throwing `parse` entry points).
public enum GatewaySDKError: Error, Sendable, Equatable, CustomStringConvertible {
  case unknownOperation(name: String)
  case unknownVariable(operation: String, name: String)
  case missingRequiredVariable(operation: String, name: String)
  case invalidSelectionPath(path: String)
  case commandOperationNeedsArgv(name: String)
  case graphQLOperationNeedsDocument(name: String)
  case invalidPattern(String)
  case variableTypeMismatch(name: String, expected: String, actual: String)
  case unusedVariable(operation: String, name: String)
  case undeclaredVariable(name: String)
  case malformedDocument(String)
  case invalidTypeReference(String)
  case invalidJSON(String)
  case invalidJSONValue(String)

  public var description: String {
    switch self {
    case .unknownOperation(let name):
      return "unknown operation '\(name)'"
    case .unknownVariable(let operation, let name):
      return "operation '\(operation)' has no variable '\(name)'"
    case .missingRequiredVariable(let operation, let name):
      return "operation '\(operation)' requires variable '\(name)'"
    case .invalidSelectionPath(let path):
      return "invalid selection path '\(path)'"
    case .commandOperationNeedsArgv(let name):
      return "operation '\(name)' is a command; build argv with GatewayArgvBuilder"
    case .graphQLOperationNeedsDocument(let name):
      return "operation '\(name)' is a GraphQL operation; build a document with GatewayDocumentBuilder"
    case .invalidPattern(let message):
      return "invalid search pattern: \(message)"
    case .variableTypeMismatch(let name, let expected, let actual):
      return "variable '\(name)' expects \(expected) but got \(actual)"
    case .unusedVariable(let operation, let name):
      return "operation '\(operation)' declares variable '\(name)' but never uses it"
    case .undeclaredVariable(let name):
      return "variable '\(name)' is used but not declared"
    case .malformedDocument(let message):
      return "malformed GraphQL document: \(message)"
    case .invalidTypeReference(let text):
      return "invalid type reference '\(text)'"
    case .invalidJSON(let message):
      return "invalid JSON: \(message)"
    case .invalidJSONValue(let message):
      return "invalid JSON value: \(message)"
    }
  }
}
