import Foundation
import Testing
@testable import GatewaySDKKit

/// An exhaustive matrix over every combination of the four members that decide how
/// `GatewayEnvelope(parsingCLIOutput:exitCode:)` classifies a payload.
///
/// Five review rounds each found a hole where one branch read a member its sibling
/// dropped, every one caught by adversarial probing rather than by a test. Case-by-case
/// tests cannot close that class, so this walks the whole cross product — 480 payloads —
/// and checks each against an oracle derived from the brief's section 7 rather than from
/// the implementation. The oracle is written to say what the *specification* requires; if
/// it were a mirror of the code it would prove nothing.
@Suite("Envelope shape matrix")
struct EnvelopeShapeMatrixTests {
  // MARK: - The axes

  enum OKFlag: CaseIterable {
    case absent, isTrue, isFalse, notBoolean

    var json: String? {
      switch self {
      case .absent: return nil
      case .isTrue: return "true"
      case .isFalse: return "false"
      // A null `ok` belongs here, not with `absent`: `ok` is the shape discriminator, so
      // a null one is uninterpretable rather than missing.
      case .notBoolean: return "null"
      }
    }
  }

  enum Data: CaseIterable {
    case absent, null, object

    var json: String? {
      switch self {
      case .absent: return nil
      case .null: return "null"
      case .object: return #"{"x":1}"#
      }
    }

    /// `data` is surfaced on every path, degraded or not, when it is a non-null member.
    var expected: GatewayJSONValue? {
      self == .object ? .object(["x": .int(1)]) : nil
    }
  }

  enum Errors: CaseIterable {
    case absent, null, emptyArray, populatedArray, nonArray

    var json: String? {
      switch self {
      case .absent: return nil
      case .null: return "null"
      case .emptyArray: return "[]"
      case .populatedArray: return #"[{"message":"listed"}]"#
      case .nonArray: return #""bare""#
      }
    }

    /// Null is the idiomatic GraphQL spelling for "no errors", so it reads as absent.
    var isPresent: Bool { self != .absent && self != .null }
  }

  enum SingularError: CaseIterable {
    case absent, null, object, nonObject

    var json: String? {
      switch self {
      case .absent: return nil
      case .null: return "null"
      case .object: return #"{"message":"singular","code":"E_CODE"}"#
      case .nonObject: return #""bare""#
      }
    }

    var isPresent: Bool { self != .absent && self != .null }
  }

  /// What kind of message the resulting first error must carry.
  enum MessageClass: Equatable {
    /// The whole raw stdout, i.e. the payload was degraded.
    case rawOutput
    /// Parsed out of a structured member.
    case exact(String)
    /// The placeholder for a failure with no message to report.
    case unknown

    func matches(_ message: String, stdout: String) -> Bool {
      switch self {
      case .rawOutput: return message == stdout
      case .exact(let text): return message == text
      case .unknown: return message == "unknown error"
      }
    }
  }

  struct Expectation {
    var errorCount: Int
    var messageClass: MessageClass?
    var code: String?
  }

  // MARK: - The oracle

  /// The brief (section 7) defines exactly two shapes and one fallback:
  ///
  /// - Shape B is `{ok: Bool, data, error: {code, message}}`.
  /// - Shape A is `{data, errors: [...], extensions: {requestId}}`.
  /// - Anything else becomes one error carrying the raw text.
  ///
  /// A payload is only shape B or shape A if it carries that shape's markers *and* none
  /// of the other's. Everything else — a non-boolean discriminator, markers from both
  /// shapes, an off-contract member, an object with no markers at all — is the fallback.
  static func expectation(_ ok: OKFlag, _ data: Data, _ errors: Errors, _ error: SingularError) -> Expectation {
    let degraded = Expectation(errorCount: 1, messageClass: .rawOutput, code: nil)

    let okIsBoolean = ok == .isTrue || ok == .isFalse
    if okIsBoolean {
      // Shape B requires no shape-A `errors` and an `error` that is absent or an object.
      guard !errors.isPresent, error != .nonObject else { return degraded }
      if error == .object {
        return Expectation(errorCount: 1, messageClass: .exact("singular"), code: "E_CODE")
      }
      return ok == .isFalse
        ? Expectation(errorCount: 1, messageClass: .unknown, code: nil)
        : Expectation(errorCount: 0, messageClass: nil, code: nil)
    }

    // A non-boolean `ok` is an uninterpretable discriminator.
    if ok != .absent { return degraded }

    // Shape A requires no singular `error` and an `errors` that is absent or an array.
    guard !error.isPresent, errors != .nonArray else { return degraded }
    // An object carrying none of the four markers is not shape A at all.
    guard data != .absent || errors.isPresent else { return degraded }

    if errors == .populatedArray {
      return Expectation(errorCount: 1, messageClass: .exact("listed"), code: nil)
    }
    return Expectation(errorCount: 0, messageClass: nil, code: nil)
  }

  // MARK: - The matrix

  static func payload(
    _ ok: OKFlag,
    _ data: Data,
    _ errors: Errors,
    _ error: SingularError,
    requestId: Bool
  ) -> String {
    var members: [String] = []
    if let json = ok.json { members.append("\"ok\":\(json)") }
    if let json = data.json { members.append("\"data\":\(json)") }
    if let json = errors.json { members.append("\"errors\":\(json)") }
    if let json = error.json { members.append("\"error\":\(json)") }
    if requestId { members.append(#""extensions":{"requestId":"r-1"}"#) }
    return "{" + members.joined(separator: ",") + "}"
  }

  @Test("every combination of ok, data, errors and error classifies per the brief")
  func exhaustiveMatrix() {
    var checked = 0
    for ok in OKFlag.allCases {
      for data in Data.allCases {
        for errors in Errors.allCases {
          for error in SingularError.allCases {
            for requestId in [false, true] {
              checked += 1
              let stdout = Self.payload(ok, data, errors, error, requestId: requestId)
              let envelope = GatewayEnvelope(parsingCLIOutput: stdout, exitCode: 1)
              let expected = Self.expectation(ok, data, errors, error)
              let cell = "ok=\(ok) data=\(data) errors=\(errors) error=\(error) rid=\(requestId)"

              #expect(envelope.errors.count == expected.errorCount, "\(cell): \(stdout)")
              if let messageClass = expected.messageClass, let first = envelope.errors.first {
                #expect(messageClass.matches(first.message, stdout: stdout), "\(cell): \(stdout)")
                #expect(first.code == expected.code, "\(cell): \(stdout)")
              }
              #expect(envelope.data == data.expected, "\(cell): \(stdout)")
              // The request id is a diagnostic, so it survives on every path including a
              // degrade — that is where an opaque raw-text message needs it most.
              #expect(envelope.requestId == (requestId ? "r-1" : nil), "\(cell): \(stdout)")
              #expect(envelope.rawOutput == stdout, "\(cell): \(stdout)")
              #expect(envelope.exitCode == 1, "\(cell): \(stdout)")
            }
          }
        }
      }
    }
    #expect(checked == 480)
  }

  @Test("no payload carrying a failure signal is ever reported as an empty success")
  func failureSignalsAreNeverSilent() {
    // The invariant the five sibling holes each violated, stated independently of the
    // classification above: if anything in the payload says "this call failed", the
    // caller must see a non-empty errors list.
    for ok in OKFlag.allCases {
      for data in Data.allCases {
        for errors in Errors.allCases {
          for error in SingularError.allCases {
            let carriesFailureSignal = ok == .isFalse
              || ok == .notBoolean
              || errors == .populatedArray
              || errors == .nonArray
              || error.isPresent
            guard carriesFailureSignal else { continue }
            let stdout = Self.payload(ok, data, errors, error, requestId: false)
            let envelope = GatewayEnvelope(parsingCLIOutput: stdout, exitCode: 1)
            #expect(!envelope.errors.isEmpty, "silent failure for \(stdout)")
          }
        }
      }
    }
  }

  @Test("a well-formed payload of either documented shape reports no errors")
  func cleanPayloadsReportNoErrors() {
    // The converse guard, so the rule above cannot be satisfied by degrading everything.
    // Enumerated per documented shape rather than filtered out of the cross product: an
    // empty `errors` array beside a boolean `ok` still mixes markers from both shapes and
    // is expected to degrade, so it is not a clean payload even though it carries no
    // error. The matrix surfaced that cell on its first run; the case-by-case tests had
    // never asked about it.
    var cleanShapeB: [String] = []
    for data in Data.allCases {
      for errors in [Errors.absent, .null] {
        for error in [SingularError.absent, .null] {
          cleanShapeB.append(Self.payload(.isTrue, data, errors, error, requestId: false))
        }
      }
    }

    var cleanShapeA: [String] = []
    for data in Data.allCases {
      for errors in [Errors.absent, .null, .emptyArray] {
        for error in [SingularError.absent, .null] {
          // An object carrying none of the four markers is not a documented shape.
          if data == .absent, !errors.isPresent { continue }
          cleanShapeA.append(Self.payload(.absent, data, errors, error, requestId: false))
        }
      }
    }

    #expect(cleanShapeB.count == 12)
    #expect(cleanShapeA.count == 14)
    for stdout in cleanShapeB + cleanShapeA {
      let envelope = GatewayEnvelope(parsingCLIOutput: stdout, exitCode: 0)
      #expect(envelope.errors.isEmpty, "unexpected error for \(stdout)")
    }
  }
}
