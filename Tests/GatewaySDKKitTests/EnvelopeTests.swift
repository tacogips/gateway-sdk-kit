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

  @Test("an errors member that is present but not an array degrades to one raw-text error")
  func shapeANonArrayErrors() {
    // Falling through with an empty list would report a failed call as an empty success.
    for stdout in [
      #"{"data":null,"errors":"boom"}"#,
      #"{"data":null,"errors":{"message":"boom"}}"#,
      #"{"errors":7}"#
    ] {
      let envelope = GatewayEnvelope(parsingCLIOutput: stdout, exitCode: 1)
      #expect(envelope.errors == [GatewayEnvelopeError(message: stdout)])
      #expect(envelope.data == nil)
      #expect(envelope.exitCode == 1)
      #expect(envelope.rawOutput == stdout)
    }
  }

  @Test("an explicitly null errors member is treated as no errors")
  func shapeANullErrors() {
    let envelope = GatewayEnvelope(parsingCLIOutput: #"{"data":{"a":1},"errors":null}"#, exitCode: 0)
    #expect(envelope.errors.isEmpty)
    #expect(envelope.data == .object(["a": .int(1)]))
  }

  @Test("an ok member that is present but not a boolean degrades to one raw-text error")
  func shapeBNonBooleanOk() {
    // `ok` non-boolean means shape B in intent but not in form. Falling through to
    // shape-A parsing would leave the singular `error` member unread and report a
    // failed call as an empty success.
    for stdout in [
      #"{"ok":"false","data":null,"error":{"message":"boom","code":"E"}}"#,
      #"{"ok":null,"data":null,"error":{"message":"boom"}}"#,
      #"{"ok":0,"data":null,"error":{"message":"boom"}}"#,
      #"{"ok":["false"],"error":{"message":"boom"}}"#
    ] {
      let envelope = GatewayEnvelope(parsingCLIOutput: stdout, exitCode: 1)
      #expect(envelope.errors == [GatewayEnvelopeError(message: stdout)])
      #expect(envelope.exitCode == 1)
      #expect(envelope.rawOutput == stdout)
    }
  }

  @Test("a shape-A payload carrying a singular error member degrades rather than losing it")
  func shapeAWithSingularError() {
    // Decision: degrade, not consume. A singular `error` belongs to shape B, so seeing
    // it here means the payload matches neither shape cleanly; the raw text carries the
    // message either way. `data` is still surfaced when present.
    let withoutData = #"{"data":null,"errors":[],"error":{"message":"boom"}}"#
    let first = GatewayEnvelope(parsingCLIOutput: withoutData, exitCode: 1)
    #expect(first.errors == [GatewayEnvelopeError(message: withoutData)])
    #expect(first.data == nil)

    let withData = #"{"data":{"a":1},"error":{"message":"boom"}}"#
    let second = GatewayEnvelope(parsingCLIOutput: withData, exitCode: 1)
    #expect(second.errors == [GatewayEnvelopeError(message: withData)])
    #expect(second.data == .object(["a": .int(1)]))

    // A populated errors array wins; the singular member does not add a second entry.
    let both = #"{"data":null,"errors":[{"message":"real"}],"error":{"message":"boom"}}"#
    let third = GatewayEnvelope(parsingCLIOutput: both, exitCode: 1)
    #expect(third.errors == [GatewayEnvelopeError(message: "real")])

    // An explicitly null singular error is not a failure signal.
    let nullError = #"{"data":{"a":1},"error":null}"#
    let fourth = GatewayEnvelope(parsingCLIOutput: nullError, exitCode: 0)
    #expect(fourth.errors.isEmpty)
    #expect(fourth.data == .object(["a": .int(1)]))
  }

  @Test("well-formed shape-B and shape-A payloads are unaffected by the degrade rules")
  func degradeRulesDoNotDisturbWellFormedPayloads() {
    // Controls for the two rules above: every documented shape still parses as before.
    let okTrue = GatewayEnvelope(parsingCLIOutput: #"{"ok":true,"data":{"files":[]}}"#, exitCode: 0)
    #expect(okTrue.errors.isEmpty)
    #expect(okTrue.data == .object(["files": .array([])]))

    let okFalse = GatewayEnvelope(
      parsingCLIOutput: #"{"ok":false,"data":null,"error":{"code":"E_AUTH","message":"denied"}}"#,
      exitCode: 3
    )
    #expect(okFalse.errors == [GatewayEnvelopeError(message: "denied", code: "E_AUTH")])

    let shapeA = GatewayEnvelope(
      parsingCLIOutput: #"{"data":{"t":null},"errors":[{"message":"boom"}],"extensions":{"requestId":"r"}}"#,
      exitCode: 1
    )
    #expect(shapeA.errors == [GatewayEnvelopeError(message: "boom")])
    #expect(shapeA.requestId == "r")

    let dataOnly = GatewayEnvelope(parsingCLIOutput: #"{"data":{"ping":"pong"}}"#, exitCode: 0)
    #expect(dataOnly.errors.isEmpty)
    #expect(dataOnly.data == .object(["ping": .string("pong")]))
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
