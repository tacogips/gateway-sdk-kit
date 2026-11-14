import Foundation
import Testing
@testable import GatewaySDKKit

private struct NumericResolverError: GatewayResolverError {
  let code: String
  let message = "provider request failed"
  let diagnostics: GatewayErrorDiagnostics?
}

private actor DistinctFailures {
  private var count = 0
  func next() -> Int { count += 1; return 400 + count }
}

@Suite("Numeric error diagnostics")
struct ErrorDiagnosticsTests {
  @Test func validatesBoundsAndDropsUnrecognizedFields() throws {
    #expect(GatewayErrorDiagnostics(httpStatus: 99, providerErrorCode: -1).isEmpty)
    #expect(GatewayErrorDiagnostics(httpStatus: 600, providerErrorCode: 100_000).isEmpty)
    for status in [100, 599] {
      for code in [0, 99_999] {
        let value = GatewayErrorDiagnostics(httpStatus: status, providerErrorCode: code)
        #expect(try JSONDecoder().decode(GatewayErrorDiagnostics.self, from: JSONEncoder().encode(value)) == value)
      }
    }
    let hostile = Data(#"{"httpStatus":"SECRET","providerErrorCode":100000,"token":"SECRET"}"#.utf8)
    let decoded = try JSONDecoder().decode(GatewayErrorDiagnostics.self, from: hostile)
    #expect(decoded.isEmpty)
    let encoded = try #require(String(data: try JSONEncoder().encode(decoded), encoding: .utf8))
    #expect(!encoded.contains("SECRET"))
    for invalid in ["true", "false", "403.5", "\"403\"", "null", "[]", "{}"] {
      let data = Data("{\"httpStatus\":\(invalid),\"providerErrorCode\":17}".utf8)
      let value = try JSONDecoder().decode(GatewayErrorDiagnostics.self, from: data)
      #expect(value.httpStatus == nil)
      #expect(value.providerErrorCode == 17)
    }
  }

  @Test func envelopeParsesBothShapesAndCodableRoundTrips() throws {
    let error = #"{"message":"failed","code":"PROVIDER","path":["alias"],"extensions":{"httpStatus":403,"providerErrorCode":453,"token":"SECRET"}}"#
    for json in ["{\"data\":null,\"errors\":[\(error)]}", "{\"ok\":false,\"error\":\(error)}"] {
      let envelope = GatewayEnvelope(parsingCLIOutput: json, exitCode: 1)
      #expect(envelope.errors.first?.diagnostics == .init(httpStatus: 403, providerErrorCode: 453))
      let encoded = try JSONEncoder().encode(envelope.errors)
      let text = try #require(String(data: encoded, encoding: .utf8))
      #expect(!text.contains("SECRET"))
      #expect(try JSONDecoder().decode([GatewayEnvelopeError].self, from: encoded) == envelope.errors)
    }
    let legacy = GatewayEnvelopeError(message: "failed", code: "OLD", path: ["alias"])
    let json = try #require(String(data: try JSONEncoder().encode(legacy), encoding: .utf8))
    #expect(!json.contains("extensions"))
    #expect(try JSONDecoder().decode(GatewayEnvelopeError.self, from: Data(json.utf8)) == legacy)
  }

  @Test func identicalArgumentsAndConcurrentAliasesKeepTheirOwnDiagnostics() async throws {
    let failures = DistinctFailures()
    let runtime = try GatewayGraphQLRuntime(catalog: FixtureCatalogs.runtime, resolvers: [
      "labels": { _, _ in
        let status = await failures.next()
        throw NumericResolverError(code: "FAIL_\(status)", diagnostics: .init(httpStatus: status, providerErrorCode: status + 100))
      },
      "threads": { _, _ in .null },
      "sendMessage": { _, _ in .null }
    ])
    let envelope = await runtime.execute(document: #"{ a: labels(accountId: "same") { id } b: labels(accountId: "same") { id } }"#, context: .init())
    #expect(envelope.errors.count == 2)
    #expect(Set(envelope.errors.compactMap { $0.path?.first }) == Set(["a", "b"]))
    #expect(Set(envelope.errors.compactMap { $0.diagnostics?.httpStatus }) == Set([401, 402]))
    for error in envelope.errors {
      let status = try #require(error.diagnostics?.httpStatus)
      #expect(error.code == "FAIL_\(status)")
      #expect(error.diagnostics?.providerErrorCode == status + 100)
    }
    #expect(GatewayEnvelope(parsingCLIOutput: envelope.rawOutput, exitCode: 1).errors == envelope.errors)
  }
}
