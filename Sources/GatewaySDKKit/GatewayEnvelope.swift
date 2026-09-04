import Foundation

/// One error entry in a gateway result.
public struct GatewayEnvelopeError: Codable, Sendable, Equatable {
  public var message: String
  public var code: String?
  public var path: [String]?

  public init(message: String, code: String? = nil, path: [String]? = nil) {
    self.message = message
    self.code = code
    self.path = path
  }
}

/// The shared result type every gateway returns.
public struct GatewayEnvelope: Codable, Sendable, Equatable {
  public var data: GatewayJSONValue?
  public var errors: [GatewayEnvelopeError]
  public var requestId: String?
  public var exitCode: Int32
  /// Exactly what the CLI would have printed.
  public var rawOutput: String

  public init(
    data: GatewayJSONValue? = nil,
    errors: [GatewayEnvelopeError] = [],
    requestId: String? = nil,
    exitCode: Int32 = 0,
    rawOutput: String = ""
  ) {
    self.data = data
    self.errors = errors
    self.requestId = requestId
    self.exitCode = exitCode
    self.rawOutput = rawOutput
  }

  /// Parses the two envelope shapes the gateways print today.
  ///
  /// Shape A is GraphQL's `{data, errors: [...], extensions: {requestId}}`; shape B is
  /// the command gateways' `{ok, data, error: {code, message}}`. Anything else — a
  /// crash message, a usage string, empty output — becomes one error carrying the raw
  /// text, so a caller never loses the output.
  public init(parsingCLIOutput stdout: String, exitCode: Int32) {
    self.init(exitCode: exitCode, rawOutput: stdout)

    guard let parsed = try? GatewayJSONValue.parse(stdout),
      case .object(let root) = parsed
    else {
      errors = [GatewayEnvelopeError(message: stdout)]
      return
    }

    if case .bool(let ok) = root["ok"] {
      data = Self.member(root["data"])
      if case .object(let error) = root["error"] {
        errors = [
          GatewayEnvelopeError(
            message: Self.string(error["message"]) ?? "unknown error",
            code: Self.string(error["code"])
          )
        ]
      } else if !ok {
        errors = [GatewayEnvelopeError(message: "unknown error")]
      }
      return
    }

    if root["ok"] != nil {
      // `ok` is present but is not a boolean (a string, a number, null). The payload is
      // shape B in intent but not in form, so success cannot be told from failure — and
      // falling through to shape-A parsing would leave the singular `error` member
      // unread. Degrade rather than guess.
      data = Self.member(root["data"])
      errors = [GatewayEnvelopeError(message: stdout)]
      return
    }

    guard root["data"] != nil || root["errors"] != nil else {
      errors = [GatewayEnvelopeError(message: stdout)]
      return
    }

    data = Self.member(root["data"])
    if case .array(let entries) = root["errors"] {
      errors = entries.map(Self.envelopeError)
    } else if let member = root["errors"], !member.isNull {
      // `errors` is present but off-contract (a bare string, an object, a number).
      // Falling through with an empty list would report a failed call as an empty
      // success, so degrade the way unparsable output does: one error, raw text.
      errors = [GatewayEnvelopeError(message: stdout)]
    }
    if errors.isEmpty, let member = root["error"], !member.isNull {
      // A singular `error` belongs to shape B. Alongside `data`/`errors` it means the
      // payload matches neither shape cleanly, and shape-A parsing would never read it;
      // degrading keeps the message rather than reporting an empty success.
      errors = [GatewayEnvelopeError(message: stdout)]
    }
    if case .object(let extensions) = root["extensions"] {
      requestId = Self.string(extensions["requestId"])
    }
  }

  /// Wraps a thrown error as an envelope, so `invoke` never has to throw.
  public static func failure(_ error: Error, exitCode: Int32) -> GatewayEnvelope {
    // String(describing:) already prefers a CustomStringConvertible description, which
    // is what GatewaySDKError provides.
    let message = String(describing: error)
    return GatewayEnvelope(
      data: nil,
      errors: [GatewayEnvelopeError(message: message)],
      requestId: nil,
      exitCode: exitCode,
      rawOutput: ""
    )
  }

  // MARK: - Parsing helpers

  private static func envelopeError(_ value: GatewayJSONValue) -> GatewayEnvelopeError {
    guard case .object(let entry) = value else {
      return GatewayEnvelopeError(message: string(value) ?? "unknown error")
    }
    var code = string(entry["code"])
    if code == nil, case .object(let extensions) = entry["extensions"] {
      code = string(extensions["code"])
    }
    var path: [String]?
    if case .array(let segments) = entry["path"] {
      path = segments.map { segment in
        switch segment {
        case .string(let text): return text
        case .int(let number): return String(number)
        case .double(let number): return String(describing: number)
        case .bool(let flag): return flag ? "true" : "false"
        case .null: return "null"
        case .array, .object: return (try? segment.jsonString()) ?? ""
        }
      }
    }
    return GatewayEnvelopeError(
      message: string(entry["message"]) ?? "unknown error",
      code: code,
      path: path
    )
  }

  private static func member(_ value: GatewayJSONValue?) -> GatewayJSONValue? {
    guard let value, !value.isNull else { return nil }
    return value
  }

  private static func string(_ value: GatewayJSONValue?) -> String? {
    guard case .string(let text) = value else { return nil }
    return text
  }
}
