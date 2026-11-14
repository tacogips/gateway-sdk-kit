import Foundation

/// One error entry in a gateway result.
public struct GatewayEnvelopeError: Codable, Sendable, Equatable {
  public var message: String
  public var code: String?
  public var path: [String]?
  public var diagnostics: GatewayErrorDiagnostics?

  public init(message: String, code: String? = nil, path: [String]? = nil, diagnostics: GatewayErrorDiagnostics? = nil) {
    self.message = message
    self.code = code
    self.path = path
    self.diagnostics = diagnostics?.isEmpty == false ? diagnostics : nil
  }
  private enum CodingKeys: String, CodingKey { case message, code, path; case diagnostics = "extensions" }

  public init(from decoder: any Decoder) throws {
    let fields = try decoder.container(keyedBy: CodingKeys.self)
    self.init(message: try fields.decode(String.self, forKey: .message),
              code: try fields.decodeIfPresent(String.self, forKey: .code),
              path: try fields.decodeIfPresent([String].self, forKey: .path),
              diagnostics: try? fields.decode(GatewayErrorDiagnostics.self, forKey: .diagnostics))
  }

  public func encode(to encoder: any Encoder) throws {
    var fields = encoder.container(keyedBy: CodingKeys.self)
    try fields.encode(message, forKey: .message)
    try fields.encodeIfPresent(code, forKey: .code)
    try fields.encodeIfPresent(path, forKey: .path)
    if let diagnostics, !diagnostics.isEmpty { try fields.encode(diagnostics, forKey: .diagnostics) }
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
  /// the command gateways' `{ok, data, error: {code, message}}`. Anything else — a crash
  /// message, a usage string, empty output, or a payload that mixes markers from both
  /// shapes — becomes one error carrying the raw text, so a caller never loses the
  /// output and a failed call is never reported as an empty success.
  ///
  /// The payload is classified once, up front, rather than parsed by falling through a
  /// chain of branches. Five review rounds each found a different member that one branch
  /// read and its sibling silently dropped; a single exhaustive classification is what
  /// makes that class of hole unrepresentable. `EnvelopeShapeMatrixTests` pins the whole
  /// cross product.
  public init(parsingCLIOutput stdout: String, exitCode: Int32) {
    self.init(exitCode: exitCode, rawOutput: stdout)

    guard let parsed = try? GatewayJSONValue.parse(stdout),
      case .object(let root) = parsed
    else {
      errors = [GatewayEnvelopeError(message: stdout)]
      return
    }

    // Diagnostics first: `data` and the request id are independent of which shape the
    // payload turns out to be, and a degraded envelope is exactly where a correlation
    // id matters most, since its message is an opaque blob.
    data = Self.member(root["data"])
    if case .object(let extensions) = root["extensions"] {
      requestId = Self.string(extensions["requestId"])
    }

    // `ok` is the shape discriminator, so a null `ok` is an uninterpretable
    // discriminator rather than an absent one. `errors`/`error` treat null as absent,
    // which is the idiomatic GraphQL spelling for "no errors".
    let okMember = root["ok"]
    let errorsMember = Self.member(root["errors"])
    let errorMember = Self.member(root["error"])

    // Shape B: a boolean `ok`, no shape-A `errors`, and `error` absent or an object.
    if case .bool(let ok) = okMember, errorsMember == nil {
      if case .object(let error) = errorMember {
        errors = [
          GatewayEnvelopeError(
            message: Self.string(error["message"]) ?? "unknown error",
            code: Self.string(error["code"]),
            diagnostics: .init(jsonValue: error["extensions"])
          )
        ]
      } else if errorMember != nil {
        // Present but not an object: off-contract, so degrade rather than drop it
        // (ok true) or replace its text with a placeholder (ok false).
        errors = [GatewayEnvelopeError(message: stdout)]
      } else if !ok {
        errors = [GatewayEnvelopeError(message: "unknown error")]
      }
      return
    }

    // Shape A: no `ok`, no singular `error`, and `errors` absent or an array.
    if okMember == nil, errorMember == nil, root["data"] != nil || errorsMember != nil {
      if case .array(let entries) = errorsMember {
        errors = entries.map(Self.envelopeError)
        return
      }
      if errorsMember == nil {
        return
      }
    }

    // Neither shape: an `ok` that is not a boolean, a shape-B `error` beside shape-A
    // members, a shape-A `errors` beside a boolean `ok`, a non-array `errors`, or an
    // object carrying none of the four markers. Degrade rather than guess.
    errors = [GatewayEnvelopeError(message: stdout)]
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
      path: path,
      diagnostics: .init(jsonValue: entry["extensions"])
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
