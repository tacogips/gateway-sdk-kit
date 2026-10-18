import Foundation

/// Bounded numeric diagnostics only; provider messages and arbitrary metadata are not accepted.
public struct GatewayErrorDiagnostics: Codable, Sendable, Equatable {
  public let httpStatus: Int?
  public let providerErrorCode: Int?

  public init(httpStatus: Int? = nil, providerErrorCode: Int? = nil) {
    self.httpStatus = httpStatus.flatMap { (100...599).contains($0) ? $0 : nil }
    self.providerErrorCode = providerErrorCode.flatMap { (0...99_999).contains($0) ? $0 : nil }
  }

  public var isEmpty: Bool { httpStatus == nil && providerErrorCode == nil }

  public var jsonValue: GatewayJSONValue {
    var fields: [String: GatewayJSONValue] = [:]
    if let httpStatus { fields["httpStatus"] = .int(httpStatus) }
    if let providerErrorCode { fields["providerErrorCode"] = .int(providerErrorCode) }
    return .object(fields)
  }

  init(jsonValue: GatewayJSONValue?) {
    guard case .object(let fields) = jsonValue else { self.init(); return }
    let httpStatus: Int? = if case .int(let value) = fields["httpStatus"] { value } else { nil }
    let providerErrorCode: Int? = if case .int(let value) = fields["providerErrorCode"] { value } else { nil }
    self.init(httpStatus: httpStatus, providerErrorCode: providerErrorCode)
  }

  private enum CodingKeys: String, CodingKey { case httpStatus, providerErrorCode }

  public init(from decoder: any Decoder) throws {
    let fields = try decoder.container(keyedBy: CodingKeys.self)
    self.init(httpStatus: try? fields.decode(Int.self, forKey: .httpStatus),
              providerErrorCode: try? fields.decode(Int.self, forKey: .providerErrorCode))
  }
}
