import Foundation

enum GatewayGraphQLLimits {
  static let documentBytes = 262_144
  static let tokens = 20_000
  static let depth = 32
  static let selections = 1_000
  static let rootFields = 64
  static let containerEntries = 1_000
  static let inputValueNodes = 10_000
  static let resolverResultNodes = 10_000
  static let concurrentQueryResolvers = 8

  static func message(_ name: String, _ maximum: Int) -> String {
    "resource limit exceeded: \(name) maximum \(maximum)"
  }
}
