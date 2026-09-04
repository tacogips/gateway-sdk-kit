import Foundation

/// One problem found by `GatewaySchemaCatalog.validate()`.
///
/// `path` is a dotted locator such as `operation.threads.arguments.accountId` or
/// `type.Thread.fields.subject`, so a facade test can assert on the exact site.
public struct GatewaySchemaProblem: Codable, Sendable, Equatable {
  public var path: String
  public var message: String

  public init(path: String, message: String) {
    self.path = path
    self.message = message
  }
}

extension GatewaySchemaCatalog {
  /// Checks the catalog for internal inconsistencies.
  ///
  /// Problems are reported in catalog order (operations first, then types) with one
  /// entry per finding. An empty result is the contract every facade asserts per tier.
  public func validate() -> [GatewaySchemaProblem] {
    var problems: [GatewaySchemaProblem] = []
    let knownTypeNames = Set(types.map(\.name))

    var seenOperationNames: Set<String> = []
    for operation in operations {
      let base = "operation.\(operation.name)"
      if !seenOperationNames.insert(operation.name).inserted {
        problems.append(
          GatewaySchemaProblem(path: base, message: "duplicate operation name '\(operation.name)'")
        )
      }
      problems += validateArguments(operation.arguments, at: "\(base).arguments", known: knownTypeNames)
      if let result = operation.result {
        problems += unknownTypeProblem(result, at: "\(base).result", known: knownTypeNames)
      } else if operation.kind == .query || operation.kind == .mutation {
        problems.append(
          GatewaySchemaProblem(
            path: "\(base).result",
            message: "operation kind '\(operation.kind.rawValue)' requires a result type"
          )
        )
      }
    }

    var seenTypeNames: Set<String> = []
    for type in types {
      let base = "type.\(type.name)"
      if !seenTypeNames.insert(type.name).inserted {
        problems.append(
          GatewaySchemaProblem(path: base, message: "duplicate type name '\(type.name)'")
        )
      }
      switch type.kind {
      case .scalar:
        break
      case .object(let fields):
        if fields.isEmpty {
          problems.append(GatewaySchemaProblem(path: base, message: "object type has no fields"))
        }
        for field in fields {
          let fieldPath = "\(base).fields.\(field.name)"
          problems += unknownTypeProblem(field.type, at: fieldPath, known: knownTypeNames)
          problems += validateArguments(
            field.arguments,
            at: "\(fieldPath).arguments",
            known: knownTypeNames
          )
        }
      case .inputObject(let fields):
        problems += validateArguments(fields, at: "\(base).fields", known: knownTypeNames)
      case .enumeration(let values):
        if values.isEmpty {
          problems.append(GatewaySchemaProblem(path: base, message: "enum type has no values"))
        }
      }
    }

    return problems
  }

  private func validateArguments(
    _ arguments: [GatewayArgument],
    at base: String,
    known: Set<String>
  ) -> [GatewaySchemaProblem] {
    var problems: [GatewaySchemaProblem] = []
    for argument in arguments {
      let path = "\(base).\(argument.name)"
      problems += unknownTypeProblem(argument.type, at: path, known: known)
      if argument.isRequired || argument.type.isRequired, argument.defaultValue != nil {
        problems.append(
          GatewaySchemaProblem(path: path, message: "required argument must not have a default value")
        )
      }
    }
    return problems
  }

  private func unknownTypeProblem(
    _ type: GatewayTypeRef,
    at path: String,
    known: Set<String>
  ) -> [GatewaySchemaProblem] {
    let name = type.namedTypeName
    guard !Self.builtinScalars.contains(name), !known.contains(name) else { return [] }
    return [GatewaySchemaProblem(path: path, message: "unknown type '\(name)'")]
  }
}
