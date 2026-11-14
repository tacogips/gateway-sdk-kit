import Foundation
import Testing
@testable import GatewaySDKKit

/// Loads the JSON fixture catalogs through `Bundle.module`, which also regression-tests
/// the pinned catalog wire format on every run.
enum FixtureCatalogs {
  static let gmail: GatewaySchemaCatalog = load("gmail-catalog")
  static let documents: GatewaySchemaCatalog = load("documents-command-catalog")
  static let runtime: GatewaySchemaCatalog = load("runtime-catalog")

  static func load(_ name: String) -> GatewaySchemaCatalog {
    guard let url = Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: "json") else {
      fatalError("missing fixture catalog '\(name).json'")
    }
    do {
      return try JSONDecoder().decode(GatewaySchemaCatalog.self, from: Data(contentsOf: url))
    } catch {
      fatalError("fixture catalog '\(name).json' failed to decode: \(error)")
    }
  }
}
