import Foundation
import Testing
@testable import GatewaySDKKit

@Suite("Gateway envelope")
struct EnvelopeTests {
  @Test("shape A with errors, paths and extensions.requestId")
  func shapeAFull() {
    let stdout = #"""
      {"data":{"threads":null},"errors":[{"message":"boom","code":"E_BOOM","path":["threads",0,"id"]},
      {"message":"other","extensions":{"code":"E_OTHER"}},{}],"extensions":{"requestId":"req-1"}}
      """#
    let envelope = GatewayEnvelope(parsingCLIOutput: stdout, exitCode: 1)
    #expect(envelope.data == .object(["threads": .null]))
    #expect(envelope.errors == [
      GatewayEnvelopeError(message: "boom", code: "E_BOOM", path: ["threads", "0", "id"]),
      GatewayEnvelopeError(message: "other", code: "E_OTHER"),
      GatewayEnvelopeError(message: "unknown error")
    ])
    #expect(envelope.requestId == "req-1")
    #expect(envelope.exitCode == 1)
    #expect(envelope.rawOutput == stdout)
  }

  @Test("shape A with data only")
  func shapeADataOnly() {
    let envelope = GatewayEnvelope(parsingCLIOutput: #"{"data":{"ping":"pong"}}"#, exitCode: 0)
    #expect(envelope.data == .object(["ping": .string("pong")]))
    #expect(envelope.errors.isEmpty)
    #expect(envelope.requestId == nil)
  }

  @Test("shape A with a null data member reports no data")
  func shapeANullData() {
    let envelope = GatewayEnvelope(parsingCLIOutput: #"{"data":null,"errors":[]}"#, exitCode: 1)
    #expect(envelope.data == nil)
    #expect(envelope.errors.isEmpty)
  }

  @Test("shape B with ok true")
  func shapeBOk() {
    let envelope = GatewayEnvelope(parsingCLIOutput: #"{"ok":true,"data":{"files":[]}}"#, exitCode: 0)
    #expect(envelope.data == .object(["files": .array([])]))
    #expect(envelope.errors.isEmpty)
    #expect(envelope.exitCode == 0)
  }

  @Test("shape B with ok false and an error object")
  func shapeBFailure() {
    let envelope = GatewayEnvelope(
      parsingCLIOutput: #"{"ok":false,"data":null,"error":{"code":"E_AUTH","message":"denied"}}"#,
      exitCode: 3
    )
    #expect(envelope.data == nil)
    #expect(envelope.errors == [GatewayEnvelopeError(message: "denied", code: "E_AUTH")])
    #expect(envelope.exitCode == 3)
  }

  @Test("shape B with ok false and no error object still reports one error")
  func shapeBFailureWithoutErrorObject() {
    let envelope = GatewayEnvelope(parsingCLIOutput: #"{"ok":false}"#, exitCode: 1)
    #expect(envelope.errors == [GatewayEnvelopeError(message: "unknown error")])
  }

  @Test("shape B with ok true but an error object present reports the error")
  func shapeBOkWithError() {
    let envelope = GatewayEnvelope(parsingCLIOutput: #"{"ok":true,"error":{"message":"warned"}}"#, exitCode: 0)
    #expect(envelope.errors == [GatewayEnvelopeError(message: "warned")])
  }

  @Test(
    "unparsable, empty, non-object and shapeless output become one error carrying the raw text",
    arguments: ["not json at all", "", "  ", "[1,2]", "\"just a string\"", "null", #"{"unrelated":1}"#]
  )
  func garbage(_ stdout: String) {
    let envelope = GatewayEnvelope(parsingCLIOutput: stdout, exitCode: 127)
    #expect(envelope.data == nil)
    #expect(envelope.errors == [GatewayEnvelopeError(message: stdout)])
    #expect(envelope.requestId == nil)
    #expect(envelope.exitCode == 127)
    #expect(envelope.rawOutput == stdout)
  }

  @Test("failure wraps a thrown error's description")
  func failure() {
    let envelope = GatewayEnvelope.failure(GatewaySDKError.unknownOperation(name: "nope"), exitCode: 2)
    #expect(envelope.data == nil)
    #expect(envelope.errors == [GatewayEnvelopeError(message: "unknown operation 'nope'")])
    #expect(envelope.exitCode == 2)
    #expect(envelope.rawOutput.isEmpty)
  }

  @Test("the envelope round trips through Codable")
  func codable() throws {
    let envelope = GatewayEnvelope(
      data: .object(["a": .int(1)]),
      errors: [GatewayEnvelopeError(message: "m", code: "c", path: ["p"])],
      requestId: "r",
      exitCode: 4,
      rawOutput: "raw"
    )
    let data = try JSONEncoder().encode(envelope)
    #expect(try JSONDecoder().decode(GatewayEnvelope.self, from: data) == envelope)
  }
}
