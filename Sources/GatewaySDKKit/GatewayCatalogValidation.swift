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
        problems += emptySelectionProblem(operation, result: result, at: "\(base).result")
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
        problems += duplicateNameProblems(fields.map(\.name), at: "\(base).fields", noun: "field")
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
        problems += duplicateNameProblems(fields.map(\.name), at: "\(base).fields", noun: "field")
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
    var problems = duplicateNameProblems(arguments.map(\.name), at: base, noun: "argument")
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

  /// Reports a composite result type whose default selection comes out empty.
  ///
  /// GraphQL requires a selection set on a composite field, so such an operation cannot
  /// produce a document through `.default`. `GatewayDocumentBuilder.build` throws
  /// `emptySelection` for it; reporting it here too lets a facade catch the catalog
  /// defect at load time rather than at the first call. Only `.default` is affected —
  /// `.raw` can still drive these operations, so this is advisory, not fatal.
  private func emptySelectionProblem(
    _ operation: GatewayOperation,
    result: GatewayTypeRef,
    at path: String
  ) -> [GatewaySchemaProblem] {
    let typeName = result.namedTypeName
    guard !GatewaySelectionPlanner.isLeafType(typeName, catalog: self) else { return [] }
    guard GatewaySelectionPlanner.defaultSelection(of: typeName, catalog: self).isEmpty else {
      return []
    }
    return [
      GatewaySchemaProblem(
        path: path,
        message: "result type '\(typeName)' yields an empty default selection"
      )
    ]
  }

  /// Reports the second and later occurrences of a repeated name.
  ///
  /// A duplicate argument or field name is not merely untidy: the name-keyed lookups in
  /// the type check, the document builder and the literal renderer used to trap on one,
  /// taking the process down. Those sites are now first-wins, so this is defence in
  /// depth — nothing forces a facade to call `validate()` before `build()`.
  private func duplicateNameProblems(
    _ names: [String],
    at base: String,
    noun: String
  ) -> [GatewaySchemaProblem] {
    var seen: Set<String> = []
    var problems: [GatewaySchemaProblem] = []
    for name in names where !seen.insert(name).inserted {
      problems.append(
        GatewaySchemaProblem(path: "\(base).\(name)", message: "duplicate \(noun) name '\(name)'")
      )
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
